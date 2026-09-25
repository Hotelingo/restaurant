# API Contract — draft

First draft of the server API. The import endpoints are from
`docs/source/Import_Mapping_Validation_Spec_v0_1.md`; everything else is new, because the source
spec covers imports only and leaves the majority of the application unspecified (G-37).

**Status: accepted for Slice 1 foundation on 2026-09-21.** Later-slice endpoints remain draft until their implementation slice.

---

## 1. Principles

- **All canonical writes happen server-side.** No client path inserts or updates `financial_fact`,
  `calc_result`, a committed `import_batch` or a signed `pack_version`.
- Every request carries a correlation id, echoed in the response and in every log line it produces.
- Authentication is a Neon Managed Better Auth JWT. The API verifies EdDSA tokens against the branch JWKS endpoint, then sets a transaction-local verified user id for PostgreSQL RLS. Organisation and outlet access are resolved from membership, never trusted from a client-supplied parameter.
- Errors use RFC 7807 problem details with a stable `type` per error class.
- Long-running operations (`calc-runs`, `packs`) return `202 Accepted` with a resource to poll.
  See OD-01.
- Mutating endpoints accept an `Idempotency-Key` header. `commit` **requires** one (G-36).

---

## 2. Auth and context

| Method | Path | Notes |
|---|---|---|
| `GET` | `/auth/context` | Implemented foundation endpoint. Caller's organisations, outlets, roles and permissions, resolved through RLS. |
| `POST` | `/organisations/{id}/invitations` | Implemented. Full-organisation admin creates an app-role invitation; only the SHA-256 token hash is persisted. |
| `GET` | `/invitations/{token}/preview` | Implemented public signed-token preview; exposes organisation display name, role/scope, safe inviter display name and expiry, never recipient email. |
| `POST` | `/invitations/{token}/accept` | Implemented. Signed-in account email must match the invitation recipient before membership is created/reactivated. |
| `POST` | `/invitations/{token}/decline` | Implemented. Recipient-only decline. |

## 3. Tenancy and configuration

| Method | Path | Notes |
|---|---|---|
| `POST` | `/setup/bootstrap` | Implemented foundation endpoint. Atomic + idempotent first organisation/outlet creation; caller becomes `admin`. Requires `Idempotency-Key`. |
| `POST` | `/organisations` | Later organisation creation path; creator becomes `admin` |
| `GET` | `/organisations/{id}` | |
| `POST` | `/organisations/{id}/outlets` | Implemented; full-organisation admin only. Currency, timezone, fiscal year start. |
| `GET` | `/outlets/{id}` | |
| `GET` `POST` | `/outlets/{id}/context` | POST implemented in Slice 1; idempotent and versioned, never mutates a prior version. GET remains planned. |
| `GET` `POST` | `/outlets/{id}/settings` | Implemented through `GET /outlets/{id}/controls`, `PUT /outlets/{id}/settings` and atomic `PUT /outlets/{id}/settings/batch`; controlled keys only. |
| `GET` `POST` | `/outlets/{id}/materiality` | POST implemented; approved versions are immutable except controlled retirement of `effective_to`. History is returned by `GET /outlets/{id}/controls`. |
| `GET` `POST` | `/outlets/{id}/periods` | POST implemented in Slice 1; idempotent, overlapping periods rejected by PostgreSQL. GET remains planned. |
| `GET` | `/outlets/{id}/setup-summary` | Implemented for SETUP05; returns only caller-authorised outlet/context/period metadata. |
| `GET` | `/organisations/{id}/members` | Implemented for full-organisation admins; returns application memberships, outlet scope and invitation history. |
| `PATCH` | `/organisations/{id}/members/{membership_id}` | Implemented activate/deactivate control; refuses deactivation of the last full-organisation admin. |
| `GET` | `/organisations/{id}/audit-log` | Implemented; full-organisation admin only, append-only source table. |

## 4. Imports

| Method | Path | Notes |
|---|---|---|
| `POST` | `/imports/upload` | Returns `source_file` and `import_batch`. File-safety checks run **before** parsing (§6) |
| `POST` | `/imports/{batch_id}/parse` | **Implemented for T1/T2/T3/T4A/T6.** Fingerprint, profile match and immutable staging rows; T4A may carry an explicit `effective_from_default`. |
| `GET` | `/imports/{batch_id}/status` | |
| `GET` | `/imports/{batch_id}/exceptions` | **Implemented.** Unmapped accounts/items/product groups and new identities for the supported templates. |
| `POST` | `/imports/{batch_id}/mapping/confirm` | **Implemented for T1/T2/T3/T4A/T6.** Creates a new immutable approved profile version after complete account/item/product-group confirmation. |
| `POST` | `/imports/{batch_id}/validate` | **Implemented for T1/T2/T3/T4A/T6.** Runs mapping/domain validation and returns results by severity. T3 parsed `expected_usage` is a blocking error. |
| `POST` | `/imports/{batch_id}/commit` | **Implemented for T1/T2/T3/T4A/T6. Atomic and idempotent.** Requires `Idempotency-Key`; food-cost canonical inputs do not enter the calculation queue until S5-3. |
| `POST` | `/imports/{batch_id}/supersede` | Explicit confirmation required |
| `GET` | `/templates` · `/templates/{code}/download` | |

**Mappings page.** Saved mappings can be viewed and revised for future uploads.

| Method | Path | Notes |
|---|---|---|
| `GET` | `/outlets/{outlet_id}/mapping-profiles` | **Implemented.** Saved layouts (source profiles) of the outlet with their active version and mapping counts, plus `can_edit` (admin/editor/setup analyst). |
| `GET` | `/mapping-profiles/{source_profile_id}?version_id=` | **Implemented.** One version (default: active) with its account, value, item and column mappings and the approved version history. |
| `POST` | `/mapping-profiles/versions/{profile_version_id}/revisions` | **Implemented.** Requires `Idempotency-Key`. Body `{account_changes:[{source_identity_key, ladder_line_code}], value_changes:[{field_name, source_value, canonical_value}]}`; `field_name` is `management_line`, `product_group` or `labour_activity_basis`. Clones the **active** version into a new approved active version with the changes (`revise_profile_mappings`, migration 0041). Approved versions are never edited: batches already read keep their version. 422 when the version is no longer active ("reload"), nothing changes, or a target is invalid/calculated; 404 outside the caller's access. |

**Profile matching uses active versions only.** `parse` matches a file only against each source
profile's active version, so a revision takes effect on the next file read and two versions of one
layout never make a match ambiguous. When a batch is confirmed without an explicit base, the API
builds on the active version of the batch's candidate profile, so confirming a batch read before a
revision cannot undo it.

**Commit semantics.** One transaction: lock batch → verify no unresolved `block` → verify approved
profile version → resolve approved identity/value mappings → insert the template's canonical fact
family → write deterministic checksum/summary → mark committed → recompute readiness → optionally
queue a supported calc run. **Any
failure commits zero canonical facts.** A retry with the same `Idempotency-Key` returns the original
result without duplicating.

## 5. Calculations, review, packs

| Method | Path | Notes |
|---|---|---|
| `POST` | `/calc-runs` | `202`; body pins review, engine version, settings snapshot |
| `GET` | `/calc-runs/{id}` | **Implemented in Slice 3.** Status, timings, frozen settings and pinned input batches/source files. |
| `GET` | `/calc-runs/{id}/results` | **Implemented in Slice 3.** Filter by `module`, `calc_id`, `grain_type`; returns explicit `NOT_CALCULATED` states and lineage refs. |
| `GET` | `/outlets/{id}/analysis/pnl` | **Implemented in Slice 3.** Page read model for the latest (or selected-period) completed Management P&L run. |
| `GET` | `/outlets/{outlet_id}/analysis/food-cost` | **Implemented in Slice 5.** Reads the latest completed `food-cost-v1` snapshot for the selected outlet/period, groups all eleven persisted FC results by canonical product group, and exposes readiness plus exact T2/T3/T4A batch/profile/source-file lineage. No financial calculation occurs in the API; unavailable prerequisites remain explicit `NOT_CALCULATED` states. |
| `GET` | `/periods/{id}/reconciliation` | **Implemented for the Slice 3 P&L source-line tie-out.** Later cross-module tests remain explicitly `not_tested` until their owning slices exist. |
| `GET` | `/periods/{id}/readiness` | Planned Data Centre read model. |
| `POST` `GET` | `/reviews` · `/reviews/{id}` | **Implemented in Slice 4.** One active review per outlet/period; mutations require `Idempotency-Key`. |
| `POST` | `/reviews/{id}/frame` | **Implemented in Slice 4.** One-time FRAME confirmation pins completed calc run, comparator, effective context version and the calc run's frozen materiality snapshot. |
| `GET` `POST` | `/reviews/{id}/issues` | **Implemented in Slice 4.** Server derives movement amount/rate/materiality from the pinned calc snapshot; 3–5 is guidance, six requires a reason. |
| `PUT` | `/reviews/{id}/issues/order` | **Implemented in Slice 4.** Persists the complete explicit shortlist order atomically. |
| `POST` | `/issues/{id}/diagnosis` · `/issues/{id}/driver-evidence` · `/issues/{id}/evidence-requests` | **Implemented in Slice 4.** Mutations require `Idempotency-Key`; diagnosis versions are append-only and evidence quantification is gated by evidence status. |
| `GET` | `/issues/{id}/evidence` | **Implemented in Slice 4.** SC12 read model: latest diagnosis, immutable diagnosis history, driver evidence and evidence requests. |
| `POST` | `/evidence-requests/{id}/fulfill` | **Implemented in Slice 4.** Links an open request to a committed batch from the same outlet; does not automatically claim the evidence supports a cause. |
| `POST` | `/issues/{id}/decision` | **Implemented in Slice 4.** Requires `Idempotency-Key`; Pydantic mirrors the five disposition requirements, while PostgreSQL remains authoritative for G-06 and the evidence gate. |
| `GET` | `/issues/{id}/decisions` | **Implemented in Slice 4.** Returns the one active disposition plus immutable decision revision history. |
| `GET` `POST` | `/reviews/{id}/actions` · `/decisions/{id}/actions` | **Implemented in Slice 4.** Actions pin an immutable decision revision; creation is idempotent. |
| `POST` `GET` | `/actions/{id}/status` · `/actions/{id}/events` | **Implemented in Slice 4.** Controlled status updates append immutable action history; closing requires closure evidence. |
| `POST` `GET` | `/actions/{id}/verification` · `/actions/{id}/verifications` | **Implemented in Slice 4.** Next-period checks record completed?, driver moved?, result responded? with immutable close/reopen outcomes. |
| `GET` | `/outlets/{outlet_id}/periods/{period_id}/prior-actions` | **Implemented in Slice 4.** SC13 read model resolves the immediately preceding reporting period and returns its actions plus any verification for the selected current period. |
| `GET` | `/reviews/{id}/gates` | **Implemented in Slice 4.** Evaluates the eleven-condition deterministic RG contract against the latest pack and returns actionable failures; there is no override path. |
| `POST` | `/reviews/{id}/packs` | **Implemented in Slice 4.** Idempotent Owner Pack version creation; pins the review's one confirmed completed calc run. |
| `GET` | `/packs/{id}` · `/packs/{id}/claims` | **Implemented in Slice 4.** Returns version metadata, immutable calc citations and current server claimCheck state. |
| `POST` | `/packs/{id}/claims/{claim_id}/accept` | **Implemented in Slice 4.** Reviewer-only acceptance reruns `claimCheck` server-side and rejects on numeric/citation/banned-word failure. `reject`, `edit` and `check` companion endpoints are also implemented. |
| `POST` | `/packs/{id}/render` | **Implemented in Slice 4.** Deterministically renders the current reviewed Owner Pack to UTF-8 HTML, writes it to the private pack-scoped storage path, and stores byte SHA-256 + authoritative source-snapshot SHA-256 through a server-only attachment function. |
| `GET` | `/packs/{id}/artifact-url` | **Implemented.** Returns a 5-minute signed URL only for a signed pack with final artefact SHA-256 metadata. |
| `POST` | `/packs/{id}/signoff` | **Implemented in Slice 4.** Reviewer-only `signed` or `changes_requested`; signing requires a passing server RG snapshot **and a current artefact source hash** (stale/missing renders are rejected), then persists reviewer identity, exact calc run, reviewed/not-reviewed scope and caveat. |
| `GET` `POST` | `/reviews/{id}/comments` | **Implemented in Slice 4.** Threaded immutable comments with role and resolution status; reviewer-only resolution endpoint is `/reviews/{id}/comments/{comment_id}/resolve`. |
| `GET` | `/reviews` | Review list, filterable by outlet and period |
| `GET` | `/reviews/{id}/history` | **Implemented in Slice 4.** Full Owner Pack version history with each pinned calc run and every request-changes/sign decision. |

## 6. File safety — G-35

Slice 2 implements the application controls below. Operational malware scanning and deployed
storage credentials still require environment configuration before preview/production upload is
declared ready:

| Control | Proposed baseline |
|---|---|
| Maximum file size | 25 MB |
| Maximum rows per file | 250,000 (the transaction fixture is 10,500) |
| Upload timeout | 60 s |
| Accepted content types | `text/csv`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` — verified by **content inspection**, not by extension or client-supplied header |
| XLSX formula injection | Values-only R1: workbooks containing formula cells, macros or external links are rejected before storage/parsing |
| Zip bomb | Decompressed-size and entry-count limits before extraction |
| Malware | ClamAV INSTREAM scan before storage; preview/production fail closed when scanner is unavailable; local/test bypass is explicit |
| Storage access | Private Neon `uploads` bucket; server writes; downloads use 5-minute presigned URLs only |
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
| `insufficient-scope` | 403 | Role forbids an action on a resource already known in the authorised context. Cross-tenant or unknown resource lookups use the same neutral 404 treatment to prevent enumeration. |
| `staff-assignment-required` | 403 | Staff access without an active assignment |

`not-calculated` is listed here deliberately: it must never be represented as an error, an empty
response or a zero. It is a first-class result state.
