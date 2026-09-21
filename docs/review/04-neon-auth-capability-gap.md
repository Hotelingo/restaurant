# Neon Auth capability check — Slice 1

**Checked:** 2026-09-21  
**Scope:** v4.3 AUTH01–AUTH05 against current Managed Better Auth capabilities.

## Implementable now

- Email/password sign-in.
- Managed session cookies in Next.js.
- Raw short-lived JWT retrieval for the separate FastAPI service.
- Magic-link sign-in, once the branch Magic Link plugin is enabled.
- Password reset through Neon's managed Auth UI components.
- Branch-isolated Auth data and endpoints.

## Gap: MFA

OD-06 requires MFA for `admin`, `reviewer` and `setup_analyst`.

Current Neon Managed Better Auth documentation lists the supported managed plugins as Admin,
Email OTP, JWT, Magic Link, Organization, Open API and Phone Number. It does **not** list the Better
Auth two-factor/MFA plugin as supported.

Therefore AUTH05 must not be falsely marked complete.

Before production, choose one of:

1. Neon adds supported MFA and we implement AUTH05 natively; or
2. adopt an external identity/MFA layer whose verified assurance can be enforced by the API.

Do not simulate MFA merely with a UI screen or unverified client flag.

## Password reset styling

Neon's current password-reset SDK method is not fully supported; the documented path uses Managed
Auth UI components. v4.3 forbids introducing a second visual system, so the reset flow remains
unreleased until that managed component is wrapped/themed to the approved STATES language.
