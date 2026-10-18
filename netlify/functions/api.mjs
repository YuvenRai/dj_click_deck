import { createHmac, pbkdf2Sync, randomBytes, timingSafeEqual } from "node:crypto";
import { getStore } from "@netlify/blobs";

const accounts = getStore({ name: "dj-click-deck-games", consistency: "strong" });
const maxGameCodeLength = 256;
const maxRecordingLength = 4_000_000;
const maxRequestLength = 16 * 1024 * 1024;
const allowedOrigins = new Set([
  "https://djdeck4.netlify.app",
  "http://localhost:5500",
  "http://127.0.0.1:5500",
  "http://localhost:8765",
  "http://127.0.0.1:8765"
]);

function corsHeaders(request) {
  const headers = { "Vary": "Origin" };
  const origin = request.headers.get("origin");
  if (allowedOrigins.has(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    headers["Access-Control-Allow-Headers"] = "Content-Type";
    headers["Access-Control-Max-Age"] = "600";
  }
  return headers;
}

function jsonResponse(status, value, request) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      ...corsHeaders(request)
    }
  });
}

function testSnapshot(snapshot) {
  const state = snapshot?.state;
  return snapshot?.version === 3
    && state
    && Number.isFinite(state.score) && state.score >= 0
    && Number.isFinite(state.pointsPerSecond) && state.pointsPerSecond >= 0
    && Number.isFinite(state.clickMultiplier) && state.clickMultiplier >= 1
    && Number.isFinite(state.passiveMultiplier) && state.passiveMultiplier >= 1
    && Array.isArray(state.upgradeCosts) && state.upgradeCosts.length === 6
    && state.upgradeCosts.every((cost) => Number.isSafeInteger(cost) && cost >= 1 && cost <= 2_147_483_647)
    && Array.isArray(state.upgradePurchaseCounts) && state.upgradePurchaseCounts.length === 6
    && state.upgradePurchaseCounts.every((count) => Number.isSafeInteger(count) && count >= 0 && count <= 2_147_483_647);
}

function createSecretHash(gameCode, salt, iterations) {
  return pbkdf2Sync(gameCode, Buffer.from(salt, "base64"), iterations, 32, "sha1").toString("base64");
}

function createSessionToken(usernameKey, secretHash) {
  const nonce = randomBytes(32).toString("base64url");
  const signature = createHmac("sha256", Buffer.from(secretHash, "base64"))
    .update(`${usernameKey}.${nonce}`)
    .digest("base64url");
  return `${nonce}.${signature}`;
}

function verifySessionToken(usernameKey, secretHash, token) {
  if (typeof token !== "string") {
    return false;
  }
  const [nonce, signature, extra] = token.split(".");
  if (!nonce || !signature || extra !== undefined) {
    return false;
  }

  const expected = createHmac("sha256", Buffer.from(secretHash, "base64"))
    .update(`${usernameKey}.${nonce}`)
    .digest();
  let provided;
  try {
    provided = Buffer.from(signature, "base64url");
  } catch {
    return false;
  }
  return provided.length === expected.length && timingSafeEqual(provided, expected);
}

async function readJsonBody(request) {
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > maxRequestLength) {
    throw new Error("Request is too large.");
  }

  const text = await request.text();
  if (!text.trim()) {
    throw new Error("A JSON request body is required.");
  }
  if (Buffer.byteLength(text, "utf8") > maxRequestLength) {
    throw new Error("Request is too large.");
  }
  return JSON.parse(text);
}

async function handleRequest(request, endpoint) {
  const origin = request.headers.get("origin");
  const respond = (status, value) => jsonResponse(status, value, request);
  if (origin && !allowedOrigins.has(origin)) {
    return respond(403, { error: "This site is not allowed to use the game API." });
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return respond(405, { error: "POST is required." });
  }

  let body;
  try {
    body = await readJsonBody(request);
  } catch (error) {
    return respond(400, {
      error: error instanceof SyntaxError ? "The request body must be valid JSON." : error.message
    });
  }

  const username = typeof body.username === "string" ? body.username.trim() : "";
  const gameCode = typeof body.gameCode === "string" ? body.gameCode : "";
  if (!/^[A-Za-z0-9_]{3,24}$/.test(username)) {
    return respond(400, { error: "Username must be 3 to 24 letters, numbers, or underscores." });
  }
  const usernameKey = username.toLowerCase();
  const accountKey = `account:${usernameKey}`;

  if (endpoint === "create") {
    if (!gameCode || gameCode.length > maxGameCodeLength) {
      return respond(400, { error: "Enter a Game Code of 256 characters or fewer." });
    }
    if (!testSnapshot(body.snapshot)) {
      return respond(400, { error: "The new game data is invalid." });
    }

    const salt = randomBytes(32).toString("base64");
    const iterations = 40_000;
    const account = {
      username,
      salt,
      iterations,
      secretHash: createSecretHash(gameCode, salt, iterations),
      snapshot: body.snapshot,
      recordingBase64: null,
      recordingType: "audio/webm"
    };
    const { modified } = await accounts.setJSON(accountKey, account, { onlyIfNew: true });
    if (!modified) {
      return respond(409, { error: "That username already exists. Load its game with the correct Game Code." });
    }

    return respond(201, {
      snapshot: body.snapshot,
      created: true,
      sessionToken: createSessionToken(usernameKey, account.secretHash)
    });
  }

  const account = await accounts.get(accountKey, { type: "json" });
  if (!account) {
    return respond(401, { error: "Username or Game Code not found. Check both and try again." });
  }

  if (endpoint === "load") {
    if (!gameCode || gameCode.length > maxGameCodeLength) {
      return respond(401, { error: "Username or Game Code not found. Check both and try again." });
    }
    const candidateHash = Buffer.from(createSecretHash(gameCode, account.salt, account.iterations), "base64");
    const expectedHash = Buffer.from(account.secretHash, "base64");
    if (candidateHash.length !== expectedHash.length || !timingSafeEqual(candidateHash, expectedHash)) {
      return respond(401, { error: "Username or Game Code not found. Check both and try again." });
    }
    return respond(200, {
      snapshot: account.snapshot,
      recordingBase64: account.recordingBase64,
      recordingType: account.recordingType,
      sessionToken: createSessionToken(usernameKey, account.secretHash)
    });
  }

  if (endpoint === "save") {
    if (!verifySessionToken(usernameKey, account.secretHash, body.sessionToken)) {
      return respond(401, { error: "Your game session expired. Enter your username and Game Code again." });
    }
    if (!testSnapshot(body.snapshot)) {
      return respond(400, { error: "The saved game data is invalid." });
    }
    if (body.recordingBase64) {
      if (typeof body.recordingBase64 !== "string" || body.recordingBase64.length > maxRecordingLength) {
        return respond(413, { error: "Microphone recording is too large to save. Record a shorter mix." });
      }
      account.recordingBase64 = body.recordingBase64;
      account.recordingType = typeof body.recordingType === "string" && /^audio\/[a-z0-9.+-]+$/.test(body.recordingType)
        ? body.recordingType
        : "audio/webm";
    }
    account.snapshot = body.snapshot;
    await accounts.setJSON(accountKey, account);
    return respond(200, { ok: true });
  }

  return respond(404, { error: "API endpoint not found." });
}

export default async function handler(request) {
  const pathname = new URL(request.url).pathname.replace(/\/+$/, "");
  const endpoint = pathname.split("/").at(-1);
  try {
    return await handleRequest(request, endpoint);
  } catch (error) {
    console.error("DJ Click Deck API request failed.", error);
    return jsonResponse(500, { error: "The game server could not complete the request. Please try again." }, request);
  }
}

export const config = {
  path: "/api/*"
};
