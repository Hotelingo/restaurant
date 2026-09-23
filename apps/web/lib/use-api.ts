"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { apiFetch, ApiError, idempotencyKey } from "./api";

export type Resource<T> = {
  data: T | null;
  error: ApiError | null;
  loading: boolean;
  reload: () => void;
};

/**
 * Load one API resource. Pass `null` to skip (e.g. until a period is known).
 * A 404 is surfaced as an error with status 404 so screens can render an
 * honest "not yet" state instead of a fabricated zero.
 *
 * `loading` is true only while a path is loaded for the first time. `reload()`
 * refreshes in place and keeps the current data on screen, so a refresh never
 * swaps the page for a skeleton and remounts everything beneath it.
 */
export function useApi<T>(path: string | null): Resource<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [loading, setLoading] = useState<boolean>(path !== null);
  const [version, setVersion] = useState(0);
  const loadedPath = useRef<string | null>(null);

  useEffect(() => {
    if (path === null) {
      loadedPath.current = null;
      setData(null);
      setError(null);
      setLoading(false);
      return;
    }
    let cancelled = false;
    if (loadedPath.current !== path) {
      // A different resource: never show the previous one's data under it.
      setData(null);
      setError(null);
      setLoading(true);
    }
    apiFetch<T>(path)
      .then((value) => {
        if (cancelled) return;
        loadedPath.current = path;
        setData(value);
        setError(null);
      })
      .catch((cause) => {
        if (cancelled) return;
        loadedPath.current = path;
        setData(null);
        setError(cause instanceof ApiError ? cause : new ApiError("The request failed.", 500, null));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [path, version]);

  const reload = useCallback(() => setVersion((v) => v + 1), []);
  return { data, error, loading, reload };
}

/** Runs one mutation at a time and exposes its error; the button re-enables on failure. */
export function useMutation() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  const run = useCallback(async <T,>(fn: () => Promise<T>): Promise<T | null> => {
    setBusy(true);
    setError(null);
    try {
      return await fn();
    } catch (cause) {
      setError(cause instanceof ApiError ? cause : new ApiError("The request failed.", 500, null));
      return null;
    } finally {
      setBusy(false);
    }
  }, []);

  return { busy, error, run, clearError: () => setError(null) };
}

/**
 * Idempotency key for one logical submission: the same key across retries of a
 * failed attempt (so a lost response never double-writes), a new key once it
 * succeeds (so the next version is a new write).
 */
export function useSubmitKey() {
  const key = useRef<string>(idempotencyKey());
  return {
    current: () => key.current,
    rotate: () => { key.current = idempotencyKey(); },
  };
}
