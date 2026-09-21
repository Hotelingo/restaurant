# API Contract — draft

First draft of the server API. The import endpoints are from
`docs/source/Import_Mapping_Validation_Spec_v0_1.md`; everything else is new, because the source
spec covers imports only and leaves the majority of the application unspecified (G-37).

**Not yet accepted.** Review alongside the calc registry before slice 1.

---

## 1. Principles

- **All canonical writes happen server-side.** No client path inserts or updates `financial_fact`,
  `calc_result`, a committed `import_batch` or a signed `pack_version`.
- Every request carries a correlation id, echoed in the response and in every log line it produces.
- Authentication is a Supabase JWT; the API resolves organisation and outlet context from
  membership, never from a client-supplied parameter.
- Errors use RFC 7807 problem details with a stable `type` per error class.
- Long-running operations (`calc-runs`, `packs`) return `202 Accepted` with a resource to poll.
  See OD-01.
- Mutating endpoints accept an `Idempotency-Key` header. `commit` **requires** one (G-36).

---

## 2. Auth and context

| Method | Path | Notes |
|---|---|---|
| `GET` | `/auth/context` | Caller's organisations, outlets, roles, permissions |
| `POST` | `/auth/invitations` | Admin invites a user to an organisation with a role |
| `POST` | `/auth/invitations/{token}/accept` | |

## 3. Tenancy and configuration

| Method | Path | Notes |
|---|---|---|
| `POST` | `/organisations` | Creator becomes `admin` |
| `GET` | `/organisations/{id}` | |
| `POST` | `/organisations/{id}/outlets` | Currency, timezone, fiscal year start |
| `GET` | `/outlets/{id}` | |
| `GET` `POST` | `/outlets/{id}/context` | Versioned; POST creates a new version, never mutates |
| `GET` `POST` | `/outlets/{id}/settings` | |
| `GET` `POST` | `/outlets/{id}/materiality` | Versioned; requires approver |
| `GET` `POST` | `/outlets/{id}/periods` | Overlapping periods rejected |
| `GET` `POST` `DELETE` | `/organisations/{id}/members` | |

## 4. Imports

| Method | Path | Notes |
|---|---|---|
| `POST` | `/imports/upload` | Returns `source_file` and `import_batch`. File-safety checks run **before** parsing (§6) |
| `POST` | `/imports/{batch_id}/parse` | Fingerprint, profile match, staging rows |
| `GET` | `/imports/{batch_id}/status` | |
| `GET` | `/imports/{batch_id}/exceptions` | Unmapped accounts/items, new identities |
| `POST` | `/imports/{batch_id}/mapping/confirm` | Creates or updates a draft `profile_version` |
| `POST` | `/imports/{batch_id}/validate` | Runs the rule set; returns results by severity |
| `POST` | `/imports/{batch_id}/commit` | **Atomic, idempotent.** Rejects unresolved `block` severities |
| `POST` | `/imports/{batch_id}/supersede` | Explicit confirmation required |
| `GET` | `/templates` · `/templates/{code}/download` | |

**Commit semantics.** One transaction: lock batch → verify no unresolved `block` → verify approved
profile version → persist resolved mappings onto facts → insert canonical facts → write fact
count/total checksum → mark committed → invalidate readiness → optionally queue a calc run. **Any
failure commits zero canonical facts.** A retry with the same `Idempotency-Key` returns the original
result without duplicating.

## 5. Calculations, review, packs

| Method | Path | Notes |
|---|---|---|
| `POST` | `/calc-runs` | `202`; body pins review, engine version, settings snapshot |
| `GET` | `/calc-runs/{id}` | Status, timings, inputs |
| `GET` | `/calc-runs/{id}/results` | Filter by `module`, `calc_id`, `grain_type` |
| `GET` | `/periods/{id}/readiness` · `/reconciliation` | |
| `POST` `GET` | `/reviews` · `/reviews/{id}` | One active review per outlet/period |
| `POST` | `/reviews/{id}/frame` | Comparator, context version, materiality snapshot |
| `GET` `POST` | `/reviews/{id}/issues` | Shortlist with order |
| `POST` | `/issues/{id}/diagnosis` · `/driver-evidence` · `/evidence-requests` | |
| `POST` | `/issues/{id}/decision` | Requirements enforced by DB constraint, not only by the gate engine |
| `GET` `POST` | `/reviews/{id}/actions` · `/actions/{id}/events` | |
| `GET` | `/reviews/{id}/gates` | `RG` failures. **Returns failures; cannot be overridden** |
| `POST` | `/reviews/{id}/packs` | `202`; pins exactly one completed calc run |
| `GET` | `/packs/{id}` · `/packs/{id}/claims` | |
| `POST` | `/packs/{id}/claims/{claim_id}/accept` | Runs `claimCheck` server-side; rejects on failure |
| `POST` | `/packs/{id}/signoff` | `signed` or `changes_requested`, with caveat |
| `GET` `POST` | `/reviews/{id}/comments` | Threaded, with resolution status |
| `GET` | `/reviews` | History, filterable by outlet and period |

## 6. File safety — G-35

Currently unspecified anywhere in the source documents, on a product that accepts arbitrary
spreadsheets from the public internet. Baseline for slice 2:

| Control | Proposed baseline |
|---|---|
| Maximum file size | 25 MB |
| Maximum rows per file | 250,000 (the transaction fixture is 10,500) |
| Upload timeout | 60 s |
| Accepted content types | `text/csv`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` — verified by **content inspection**, not by extension or client-supplied header |
| XLSX formula injection | Formulas neither evaluated nor stored; cell values read as text and parsed explicitly |
| Zip bomb | Decompressed-size and entry-count limits before extraction |
| Malware | Scan before parse; quarantine on detection |
| Storage access | Signed URLs only, short expiry. No public bucket access |
| Rate limiting | Per organisation and per user, on upload and calc-run creation |

## 7. Error classes

| `type` | HTTP | Meaning |
|---|---|---|
| `validation-failed` | 422 | Unresolved `block` severities; body lists them |
| `mapping-required` | 409 | New identities need human confirmation |
| `duplicate-batch` | 409 | Requires explicit supersede |
| `immutable-record` | 409 | Attempt to modify a committed, completed or signed record |
| `gate-failed` | 409 | Review gate conditions unmet; body lists each failure |
| `claim-check-failed` | 422 | Claim contains numbers absent from engine output, or banned wording |
| `not-calculated` | 200 | **Not an error.** A result whose `calculation_status` is `not_calculated`, carrying an `explanation_code` |
| `insufficient-scope` | 403 | Role or outlet scope forbids the action |
| `staff-assignment-required` | 403 | Staff access without an active assignment |

`not-calculated` is listed here deliberately: it must never be represented as an error, an empty
response or a zero. It is a first-class result state.
