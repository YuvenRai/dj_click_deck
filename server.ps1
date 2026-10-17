$ErrorActionPreference = "Stop"

$port = 8765
$siteRoot = $PSScriptRoot
$dataDirectory = Join-Path $env:LOCALAPPDATA "DJ CLICK DECK Server"
$dataFile = Join-Path $dataDirectory "games.json"
$script:accounts = @{}
$script:sessions = @{}

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
if (Test-Path $dataFile) {
  $savedAccounts = Get-Content -LiteralPath $dataFile -Raw | ConvertFrom-Json
  foreach ($property in $savedAccounts.PSObject.Properties) {
    $account = $property.Value
    $script:accounts[$property.Name] = @{
      username = $account.username
      salt = $account.salt
      secretHash = $account.secretHash
      iterations = if ($account.iterations) { $account.iterations } else { 310000 }
      snapshot = $account.snapshot
      recordingBase64 = $account.recordingBase64
      recordingType = $account.recordingType
    }
  }
}

function Write-JsonResponse {
  param(
    [System.Net.HttpListenerResponse] $Response,
    [int] $StatusCode,
    [object] $Value
  )

  $Response.StatusCode = $StatusCode
  $Response.ContentType = "application/json; charset=utf-8"
  $Response.Headers["Cache-Control"] = "no-store"
  $json = ConvertTo-Json -InputObject $Value -Depth 30 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.Close()
}

function Read-JsonBody {
  param([System.Net.HttpListenerRequest] $Request)

  if ($Request.ContentLength64 -gt 16MB) {
    throw "Request is too large."
  }
  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  try {
    $bodyText = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }
  if ([string]::IsNullOrWhiteSpace($bodyText)) {
    throw "A JSON request body is required."
  }
  return ($bodyText | ConvertFrom-Json)
}

function Test-GameCode {
  param([string] $Value)

  return -not [string]::IsNullOrEmpty($Value) -and $Value.Length -le 256
}

function New-SecretHash {
  param([string] $GameCode, [string] $Salt, [int] $Iterations = 40000)

  $saltBytes = [Convert]::FromBase64String($Salt)
  $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($GameCode, $saltBytes, $Iterations)
  try {
    return [Convert]::ToBase64String($deriveBytes.GetBytes(32))
  } finally {
    $deriveBytes.Dispose()
  }
}

function Test-Snapshot {
  param([object] $Snapshot)

  if (-not $Snapshot -or $Snapshot.version -ne 3 -or -not $Snapshot.state) {
    return $false
  }
  $state = $Snapshot.state
  if (-not ($state.score -is [ValueType]) -or [double]$state.score -lt 0) { return $false }
  if ([double]$state.pointsPerSecond -lt 0 -or [double]$state.clickMultiplier -lt 1 -or [double]$state.passiveMultiplier -lt 1) { return $false }
  if ($state.upgradeCosts.Count -ne 6 -or $state.upgradePurchaseCounts.Count -ne 6) { return $false }
  foreach ($cost in $state.upgradeCosts) {
    if ([double]$cost -lt 1 -or [double]$cost -gt [int]::MaxValue) { return $false }
  }
  foreach ($count in $state.upgradePurchaseCounts) {
    if ([double]$count -lt 0 -or [double]$count -gt [int]::MaxValue) { return $false }
  }
  return $true
}

function Save-Accounts {
  $json = ConvertTo-Json -InputObject $script:accounts -Depth 30
  $temporaryFile = "$dataFile.tmp"
  [System.IO.File]::WriteAllText($temporaryFile, $json, [System.Text.Encoding]::UTF8)
  Move-Item -LiteralPath $temporaryFile -Destination $dataFile -Force
}

function Get-AccountForRequest {
  param([object] $Body)

  if (-not $Body.username -or -not $Body.gameCode) {
    return $null
  }
  $usernameKey = ([string]$Body.username).ToLowerInvariant()
  if (-not $script:accounts.ContainsKey($usernameKey)) {
    return $null
  }
  $account = $script:accounts[$usernameKey]
  $candidateHash = New-SecretHash ([string]$Body.gameCode) $account.salt $account.iterations
  $expectedBytes = [Convert]::FromBase64String($account.secretHash)
  $candidateBytes = [Convert]::FromBase64String($candidateHash)
  $difference = 0
  for ($index = 0; $index -lt $expectedBytes.Length; $index += 1) {
    $difference = $difference -bor ($expectedBytes[$index] -bxor $candidateBytes[$index])
  }
  if ($difference -ne 0) {
    return $null
  }
  return $account
}

function New-SessionToken {
  param([string] $UsernameKey)

  $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $tokenBytes = New-Object byte[] 32
  $random.GetBytes($tokenBytes)
  $random.Dispose()
  $token = [Convert]::ToBase64String($tokenBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
  $script:sessions[$token] = $UsernameKey
  return $token
}

function Handle-ApiRequest {
  param([System.Net.HttpListenerContext] $Context)

  $request = $Context.Request
  $response = $Context.Response
  if ($request.HttpMethod -ne "POST") {
    Write-JsonResponse $response 405 @{ error = "POST is required." }
    return
  }
  try {
    $body = Read-JsonBody $request
    $username = ([string]$body.username).Trim()
    $gameCode = [string]$body.gameCode
    if ($username -notmatch '^[A-Za-z0-9_]{3,24}$') {
      Write-JsonResponse $response 400 @{ error = "Username must be 3 to 24 letters, numbers, underscores, or hyphens." }
      return
    }
    $usernameKey = $username.ToLowerInvariant()
    $route = $request.Url.AbsolutePath

    if ($route -eq "/api/create") {
      if (-not (Test-GameCode $gameCode)) {
        Write-JsonResponse $response 400 @{ error = "Enter a Game Code of 256 characters or fewer." }
        return
      }
      if ($script:accounts.ContainsKey($usernameKey)) {
        Write-JsonResponse $response 409 @{ error = "That username already exists. Load its game with the correct Game Code." }
        return
      }
      if (-not (Test-Snapshot $body.snapshot)) {
        Write-JsonResponse $response 400 @{ error = "The new game data is invalid." }
        return
      }
      $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
      $saltBytes = New-Object byte[] 32
      $random.GetBytes($saltBytes)
      $random.Dispose()
      $salt = [Convert]::ToBase64String($saltBytes)
      $script:accounts[$usernameKey] = @{
        username = $username
        salt = $salt
        iterations = 40000
        secretHash = New-SecretHash $gameCode $salt 40000
        snapshot = $body.snapshot
        recordingBase64 = $null
        recordingType = "audio/webm"
      }
      Save-Accounts
      $sessionToken = New-SessionToken $usernameKey
      Write-JsonResponse $response 201 @{ snapshot = $body.snapshot; created = $true; sessionToken = $sessionToken }
      return
    }

    if ($route -eq "/api/load") {
      $account = Get-AccountForRequest $body
      if (-not $account) {
        Write-JsonResponse $response 401 @{ error = "Username or Game Code not found. Check both and try again." }
        return
      }
      $sessionToken = New-SessionToken $usernameKey
      Write-JsonResponse $response 200 @{
        snapshot = $account.snapshot
        recordingBase64 = $account.recordingBase64
        recordingType = $account.recordingType
        sessionToken = $sessionToken
      }
      return
    }
    if ($route -eq "/api/save") {
      if (-not $body.sessionToken -or -not $script:sessions.ContainsKey([string]$body.sessionToken)) {
        Write-JsonResponse $response 401 @{ error = "Your game session expired. Enter your username and Game Code again." }
        return
      }
      $sessionUsernameKey = $script:sessions[[string]$body.sessionToken]
      if ($sessionUsernameKey -ne $usernameKey) {
        Write-JsonResponse $response 401 @{ error = "Game session does not match this username." }
        return
      }
      $account = $script:accounts[$sessionUsernameKey]
      if (-not (Test-Snapshot $body.snapshot)) {
        Write-JsonResponse $response 400 @{ error = "The saved game data is invalid." }
        return
      }
      if ($body.recordingBase64) {
        if ($body.recordingBase64.Length -gt 12000000) {
          Write-JsonResponse $response 413 @{ error = "Microphone recording is too large to save." }
          return
        }
        $account.recordingBase64 = [string]$body.recordingBase64
        $account.recordingType = if ($body.recordingType -match "^audio/[a-z0-9.+-]+$") { $body.recordingType } else { "audio/webm" }
      }
      $account.snapshot = $body.snapshot
      Save-Accounts
      Write-JsonResponse $response 200 @{ ok = $true }
      return
    }
    Write-JsonResponse $response 404 @{ error = "API endpoint not found." }
  } catch {
    if (-not $response.OutputStream.CanWrite) {
      return
    }
    Write-JsonResponse $response 400 @{ error = $_.Exception.Message }
  }
}

function Get-ContentType {
  param([string] $Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".css" { return "text/css; charset=utf-8" }
    ".js" { return "text/javascript; charset=utf-8" }
    ".png" { return "image/png" }
    ".svg" { return "image/svg+xml" }
    default { return "application/octet-stream" }
  }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
try {
  $listener.Start()
} catch {
  Write-Error "Could not start the local server on http://127.0.0.1:$port/. $_"
  exit 1
}

Write-Host "DJ Click Deck Server is running at http://127.0.0.1:$port/"
Write-Host "Game data is stored in: $dataFile"
Write-Host "Open the local URL in your preferred browser."

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      if ($context.Request.Url.AbsolutePath.StartsWith("/api/")) {
        Handle-ApiRequest $context
        continue
      }
      if ($context.Request.HttpMethod -ne "GET" -and $context.Request.HttpMethod -ne "HEAD") {
        Write-JsonResponse $context.Response 405 @{ error = "Method not allowed." }
        continue
      }
      $relativePath = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart("/"))
      if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = "index.html" }
      if ($relativePath -ne "index.html") {
        $context.Response.StatusCode = 404
        $context.Response.Close()
        continue
      }
      $filePath = Join-Path $siteRoot "index.html"
      $bytes = [System.IO.File]::ReadAllBytes($filePath)
      $context.Response.ContentType = Get-ContentType $filePath
      $context.Response.Headers["Cache-Control"] = "no-store"
      $context.Response.ContentLength64 = $bytes.Length
      if ($context.Request.HttpMethod -eq "GET") {
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      }
      $context.Response.Close()
    } catch {
      Write-Warning "Request failed: $_"
      try { $context.Response.Abort() } catch {}
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
