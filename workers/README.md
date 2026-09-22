# Calculation worker

Dedicated background execution for long-running Restaurant Performance Review jobs.

The R1 P&L worker consumes the durable PostgreSQL `calculation_request_queue`, claims work with
`FOR UPDATE SKIP LOCKED`, creates an immutable `calc_run`, freezes the outlet/settings/materiality
snapshot, loads only committed canonical facts, calls the pure `packages/calc_engine` PL module,
and persists results plus dependency/fact lineage. It also runs the pure first material movement
sequence from the frozen approved general materiality snapshot; the worker does not infer operating
causes or recurrence/risk events. No financial formula lives in the worker.

## Reliability model

- every claim has a database lease and attempt number;
- expired leases fail the abandoned running calc attempt and allow a fresh immutable retry;
- queue retries append new `calc_run` attempts rather than editing partial history;
- completed requests point to the completed run;
- identical inputs can be rerun through a new queue request and produce the same deterministic result hash;
- application/client sessions have no write path to calc persistence or worker queue functions;
- logs contain request/run identifiers and error codes, not customer financial values.

## Run

Set `DATABASE_URL` to a trusted server/worker database credential, then:

```bash
python -m workers.pl_worker --once
# or continuous polling
python -m workers.pl_worker
```

Environment controls: `CALC_WORKER_ID`, `CALC_WORKER_POLL_SECONDS`,
`CALC_WORKER_LEASE_SECONDS`, `CALC_WORKER_MAX_ATTEMPTS`, and `LOG_LEVEL`.

The included `workers/Dockerfile` is intentionally provider-neutral so the same image can run on
Render, Fly.io, Railway, or another container host without changing the orchestration contract.


## Food Cost worker path

The same durable queue worker now dispatches by source template/reason. PL requests continue to pin
only T1/T6; Food Cost requests pin exactly one committed T2 item-sales batch, one T3 stock batch,
and one T4A approved-item-cost batch for the outlet/period. PL and Food Cost supersession chains
are isolated by engine version.

Food Cost uses `food-cost-v1` and persists eleven stable FC results per canonical product group:
the eight two-story bridge results, supported-driver total, residual, and decision path. Expected
usage is derived only from T2 units × the latest T4A cost effective on or before period end.
T3 `Expected_Usage` is never read by the worker.

The decision path uses the approved materiality snapshot, the actual-vs-expected signal and its
reconciled residual; budget gap remains context only. Result hashes exclude random row ids, so an
identical rerun creates a new immutable calc run with the same deterministic result hash.
