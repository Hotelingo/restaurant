# Groundwork Review — decisions, v4.3 addendum, WP-02

**Date:** 2026-09-21
**Reviewed:** `9f6df6d` (OD-01 to OD-12), `f886d77` (v4.3 addendum + Slice 1 baseline), `7161115` (WP-02)
**Verdict:** **Accept**, after two test-harness defects fixed in this commit.

---

## 1. What was verified by execution

| Check | Result |
|---|---|
| Migrations 0001–0004 apply to PostgreSQL 16.13 from empty | 15 tables, 25 policies, RLS on all 15 |
| `test_slice1_constraints.sql` | **1 of 8 assertions ran** → fixed → **8/8** |
| `test_slice1_rls.sql` | **18/18** |
| Deliberate-failure probes (3) | All now exit non-zero |
| `check_boundaries.py` with planted violations | Caught all 4 |
| `guard_db_target.py` | 5/5 |
| Golden parity | 13/13 |

---

## 2. Two defects found — both in the test harness, neither in the schema

### D-01 · The constraint suite silently tested almost nothing · **critical**

`test_slice1_constraints.sql` line 72 used `$ ... $` for dollar quoting. That is not valid
PostgreSQL — the valid empty tag is `$$`. The syntax error aborted the transaction, so **every
assertion after it was skipped**: 1 of 8 ran.

Worse, line 13 set `\set ON_ERROR_STOP off`, which **overrode the `-v ON_ERROR_STOP=1` that CI
passes on the command line** (a `\set` inside the script wins). psql therefore exited **0**, and the
CI job reported green while the suite verified one thing.

This is precisely the failure mode the file's own header warns about — "a migration that silently
stops refusing things is a regression that no feature test would catch" — reproduced in the test
that was supposed to catch it.

**Fixed:** `$q$` tagged quoting (matching the RLS suite's convention, which cannot collide with an
inner `$$`), and `ON_ERROR_STOP on` with a comment explaining why it must stay on. Every expected
rejection is caught inside `assert_rejects`, so nothing should ever reach psql as an error; if
something does, it is a genuine failure and must fail the build.

**Verified by three probes**, each of which now exits non-zero:
- an `assert_rejects` whose statement is *not* rejected;
- a syntax error mid-file (the original bug);
- an RLS expectation weakened to a wrong count.

> **The schema itself was never wrong.** Every constraint the broken suite skipped was verified
> manually and all behave correctly: cross-organisation `membership_outlet` rejected, duplicate NULL
> outlet code rejected, `percent_threshold > 1` rejected, `approved_at` without `approved_by`
> rejected, approved materiality immutable.

### D-02 · The `auth.uid()` stub tested one of the two paths production uses · **moderate**

Real Supabase resolves the caller from **either** `request.jwt.claim.sub` (legacy GoTrue) **or**
`request.jwt.claims` JSON:

```sql
coalesce(
  nullif(current_setting('request.jwt.claim.sub', true), ''),
  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
)::uuid
```

The stub in `supabase/tests/README.md` and in CI implemented only the first branch, so the RLS suite
proved the policy logic but not against the function production actually runs.

**Fixed:** both stubs now match Supabase's definition, and both resolution paths are verified.
26/26 assertions still pass.

Also fixed: `do $ begin ... end $;` in the README stub, same dollar-quoting defect.

---

## 3. The decisions (OD-01 to OD-12)

All twelve are answered, and answered well. Several are materially better than the recommendations
they replace:

- **OD-02** adds what the recommendation omitted — **Storage is in scope for backup**, not just
  PostgreSQL. Source files and signed packs are part of the audit lineage, so a database-only backup
  would leave the lineage unrestorable. Concrete RPO ≤ 4h / RTO ≤ 8h.
- **OD-05** adds the immutable-artefact exception the recommendation lacked: delete/revoke the
  artefact and retain a **non-personal tombstone** (pack identity, version, hash, reason, timestamp)
  rather than editing signed bytes. That is the right resolution of the conflict.
- **OD-09** specifies SHA-256 over the **final stored bytes** with pinned renderer, fonts and
  template version. Hashing anything earlier would not be reproducible.
- **OD-11** separates **engine arithmetic tolerance** (one minor currency unit, not customer-editable)
  from **cross-file reconciliation tolerance** (configurable, snapshotted). The recommendation
  conflated them; the answer is correct — an engine tolerance a customer can relax is not a control.
- **OD-10** replaces the flat "2,000 / 2%" proposal with a **relative** basis (≈0.5% of comparator
  monthly net sales, plus 10% of the individual line), and correctly labels the Amberside figures as
  fixture values. Better: a fixed absolute threshold does not scale across outlet sizes.
- **OD-12** adds a clarification worth flagging to everyone: an organisation may hold multiple
  outlets and access control must support them, but **consolidated cross-outlet reporting is not
  R1**. That boundary needs to be visible in the UI, or customers will infer roll-up exists.

**OD-08** is now closed with evidence: `SC23`/`SC24` were superseded by `MN03`/`MN04`, not lost.
Gap G-49 can be marked resolved.

---

## 4. The v4.3 addendum

Closes OD-07 properly. 401 lines, all four journeys, with a route inventory and ten acceptance
scenarios that are genuinely testable rather than aspirational.

The strongest part is §4's **bootstrap architectural rule**. It identifies the RLS chicken-and-egg
problem — the first user cannot hold a membership until the organisation exists — and resolves it
with a server-authoritative `POST /setup/bootstrap` transaction rather than a client insert or an
RLS loophole. The schema agrees: `organisation` has a SELECT and an UPDATE policy and **no INSERT
policy**, so there is no client path to create one. Design and schema are consistent.

Two details worth keeping:
- §8 "submit disables only after the request is accepted" — the opposite of the usual reflex, and
  right, because disabling on click loses the retry when the request never leaves.
- §9 scenario 7: a cross-tenant URL returns the **same neutral treatment as an unknown object**.
  That closes an enumeration side channel most products leak.

---

## 5. WP-02

Genuinely enforcing rather than decorative. The boundary checker was tested with planted
violations and caught all four (web→calc_engine by path and by name, `psycopg2` in `calc_engine`,
`requests` in `import_engine`). The production DB guard covers CI and manual paths with an explicit
acknowledgement escape hatch.

One observation, not a defect: `apps/web` and `api` are **README-only** — no `package.json`,
`tsconfig.json` or `pyproject.toml` anywhere. The boundary checker passes partly because there is
no code to violate the boundaries yet. That is fine for WP-02, but it means WP-03 begins with
framework scaffolding, and the scaffolding choices are not yet decided (see the open question in
§6).

---

## 6. Carried forward

| Ref | Item | Status |
|---|---|---|
| D-01 | Constraint suite gating | Fixed in this commit |
| D-02 | `auth.uid()` stub fidelity | Fixed in this commit |
| — | RLS is still validated against **stubbed** auth, not a real Supabase project. The policy logic is proven; the auth wiring, `service_role` BYPASSRLS behaviour and Storage policies are not. | Validate on a preview project |
| — | Frontend stack specifics undecided: styling approach, component test runner, component workbench. WP-03 cannot start without them, and if not decided they will be decided implicitly by whoever starts. | **Needs a decision** |
| G-49 | `SC23`/`SC24` | Resolved by OD-08 |
