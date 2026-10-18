$ErrorActionPreference = "Stop"

$port = 8765
$siteRoot = $PSScriptRoot
$cloudApiBaseUrl = "https://djdeck4.netlify.app"

Add-Type -AssemblyName System.Net.Http
$httpClient = New-Object System.Net.Http.HttpClient
$httpClient.Timeout = [TimeSpan]::FromSeconds(30)

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

function Handle-ApiRequest {
  param([System.Net.HttpListenerContext] $Context)

  $request = $Context.Request
  if ($request.HttpMethod -ne "POST") {
    Write-JsonResponse $Context.Response 405 @{ error = "POST is required." }
    return
  }
  if ($request.ContentLength64 -gt 16MB) {
    Write-JsonResponse $Context.Response 413 @{ error = "Request is too large." }
    return
  }

  $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
  try {
    $body = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }

  $remoteRequest = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::Post,
    [Uri]("$cloudApiBaseUrl$($request.Url.AbsolutePath)")
  )
  $remoteRequest.Content = [System.Net.Http.StringContent]::new(
    $body,
    [System.Text.Encoding]::UTF8,
    "application/json"
  )

  try {
    $remoteResponse = $httpClient.SendAsync($remoteRequest).GetAwaiter().GetResult()
    try {
      $responseBytes = $remoteResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      $Context.Response.StatusCode = [int]$remoteResponse.StatusCode
      $Context.Response.ContentType = if ($remoteResponse.Content.Headers.ContentType) {
        $remoteResponse.Content.Headers.ContentType.ToString()
      } else {
        "application/json; charset=utf-8"
      }
      $Context.Response.Headers["Cache-Control"] = "no-store"
      $Context.Response.ContentLength64 = $responseBytes.Length
      $Context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
      $Context.Response.Close()
    } finally {
      $remoteResponse.Dispose()
    }
  } catch {
    Write-Warning "Could not reach the cloud game API: $_"
    if ($Context.Response.OutputStream.CanWrite) {
      Write-JsonResponse $Context.Response 502 @{
        error = "Could not reach the cloud game server. Check your internet connection and try again."
      }
    }
  } finally {
    $remoteRequest.Dispose()
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
  $httpClient.Dispose()
  exit 1
}

Write-Host "DJ Click Deck is running at http://127.0.0.1:$port/"
Write-Host "Accounts and saved games use the shared cloud server at $cloudApiBaseUrl."
Write-Host "An internet connection is required to create, load, and save games."

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
  $httpClient.Dispose()
}
