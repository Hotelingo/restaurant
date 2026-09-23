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

## Password reset

Implemented in Slice 1 hardening using Neon's supported Managed Auth UI path:

- `@neondatabase/auth-ui` provides the forgot-password and reset-password views;
- the managed forms are wrapped inside the existing product shell and mapped to the STATES colour/focus tokens;
- `/auth/reset` requests the reset link and `/auth/reset-password` handles the token callback;
- the application auth proxy rejects new passwords shorter than 12 characters for sign-up,
  reset-password, change-password and set-password endpoints.

The remaining release check is a live email-link E2E test against the deployed auth domain. The
managed reset flow is therefore implemented but not yet claimed production-verified.


## Invitation implementation

Application membership invitations are implemented independently of Neon's beta Organization plugin.

Reason:
- the product requires application roles `admin`, `editor`, `viewer`, and `reviewer`;
- it also requires explicit all-outlets versus selected-outlet scope;
- setup-analyst access remains a separate time-limited staff assignment.

The server generates a high-entropy invitation token and stores only its SHA-256 hash. The signed
preview route discloses only the organisation display name, role, outlet scope, safe inviter name and
expiry. Acceptance requires an authenticated Neon identity whose email matches the invited address.

R1 currently exposes the invitation link to the organisation admin for secure delivery. In-app SMTP
delivery is not represented as complete until a production email provider and verified delivery flow
are configured.

Registration and sign-out are implemented. Password reset remains gated by the managed-reset UI
integration described above. MFA remains the production blocker described above.


## Session policy gap

OD-06 specifies a 12-hour idle timeout with sliding refresh and a 7-day absolute maximum. The
current Managed Better Auth configuration exposed to this project does not provide those two
application-specific lifetime controls through the integration surface we are using.

Do not claim the session-lifetime requirement complete until either Neon exposes enforceable values
for both limits or the application adds a server-side session gate that can verify session
created/updated timestamps without weakening the managed-auth middleware.

The application-layer 12-character password minimum is implemented separately and does not close
this session-policy gap.
