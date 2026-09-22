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
