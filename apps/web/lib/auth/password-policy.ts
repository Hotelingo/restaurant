export const MIN_PASSWORD_LENGTH = 12;

const PASSWORD_ENDPOINTS = new Set([
  "sign-up/email",
  "reset-password",
  "change-password",
  "set-password",
]);

export function passwordPolicyError(
  endpoint: string,
  body: unknown,
): string | null {
  if (!PASSWORD_ENDPOINTS.has(endpoint)) return null;
  if (!body || typeof body !== "object") return null;

  const value = body as Record<string, unknown>;
  const candidate =
    typeof value.newPassword === "string"
      ? value.newPassword
      : typeof value.password === "string"
        ? value.password
        : null;

  if (candidate === null) return null;
  if (candidate.length < MIN_PASSWORD_LENGTH) {
    return `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`;
  }
  return null;
}
