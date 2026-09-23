# Definition of Done

Applies to every story and every work package. A PR that does not satisfy all of it is not
finished, however complete the feature looks.

---

## 1. Correctness

- [ ] Acceptance criteria in `02-backlog.md` all met.
- [ ] Tests exist that **would fail if the code were wrong**. A test that passes against a broken
      implementation is worse than no test — it buys false confidence.
- [ ] Golden parity tests pass. If an expected value changed, the PR either updates the fixture with
      a written justification or states explicitly **"no expected-value change"**. Silent changes
      fail review.
- [ ] Edge cases covered: zero and absent denominators, missing comparators, empty result sets,
      single-row datasets, and the largest fixture (10,500 transaction rows).

## 2. The four non-negotiables

- [ ] No authoritative financial value is computed in the browser.
- [ ] No client path writes canonical facts or calculation results.
- [ ] `calc_engine` and `import_engine` import no database, HTTP or browser library. Tests for them
      run with no database available.
- [ ] `NOT_CALCULATED` is used wherever a value is genuinely absent. **Grep the diff for `or 0`,
      `?? 0`, `|| 0` and `: 0` on a numeric path** — each one is a potential violation of "missing
      is not zero".

## 3. Data integrity

- [ ] New tenant tables carry `organisation_id`, composite tenancy foreign keys, RLS enabled and a
      policy.
- [ ] New unique constraints involving nullable columns use `NULLS NOT DISTINCT` or a `coalesce`
      index. **A unique constraint containing a NULL column enforces nothing.**
- [ ] Immutable records have `BEFORE UPDATE OR DELETE` triggers, not just a comment saying they are
      immutable.
- [ ] Indexes ship with the table, in the same migration.
- [ ] The migration has a stated rollback or forward-fix plan. No destructive migration without one.
- [ ] Migrations are reviewed in the PR by a second pair of eyes.

## 4. Security

- [ ] RLS tested from the perspective of another tenant, not only the happy path.
- [ ] No secret, key or connection string in the diff. No customer data in logs.
- [ ] Uploaded files are validated for type, size and row count before parsing.
- [ ] Storage access is by signed URL only.
- [ ] Staff access to customer data requires an active `staff_assignment` and writes to `audit_log`.

## 5. Accessibility

- [ ] Built from `STATES` primitives. New markup patterns are added to the library, not invented
      in a screen.
- [ ] Automated axe pass with zero violations.
- [ ] Keyboard-operable end to end: focus visible, focus order logical, no keyboard trap.
- [ ] Every table has `scope` on its `<th>` and a `<caption>`.
- [ ] Every field has a visible label. No placeholder-as-label.
- [ ] Explanatory text is in an accessible disclosure, never a `title` tooltip.
- [ ] Works at 320 px width and at 200% zoom.
- [ ] Correct in both light and dark themes.

## 6. Observability

- [ ] Structured logs with a correlation id on every request.
- [ ] Errors reported with enough context to diagnose without reproducing.
- [ ] Long-running operations (calc runs, imports, pack generation) emit start, finish and failure
      events.

## 7. Documentation

- [ ] New `calc_id`s are in `docs/contracts/calc-registry.md` with formula, unit, grain and a
      golden value.
- [ ] New endpoints are in `docs/contracts/api-contract.md`.
- [ ] Schema changes are reflected in the migration README's phase map.
- [ ] A gap from `02-gap-register.md` that this PR closes is marked resolved, with the PR link.
- [ ] Any new decision is added to `05-open-decisions.md` as answered, with its rationale.

## 8. Review

- [ ] CI green: lint, typecheck, unit, golden, RLS, migration dry-run.
- [ ] Reviewed by someone who did not write it.
- [ ] The PR description says what changed, why, and what could break.
- [ ] Demonstrable: a reviewer can run it locally against the Amberside fixture and see the result.

---

## Release gate

Before a slice is called complete:

- [ ] Its slice-level acceptance criteria in `01-development-plan.md` are met.
- [ ] No S1 gap from `02-gap-register.md` remains open in the area it touches.
- [ ] The full golden suite passes against a fresh database seeded from scratch.
- [ ] Preview deployment verified end to end by someone other than the author.
