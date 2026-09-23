export function safeReturnTo(value: string | null | undefined, fallback = "/auth/continue") {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return fallback;
  return value;
}
