"use client";

import { clearApiTokenCache } from "@/lib/api";

/**
 * Clears any cached API token when an /auth page renders. See clearApiTokenCache.
 *
 * Deliberately runs during render, not in an effect: React runs child effects
 * before parent effects, so an effect here would fire after an auth page's own
 * first API call (e.g. /auth/continue resolving access) and could let that call
 * carry the previous user's token. Clearing is idempotent, so render-time is safe.
 */
export function ResetApiSession() {
  clearApiTokenCache();
  return null;
}
