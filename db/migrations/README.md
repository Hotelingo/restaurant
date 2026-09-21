# Neon database migrations

These are the Neon-native Slice 1 migrations for Restaurant Performance Review.

They adapt the previously accepted PostgreSQL domain model to Managed Better Auth and a
server-authoritative FastAPI access model.

## Runtime identity

FastAPI verifies the Neon Auth JWT. For every database transaction it executes:

```sql
select set_config('app.user_id', '<verified JWT sub>', true);
```

RLS resolves identity through `current_app_user_id()`.

The application connects as the non-owner PostgreSQL role `restaurant_app`; application traffic
must never connect as `neondb_owner`, otherwise table ownership can bypass ordinary RLS behavior.

## Apply order

1. 0001_reference.sql
2. 0002_tenancy.sql
3. 0003_context_controls.sql
4. 0004_immutability.sql
5. 0005_rls.sql
6. 0006_bootstrap.sql

Use a direct/unpooled connection for migrations. Use the pooled application connection for normal
API traffic.

## Environments

Develop against Neon branch `slice1-neon-foundation` (or another feature branch), never directly
against `production`.

No secrets belong in this directory.


## Slice 2 additions

- 0011_import_mapping.sql — source profiles, immutable profile versions and mapping tables.
- 0012_ingestion_persistence.sql — immutable source-file metadata, import-batch lifecycle,
  immutable staging rows, structured validation results and explicit supersede semantics.
- 0013_source_file_safety.sql — accepted file type/size/row caps plus required malware-scan and
  inspection metadata for every persisted raw source file.

The full canonical commit transaction remains a later step because canonical financial facts are
introduced with Slice 3. Do not mark S2-6 complete merely because the batch lifecycle exists.


## Slice 3 canonical finance prerequisite

- 0014_financial_facts.sql — seeds the v1 Management P&L ladder and adds the immutable
  account/financial_fact canonical model. Actuals require account grain. Budget, forecast and
  prior-year comparators may be account-grain or ladder-grain; ladder-grain rows never require
  synthetic accounts.

Canonical tables are SELECT-only to restaurant_app. The server-side atomic import-commit function
is the only planned writer.


## Atomic T1/T6 commit

- 0015_atomic_financial_commit.sql — single-transaction T1/T6 commit, idempotency response,
  deterministic canonical checksum, Management P&L readiness state and optional durable calculation
  request. A private fault-injection helper is EXECUTE-revoked from public/application roles and
  exists only so PostgreSQL CI can prove rollback after each of the nine commit steps.
