# Server API boundary

Target: FastAPI + Python.

The API is the server-authoritative orchestration layer for:
- auth/context checks;
- organisation/outlet bootstrap;
- uploads and import commits;
- calculation runs;
- review gates;
- Owner Pack generation;
- signed URLs.

It may call `packages/calc_engine` and `packages/import_engine`.

Every request must carry/emit a correlation id. Mutations must follow the API contract and use
idempotency where specified. The browser never receives service-role credentials.
