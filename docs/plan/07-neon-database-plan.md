# Neon Database Integration Plan

**Status:** approved platform transition preparation  
**Neon project:** `cold-mouse-53445788`  
**Production branch:** `production`  
**Date:** 2026-09-21

## 1. Decision

The Restaurant Performance Review application will use **Neon PostgreSQL** as the application
database platform.

The existing PostgreSQL schema work remains useful as the domain baseline, but any Supabase-specific
authentication, storage, function or environment assumptions must be adapted before deployment.

This is a platform transition, not permission to weaken the previously accepted data-integrity,
RLS, immutability or traceability rules.

## 2. Immediate repository setup

The repository contains the Neon project configuration requested for the project:

- `neon.ts`
- `hello.ts`

The first Neon Function is only a connectivity/deployment probe. It does **not** replace the planned
application API or calculation/import engines.

No connection string, password, API key, JWT secret or service credential is committed to Git.

## 3. Environment policy

The Neon project's `production` branch must not be used for iterative schema development.

Development sequence:

1. repository is linked to project `cold-mouse-53445788`;
2. create a persistent Neon development/preview branch;
3. apply adapted Slice 1 migrations to that non-production branch;
4. run constraint and RLS tests there;
5. connect preview application deployments only to the preview branch;
6. promote reviewed migrations to `production` only after the acceptance path is green.

Production remains protected from CI migration/seed jobs, consistent with
`docs/plan/06-environment-contract.md`.

## 4. What can be reused unchanged

The following database design principles remain valid because Neon is PostgreSQL:

- UUID primary keys;
- composite tenancy foreign keys;
- explicit organisation/outlet scoping;
- PostgreSQL row-level security;
- immutable/versioned records;
- append-only audit history;
- `NULLS NOT DISTINCT` where required;
- indexes shipped with table migrations;
- deterministic canonical facts and calculation results;
- migration tests against real PostgreSQL.

The accepted business/domain structures in Slice 1 therefore remain the starting point.

## 5. What must be adapted before applying migrations

The current Slice 1 files were originally written around Supabase-specific identity assumptions.
Do **not** apply them to Neon production unchanged.

The following items require a Neon-specific implementation after the live project is connected and
its auth objects are inspected:

### Authentication identity

Current assumptions such as:

- foreign keys to `auth.users(id)`;
- use of `auth.uid()`;
- PostgreSQL roles named `authenticated` and `anon`;

must be replaced by the actual Neon Auth identity/JWT integration.

Create one project-level helper, conceptually:

`current_app_user_id()`

All tenant RLS helpers should depend on that abstraction instead of embedding provider-specific JWT
logic throughout the schema.

### Storage

The `uploads` bucket is configured private in `neon.ts`.

The ingestion design still requires:

- private customer files;
- authenticated upload/download;
- short-lived access;
- no public bucket URLs;
- malware/content/file-safety checks before canonical commit.

Exact signed/private-access mechanics will be fixed against the connected Neon project rather than
guessed in advance.

### Functions

`hello.ts` verifies Neon Functions deployment.

The existing architecture uses a server-authoritative application API. We will decide whether any
small operational endpoint belongs in Neon Functions only after the database/auth integration is
working. Financial calculations and canonical import commits remain server-authoritative and must
not migrate into browser code.

## 6. Migration layout

Until the Neon auth inspection is complete, keep the accepted historical files in
`supabase/migrations/` as the reviewed baseline rather than silently rewriting them.

Then create:

`db/migrations/`

for Neon-ready migrations.

The first Neon migration set should be produced by adapting the accepted Slice 1 baseline, not by
starting a second schema design.

Proposed first set:

- `0001_enums_and_reference.sql`
- `0002_tenancy_core.sql`
- `0003_context_settings_materiality.sql`
- `0004_immutability.sql`
- `0005_rls.sql`
- `0006_neon_auth_adapter.sql`

File boundaries may change during implementation, but domain invariants may not.

## 7. Database build order

### Phase N0 — project connection

- connect Neon to ChatGPT/project tooling;
- inspect project, branch, database and auth configuration;
- create non-production development branch;
- verify `neon deploy` with the hello function.

### Phase N1 — auth adapter

- inspect Neon Auth user identifiers and database/JWT claim exposure;
- define `current_app_user_id()`;
- write tests proving unauthenticated access fails closed.

### Phase N2 — Slice 1 tenancy

Create/adapt:

- `organisation`
- `outlet`
- `membership`
- `membership_outlet`
- `staff_assignment`
- `reporting_period`

Preserve the accepted explicit `all_outlets` / `selected_outlets` semantics.

### Phase N3 — context and controls

Create/adapt:

- `restaurant_context`
- `setting`
- `materiality_setting`
- `audit_log`
- platform reference tables.

### Phase N4 — RLS verification

Run the existing tenant-isolation scenarios against Neon:

- organisation A cannot read organisation B;
- selected-outlet membership cannot read unselected outlets;
- selected scope with zero rows grants zero outlets;
- staff assignment respects outlet and expiry;
- outlet-scoped admin cannot expand organisation-wide membership;
- anonymous/unauthenticated access reads no customer rows.

### Phase N5 — application connection

Only after N1–N4 pass:

- wire `/auth/context`;
- implement atomic organisation/outlet bootstrap;
- connect the v4.3 onboarding UI;
- connect the Data Centre later through Slice 2 ingestion.

## 8. GitHub / Neon workflow

Recommended source-control workflow:

`feature branch → GitHub PR → Neon preview/dev branch → migration + RLS tests → application preview → review → merge → controlled production migration`

Do not put database credentials in GitHub files.

When GitHub Actions need Neon access, use repository/environment secrets and least-privilege
credentials. Production migration credentials should not be available to normal PR workflows.

## 9. First acceptance checkpoint

Neon foundation is ready when all of the following are true:

- repository linked to the correct Neon project;
- non-production Neon branch exists;
- `neon deploy` succeeds for the connectivity function;
- Neon Auth identity contract is documented;
- adapted Slice 1 migrations apply from an empty preview database;
- constraint tests pass;
- RLS tests pass;
- no production database/schema was modified during development;
- no Supabase-specific identity reference remains in the Neon-ready migration path.

At that point we can start implementing real database-backed application screens.
