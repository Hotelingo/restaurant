"use client";

import { authClient } from "@/lib/auth/client";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly correlationId: string | null,
  ) {
    super(message);
  }
}

const API_BASE = process.env.NEXT_PUBLIC_API_BASE_URL;

if (!API_BASE) {
  throw new Error("NEXT_PUBLIC_API_BASE_URL is required");
}

async function parseResponse<T>(response: Response): Promise<T> {
  const correlationId = response.headers.get("X-Correlation-ID");

  if (!response.ok) {
    let message = "The server could not complete this request.";
    try {
      const body = await response.json();
      if (typeof body?.detail === "string") message = body.detail;
    } catch {
      // Keep the neutral message. Do not expose transport internals.
    }
    throw new ApiError(message, response.status, correlationId);
  }

  return response.json() as Promise<T>;
}

export async function publicApiFetch<T>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
    cache: "no-store",
  });
  return parseResponse<T>(response);
}

// Short-lived API JWT, held in memory only (never storage -- v4.3 §8).
// Fetching a fresh token before every call doubled round-trips, and two calls
// in quick succession could race so the second came back empty and surfaced
// as a false "session expired". One in-flight request is shared, and the token
// is reused until shortly before its own `exp`.
const TOKEN_EXPIRY_SKEW_MS = 30_000;
let cachedToken: { value: string; expiresAt: number } | null = null;
let inflightToken: Promise<string | null> | null = null;

/**
 * Drop the cached API token. Must run on sign-out and whenever an /auth page
 * mounts: navigation here is client-side, so module state survives it, and a
 * token cached for one user must never be sent on behalf of the next.
 */
export function clearApiTokenCache(): void {
  cachedToken = null;
  inflightToken = null;
}

function tokenExpiry(token: string): number {
  try {
    const payload = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return typeof payload.exp === "number" ? payload.exp * 1000 : 0;
  } catch {
    return 0; // Unreadable expiry: treat as expired and never reuse it.
  }
}

async function getApiToken(forceRefresh = false): Promise<string | null> {
  if (!forceRefresh && cachedToken && cachedToken.expiresAt - TOKEN_EXPIRY_SKEW_MS > Date.now()) {
    return cachedToken.value;
  }
  if (!inflightToken) {
    inflightToken = authClient
      .token()
      .then((result) => {
        const token = result.data?.token ?? null;
        cachedToken = token ? { value: token, expiresAt: tokenExpiry(token) } : null;
        return token;
      })
      .finally(() => {
        inflightToken = null;
      });
  }
  return inflightToken;
}

async function authorisedFetch(path: string, init: RequestInit, token: string): Promise<Response> {
  return fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
    cache: "no-store",
  });
}

export async function apiFetch<T>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  let token = await getApiToken();
  if (!token) token = await getApiToken(true);
  if (!token) {
    throw new ApiError("Your session has expired. Sign in again.", 401, null);
  }

  let response = await authorisedFetch(path, init, token);

  // A cached token the API rejects (revoked, rotated key) gets one fresh retry.
  if (response.status === 401) {
    cachedToken = null;
    const fresh = await getApiToken(true);
    if (fresh) response = await authorisedFetch(path, init, fresh);
  }

  return parseResponse<T>(response);
}
