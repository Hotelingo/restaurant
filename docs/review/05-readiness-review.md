# Readiness Review — first user testing

**Date:** 2026-09-23
**Scope:** integration branch `claude/funny-allen-rasy71` at `639950b` (Slices 1–8 merged), plus
the fixes in this review.
**Method:** every suite executed; the whole stack run locally (PostgreSQL, a Better Auth stand-in
for Neon Auth, S3, API, worker, web); a first user's journey driven over HTTP **as the
RLS-enforced runtime role**; every built screen opened in Chromium.

---

## 1. Verdict

**The backend is ready for first user testing. The frontend is not.**

The database, calculation engines, worker and API are verified end to end. A real signed-up user
can go from sign-up to a correct Management P&L — all eleven golden values exact — through the
live API, under row-level security, using the untouched Amberside files. That is a strong position.

But the browser offers only about a quarter of that path. **A tester cannot upload a file**: the
Data Centre is a placeholder, although its whole backend exists. The review loop — FRAME,
shortlist, decisions, actions, Owner Pack, sign-off — has **no screens at all**, although all 72
API operations behind it are built and pass CI.

The backend has run roughly five slices ahead of the UI. **The critical path to first user
testing is now almost entirely frontend and deployment plumbing, not more backend.**

---

## 2. Health scorecard

| Area | Result | Notes |
|---|---|---|
| Golden parity | **13/13** | Fixture unchanged since 2026-09-21 |
| Calculation engine | **63/63** | |
| Import engine | **75/75** | |
| Review-gate engine | **11/11** | |
| Worker unit | **11/11** | |
| API unit | **90/90** | Mocks the database — see §4 |
| Database + integration (CI-equivalent) | **85/85** | 39 migrations (incl. new `0038`), 26 contract/RLS suites, 4 worker runs end-to-end, R1 twelve-step acceptance |
| Web | **green** | typecheck, axe on primitives, password policy, production build |
| **Live first-user journey (new)** | **30/30** | Over HTTP, as `restaurant_app`, real auth session |
| Architecture boundaries | **pass** | Re-tested with planted violations: all caught |
| Test gating | **genuine** | Deliberate-failure probes exit non-zero; no `ON_ERROR_STOP off` anywhere |

### Efficiency

Measured on the live API with statement logging on the runtime role:

| Endpoint | SQL statements | Latency (local) |
|---|---|---|
| `/auth/context` | 4 | 5 ms |
| `/outlets/{id}/analysis/pnl` | 3 | 14 ms |
| `/periods/{id}/reconciliation` | 2 | 13 ms |
| `/calc-runs/{id}/results` | 2 | 10 ms |
| food-cost / revenue / labour-other read models | 2 each | 7–8 ms |
| controls, members, audit-log, reviews | 2 each | 7–18 ms |

**No N+1 queries anywhere.** Every read model is one set-based query plus the per-transaction
`set_config`. The data layer is efficient. The one real inefficiency was in the browser — a new
JWT fetched before every API call, which doubled round-trips (fixed, §3).

---

## 3. Defects found and fixed in this review

Six defects, **none of which any CI job could see.** Each was reproduced first, then fixed and
verified.

| # | Defect | Impact | Root cause | Fix |
|---|---|---|---|---|
| **D1** | `GET /outlets/{id}/analysis/pnl` returned **500 on every request** | The P&L screen could never load | `like 'pl-%'` in a parameterised query; psycopg reads the lone `%` as a malformed placeholder | `%%` — `analysis.py` |
| **D2** | `GET /periods/{id}/reconciliation` returned **500 on every request** | The Reconciliation screen could never load | Same | Same |
| **D3** | `GET /calc-runs/{id}/results?module=…` returned **500** | Module-filtered results unusable | Same, in a single-quoted literal | Same |
| **D4** | **Upload and parse failed for every real user** | A tester could never get data in | Both routes inserted into `audit_log`, which has no INSERT policy for `restaurant_app`. Every other audit event is written by a `SECURITY DEFINER` function | Migration `0038`: a narrow `record_import_audit_event()` that derives actor and tenant server-side, applies the import routes' own role check, and accepts only the two import action codes |
| **D5** | P&L showed **cost overspends in green** | A finance user would distrust the screen on sight | One renderer coloured every figure by sign — so Direct Labour's +5,205 overspend was green, contradicting the page's own sign-convention banner | Only `profit_effect` is coloured; actuals, comparators and raw deltas are neutral |
| **D6** | Reconciliation page showed a **false "session expired"** | Any page making two API calls could fail | `apiFetch` fetched a new JWT before *every* call; back-to-back calls raced and the second came back empty | In-memory token reuse until shortly before `exp`, one shared in-flight request, one retry on 401 |

**On D6 — a security trap avoided.** Sign-out here is client-side navigation, so an in-memory
token cache survives it. Left alone, a second person signing in on the same tab could have sent
the previous user's token. The cache is therefore cleared on sign-out and **during render** of
every `/auth/*` page. It has to be render, not an effect, because React runs child effects before
parent effects. **Verified:** user A loads data and signs out, user B signs in on the same tab,
and B's first `/auth/context` call carries B's own token. B lands on organisation setup and never
sees A's organisation.

### Guards added so these classes of defect cannot return

| Guard | Catches | Where |
|---|---|---|
| `tests/architecture/test_sql_percent_escaping.py` | Any unescaped `%` in any SQL literal in the API or worker (D1–D3) | CI architecture job. Standard library only; verified to fail on a reintroduced bug |
| `db/tests/test_import_audit_writer.sql` | The audit writer working, **and** being unusable to forge history across tenants, by a viewer, for other action codes, or unauthenticated (8 assertions) | CI database job |
| `dev/local-stack/first_user_journey.py` | Anything that only breaks over HTTP under RLS (D1–D4) | Runs locally today; recommended as a CI job (§5, Q1) |

---

## 4. Why CI missed all six

This matters more than the defects themselves.

1. **The API unit tests mock the database connection.** SQL text never reaches psycopg, so a
   malformed placeholder cannot fail a test. Ninety green tests exercised none of the SQL.
2. **The CI integration steps connect as `postgres`, a superuser that bypasses RLS.** The R1
   twelve-step acceptance proves the domain logic, but not that the runtime role can perform it.
   D4 was invisible for exactly this reason.
3. **Nothing in CI renders a real page.** The axe gate checks primitives via static markup. D5
   and D6 are only visible in a browser.

The backend's own design is sound — the runtime-role hardening in migration `0031` is exactly
right. The test harness simply never runs as that role over HTTP. **Closing that gap is the
single highest-leverage quality investment available** (Q1).

---

## 5. Open findings — not fixed here

Ranked. **B** blocks hosted user testing · **Q** quality/test risk · **P** product gap against an
agreed decision · **M** maintainability.

### Blocks hosted user testing

| # | Finding | Recommendation |
|---|---|---|
| **B1** | **No migration ledger.** Migrations are applied by filename glob from an empty database; all 60 `create table` statements are non-idempotent. A persistent Neon preview branch cannot be upgraded safely — re-running the glob fails on the first existing table. The README's "apply order" stops at `0006`. Two files share the number `0031`, which would collide in any version-keyed tool. | Adopt a small runner with a `schema_migrations` ledger (or dbmate/Atlas); renumber `0031_runtime_role_hardening` **before** the first persistent environment exists, since afterwards it is a ledger migration problem |
| **B2** | **No recalculation endpoint.** A calculation is queued only by `POST /imports/{id}/commit?queue_calc=true`, which defaults to `false`. Commit T1 without the flag and there is no way, through the API, to ever calculate it. | Add `POST /periods/{id}/calc-runs` (idempotent, `202`). The Data Centre UI then commits and calculates as separate, visible steps |
| **B3** | **Worker database role undefined.** `claim_calculation_request` is granted to no role, so the worker must run as the database owner. This is undocumented, and `docs/plan/06-environment-contract.md` still describes Supabase service-role keys. | Create a `restaurant_worker` role holding only the worker functions; document the credential split |
| **B4** | **Malware scanning is required outside local/test/CI.** Uploads correctly fail closed without it, so any hosted preview will refuse every upload until ClamAV is deployed. | Deploy clamd alongside the API; set `CLAMAV_HOST` |
| **B5** | **Hosting not configured.** Web is not connected to Vercel; API and worker hosts are not chosen. OD-01 selected a containerised worker (`workers/Dockerfile` exists). | Web → Vercel; API → a container host alongside the worker; one Neon preview branch |

### Quality and test risk

| # | Finding | Recommendation |
|---|---|---|
| **Q1** | CI never exercises the API over HTTP as `restaurant_app` (§4). | Turn `dev/local-stack` into a CI job: Postgres service + auth stand-in + moto + API + `first_user_journey.py`. Extend it slice by slice |
| **Q2** | No browser end-to-end tests. The axe gate covers primitives only, through static render — 25 rules, no colour contrast, no keyboard behaviour. | Playwright against the local stack for the tester journeys, with axe per page |
| **Q3** | No `package-lock.json` committed; CI runs `npm install` against **beta** auth packages (`@neondatabase/auth 0.5.0-beta`, `auth-ui 0.3.0-beta`). Builds are not reproducible, and a beta bump can break sign-in silently. | **Done in this review:** lockfile committed (beta packages now pinned by it); CI switched to `npm ci` |
| **Q4** | Stale artefacts: the `supabase/` tree and its `slice1-database` CI job test a schema that is no longer deployed, so a green result is misleading. `hello.ts` / `neon.ts` Neon Functions scaffold at the repo root. `06-environment-contract.md` still describes Supabase. | Delete the job and tree after confirming nothing depends on them; confirm whether `neon.ts` is used by Neon config; rewrite 06 |

### Product gaps against agreed decisions

| # | Finding | Recommendation |
|---|---|---|
| **P1** | **The Owner Pack renders HTML** (`server-html-v1`). OD-09 decided on server-side **PDF** from a pinned renderer, with a SHA-256 over the final stored bytes. | HTML is fine for a first test. PDF before any tester treats a pack as a signed deliverable |
| **P2** | **No navigation shell.** The v4.2 six-area navigation is absent; each page is a floating panel. App home is a small card, and **does not link to the Data Centre.** | Build the shell first in the UI track — every later screen hangs off it |
| **P3** | User-facing copy leaks internal jargon: "Slice 2 will add…" (Data Centre), "This Slice 3 reconciliation…" | Remove as those screens are built |
| **P4** | Setup asks a restaurant owner for a "URL-safe slug". | Derive it from the organisation name; allow edit |
| **P5** | Invitations are copy-link only; no email is sent. The UI says so honestly. | Acceptable for a first test with a handful of testers |
| **P6** | Slice 8 C02: the engine and evidence schema exist, but **nothing is wired** — no worker, API or UI. | Leave until the review loop has a UI; C02 is only reachable from it |
| **P7** | `Toast` primitive missing from the v4.3 §7 set. | Add with the mutation-heavy review screens |

### Maintainability

| # | Finding |
|---|---|
| **M1** | `workers/pl_worker.py` is 2,702 lines handling four modules (P&L, Food Cost, Revenue, Labour/Other) despite its name; four `prepare_*_run` functions of 206–356 lines each. Split per module behind a small dispatcher before C02 and Menu are added. |
| **M2** | `import_workflow.py`: `validate_import_batch` is 522 lines and `parse_import_batch` 491. Extract per-template strategies. |
| **M3** | `formatAmount` is duplicated across the two analysis clients; move it to `lib/format.ts` before the next four analysis screens copy it again. |

---

## 6. Readiness map — the first user's journey

Each step of the journey a first tester must complete, by layer.
✅ built and verified · ⚠️ built with a caveat · ❌ missing

| # | Journey step | DB | Engine / worker | API | **UI** |
|---|---|---|---|---|---|
| 1 | Sign up, sign in, password reset | ✅ | — | ✅ | ✅ |
| 2 | Invite a colleague | ✅ | — | ✅ | ⚠️ copy-link only (P5) |
| 3 | Create organisation, outlet, context, period | ✅ | — | ✅ | ✅ |
| 4 | Settings, materiality, members, audit log | ✅ | — | ✅ | ✅ |
| 5 | **Upload P&L and budget files** | ✅ | ✅ | ✅ (D4 fixed) | ❌ **placeholder** |
| 6 | **Map accounts (mapping wizard)** | ✅ | ✅ | ✅ | ❌ |
| 7 | **Validate and commit** | ✅ | ✅ | ✅ | ❌ |
| 8 | Calculate | ✅ | ✅ | ⚠️ commit flag only (B2) | ❌ |
| 9 | Management P&L + first material movement | ✅ | ✅ | ✅ (D1 fixed) | ✅ (D5 fixed) |
| 10 | Reconciliation | ✅ | ✅ | ✅ (D2 fixed) | ✅ (D6 fixed) |
| 11 | **Start review, FRAME** | ✅ | ✅ | ✅ | ❌ |
| 12 | **Shortlist issues** | ✅ | ✅ | ✅ | ❌ |
| 13 | **Diagnose, evidence, decide** | ✅ | ✅ | ✅ | ❌ |
| 14 | **Action register, prior-action check** | ✅ | ✅ | ✅ | ❌ |
| 15 | **Owner Pack, claims, claimCheck** | ✅ | ✅ | ⚠️ HTML not PDF (P1) | ❌ |
| 16 | **Reviewer comments, gates, sign-off** | ✅ | ✅ | ✅ | ❌ |
| 17 | Packs and history | ✅ | — | ✅ | ❌ |
| 18 | Food Cost analysis (T2/T3/T4A) | ✅ | ✅ | ✅ | ❌ |
| 19 | Revenue and Contribution (T1B/T7) | ✅ | ✅ | ✅ | ❌ |
| 20 | Labour and Other Costs (T5) | ✅ | ✅ | ✅ | ❌ |
| 21 | C02 driver tests | ✅ | ✅ engine only | ❌ | ❌ |
| 22 | Menu SCREEN / TRAIL / TEST | ❌ | ❌ | ❌ | ❌ |

**Count:** of the 17 steps that make up R1's core loop (1–17), the backend covers **all 17** and the
UI covers **6**.

### Deployment readiness for a hosted test

| Need | State |
|---|---|
| Neon preview branch with the schema | ❌ blocked on a migration ledger (B1) |
| API hosted | ❌ (B5) |
| Worker hosted, least-privilege role | ❌ (B3, B5) |
| Malware scanning | ❌ required, or uploads fail closed (B4) |
| Web on Vercel | ❌ not connected |
| Neon Auth: email for magic link and reset | ⚠️ provided by Neon Auth; not verifiable from this sandbox |
| Restore drill (OD-02) | ❌ required before production, recommended before external testers |

---

## 7. What can finish first — yes, in three testable milestones

The answer to "can we finish some parts before others" is **yes**, and it should be done that
way. Each milestone below is independently testable with real users.

```
                 Track A · Frontend          Track B · Platform           Track C · Backend (small)
               ─────────────────────────   ─────────────────────────   ─────────────────────────
  M0 Stabilise  merge this review           migration ledger (B1)       recalc endpoint (B2)
   (days)       nav shell (P2)              lockfile + npm ci (Q3)      worker role (B3)
                                            drop stale supabase job
               ─────────────────────────   ─────────────────────────   ─────────────────────────
  M1 "Data in"  Data Centre: upload →       Neon preview branch         —
   ★ FIRST      parse → mapping wizard →    API + worker hosted
   USER TEST    validate → commit →         ClamAV (B4)
                calculate                   Vercel web
                                            CI HTTP journey (Q1)
               ─────────────────────────   ─────────────────────────   ─────────────────────────
  M2 "Review"   FRAME → shortlist →         Playwright e2e (Q2)         PDF renderer (P1)
   ★ R1 CORE    diagnose/decide → actions   restore drill (OD-02)
                → Owner Pack → sign-off
               ─────────────────────────   ─────────────────────────   ─────────────────────────
  M3 "Depth"    Food Cost, Revenue,         —                           wire C02 (P6)
                Labour/Other screens                                    split the worker (M1)
                (read models exist)
```

### M1 — "Can I get my numbers in, and do I trust the P&L?" ★ recommended first user test

A tester signs up, uploads their own P&L and budget, maps their accounts once, and sees a
reconciled Management P&L with the first material movement. **Everything behind that exists and
is verified**; the P&L and Reconciliation screens are already built and correct. What remains is
the Data Centre UI, the recalculation endpoint, and hosting.

It is a genuinely valuable test by itself. Mapping is where a first-time user is most likely to get
stuck, and whether they trust the P&L is the product's first moment of truth. Put that in front of
real users **before** building the review loop on top of it.

### M2 — "Can I run a review and sign a pack?" ★ R1 core complete

Screens only. The APIs exist and the twelve-step acceptance already passes in CI.

### M3 — analytical depth

Screens only for Food Cost, Revenue and Labour/Other. Their read models, workers and ingestion are
already built.

### What to stop

**Pause new backend slices — Menu (Slice 9) and the C02 wiring — until the UI reaches M2.** Every
further backend slice widens the surface that no user can reach and no browser test covers. That
is exactly the surface where this review found its defects. The API is already ahead by about five
slices; more backend now adds risk, not progress.

---

## 8. Decisions needed

1. **Adopt M1 as the first user test**, ahead of the review loop? (Recommended.)
2. **Pause Slice 9 / C02 wiring** until the UI reaches M2? (Recommended.)
3. **Migration tool:** a hand-rolled ledger runner, or dbmate/Atlas? Either works; decide before the
   first persistent Neon branch.
4. **API hosting:** the same container host as the worker (simplest, per OD-01), or Vercel Python
   functions? A container is recommended: uploads take up to 60 seconds, and ClamAV must sit
   alongside the API.
5. **Neon access for automated verification:** today this sandbox can reach neither Neon (network
   policy denies `console.neon.tech`) nor any credentials. The local stack substitutes faithfully
   for everything except Neon-specific behaviour (branching, pooling, managed-auth email).

---

## 9. Evidence

Screenshots, taken in Chromium against the local stack after the fixes (`screens/2026-09-23/`):

| Screen | File |
|---|---|
| App home: a small card, no navigation shell, no Data Centre link (P2) | `app-home.png` |
| Data Centre: a placeholder with internal jargon (P3), and the first-user blocker | `data-centre-placeholder.png` |
| Management P&L: all eleven golden values; only profit effect coloured (D5) | `pnl-desktop.png` |
| Management P&L at 390 px: no horizontal overflow | `pnl-mobile-390.png` |
| Reconciliation: all seven lines tie to zero, loading reliably (D2, D6) | `reconciliation.png` |
| Organisation setup, as user B after user A signed out on the same tab (D6 safety) | `setup-organisation.png` |
- Reproduce: `dev/local-stack/README.md`, then
  `python dev/local-stack/first_user_journey.py <worker-db-url>` → `RESULT: 30 ok, 0 failed`.
