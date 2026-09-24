"use client";


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
      const detail = body?.detail;
      if (typeof detail === "string") message = detail;
      else if (detail && typeof detail.message === "string") message = detail.message;
      else if (Array.isArray(detail) && typeof detail[0]?.msg === "string") message = detail[0].msg;
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

/**
 * Ask our server-side Neon Auth adapter for a JWT. This intentionally goes
 * through a dedicated route that calls `auth.token()`, so the browser receives
 * a normalized JWT response instead of depending on the catch-all auth proxy's
 * upstream response shape.
 */
async function fetchApiToken(): Promise<string | null> {
  try {
    const response = await fetch("/api/session-token", { credentials: "same-origin", cache: "no-store" });
    if (!response.ok) return null;
    const body = (await response.json()) as { token?: unknown };
    return typeof body.token === "string" && body.token.split(".").length === 3 ? body.token : null;
  } catch {
    return null;
  }
}

async function getApiToken(forceRefresh = false): Promise<string | null> {
  if (!forceRefresh && cachedToken && cachedToken.expiresAt - TOKEN_EXPIRY_SKEW_MS > Date.now()) {
    return cachedToken.value;
  }
  if (!inflightToken) {
    inflightToken = fetchApiToken()
      .then((token) => {
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
  // Multipart bodies must let the browser set Content-Type (with its boundary).
  const isForm = typeof FormData !== "undefined" && init.body instanceof FormData;
  return fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(isForm ? {} : { "Content-Type": "application/json" }),
      ...(init.headers ?? {}),
    },
    cache: "no-store",
  });
}

/** A fresh key for one logical mutation. Reuse the same key when retrying that mutation. */
export function idempotencyKey(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

/** JSON POST/PUT with an Idempotency-Key header. */
export function apiMutate<T>(path: string, body: unknown, options: { method?: string; key?: string } = {}): Promise<T> {
  return apiFetch<T>(path, {
    method: options.method ?? "POST",
    headers: { "Idempotency-Key": options.key ?? idempotencyKey() },
    body: body === undefined ? undefined : JSON.stringify(body),
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
