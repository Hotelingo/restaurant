# Restaurant Performance Review web

Next.js + TypeScript presentation layer for the Restaurant Performance Review application.

## Current foundation

Implemented:

- v4.2 design tokens in light/dark CSS variables;
- STATES primitives: Button, Field, Card, Chip, DataTable, Tabs, Disclosure, EmptyState,
  Skeleton and ErrorPanel;
- Neon Managed Better Auth server/client integration;
- AUTH01 email/password + magic-link entry;
- post-auth context resolution;
- SETUP01 organisation step;
- SETUP02 atomic outlet/bootstrap step through FastAPI;
- STATE03 permission denied;
- STATE04 recoverable error panel;
- STATE05 neutral not-found handling.

## Environment

Required values:

```text
NEON_AUTH_BASE_URL
NEON_AUTH_COOKIE_SECRET
NEXT_PUBLIC_API_BASE_URL
```

Never put database credentials or Neon API keys in the browser environment.

## Architecture boundary

This package is presentation and interaction only.

Allowed:
- Neon Auth client/session integration;
- calling typed server API contracts;
- rendering server-authoritative values;
- local UI/form/navigation state.

Forbidden:
- authoritative financial calculations;
- direct imports from `packages/calc_engine` or `packages/import_engine`;
- direct writes to canonical facts or calculation results;
- database owner/service credentials in browser code.

The v4.2 wireframe remains the analytical behavioural reference. v4.3 defines the operational
auth/onboarding/error journeys.
