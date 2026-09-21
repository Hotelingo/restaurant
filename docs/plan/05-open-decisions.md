# Open Decisions

Twelve questions that need an answer before or during slice 1. Nine are short. **OD-01, OD-02 and
OD-05 are genuinely architectural** and will be expensive to change later — they should be settled
first.

Each records the question, why it matters, the options, and a recommendation. Record the answer and
the date inline; this file is the decision log.

---

## OD-01 · Background job runner — **architectural, blocks slice 3**

**Question.** How do long-running calculation runs and pack generation execute?

**Why it matters.** A calc run over the 10,500-row transaction fixture plus PDF pack generation will
not reliably complete inside a Vercel serverless request. Vercel function timeouts are the binding
constraint, and discovering this during slice 3 means rewriting the calc orchestration layer. This
is not an optimisation — it determines the shape of the API. (Gap G-60.)

**Options.**
1. **A dedicated worker service** (Render, Fly.io, Railway, or a container on any host) consuming a
   queue, with the FastAPI app enqueueing and the UI polling `calc_run.status`.
2. **Supabase Edge Functions plus `pg_cron`** — keeps everything inside Supabase but with tighter
   execution limits and a less pleasant debugging story.
3. **Synchronous execution with aggressive input limits** — only viable if runs stay small, which
   the transaction path already contradicts.

**Recommendation: option 1.** The schema already models runs as asynchronous — `calc_run` has
`started_at`, `completed_at` and a `status`. The model expects a worker; supply one. It also keeps
pack PDF generation, which is unbounded, off the request path.

**Answer:** _pending_

---

## OD-02 · Backup, restore and disaster recovery — **architectural**

**Question.** What is the RPO and RTO, and who has tested a restore?

**Why it matters.** The product's entire value proposition is immutable, auditable history. Losing
it is not an outage, it is an existential failure — a customer's signed packs and their lineage are
not reproducible from anywhere else. Supabase provides backups by plan tier, but an untested backup
is a hypothesis. (Gap G-63.)

**Options.**
1. Rely on Supabase's managed backups at the chosen tier; document RPO/RTO; **test a restore into a
   scratch project once per quarter**.
2. The above, plus independent periodic logical dumps to separate object storage.

**Recommendation: option 2** once the first paying customer exists; option 1 is acceptable during
development, provided a restore is actually performed at least once before launch.

**Answer:** _pending_

---

## OD-03 · Budget grain — **blocks slice 3**

**Question.** Are comparator (budget/forecast/prior-year) figures stored at account grain like
actuals, or at ladder-line grain?

**Why it matters.** The spec says T6 has "the same canonical structure as T1" — account grain — but
`fixtures/amberside/upload_files/Amberside_Budget_Jul2026.csv` is keyed by `Management_Line`, and
`financial_fact.account_id` is `NOT NULL`. **As it stands the fixture comparator cannot be committed
without inventing synthetic accounts**, which would corrupt the account dimension. (Gap G-07.)

**Options.**
1. **Allow ladder-grain comparators.** Make `account_id` nullable with a `CHECK` requiring it for
   `scenario = 'actual'`; always record `ladder_line_id`.
2. **Require account grain**, and change the fixture and the customer-facing template accordingly.
3. A separate `comparator_fact` table at ladder grain.

**Recommendation: option 1.** Restaurants routinely budget at management-line level and not by
account — requiring account-grain budgets would impose bookkeeping most customers do not do. The
fixture is right and the schema should accommodate it. Option 3 duplicates the variance logic for no
gain.

**Answer:** _pending_

---

## OD-04 · Outlet scoping model

**Question.** Keep `membership.outlet_scope uuid[]`, or move to a `membership_outlet` join table?

**Why it matters.** An array of UUIDs cannot carry a foreign key. Deleting an outlet leaves a
dangling entry, and access silently changes — in either direction. (Gap G-11.)

**Options.**
1. `membership_outlet` join table with real foreign keys and cascade behaviour.
2. Keep the array for RLS performance, add a trigger-based integrity check and document why.

**Recommendation: option 1.** Correctness over a micro-optimisation, in the one part of the system
where a silent error is a data breach. If profiling later shows the join is genuinely hot, cache it
in a materialised view rather than reintroducing an unconstrained array.

**Answer:** _pending_

---

## OD-05 · Data retention versus immutability — **architectural, blocks slice 4**

**Question.** How does a right-to-erasure request interact with "a signed pack never changes"?

**Why it matters.** These two requirements are in direct conflict and there is no technical trick
that dissolves it. A signed pack, its claims and its citations may contain personal data — action
owners, reviewer names, comment authors. GDPR erasure obligations and audit-trail immutability have
to be reconciled deliberately, and the answer shapes the schema. (Gap G-64.)

**Options.**
1. **Pseudonymise on erasure**: replace personal identifiers with a stable opaque token while
   preserving the record structure and every financial figure. The audit trail survives; the person
   is no longer identifiable.
2. **Hard delete with pack invalidation**: erasure voids affected packs, which are marked as such.
   Honest, but it destroys the customer's audit history.
3. **Contractual route**: rely on legitimate-interest and legal-obligation grounds for retention.
   **This needs a lawyer, not an engineer** — do not adopt it on engineering judgement alone.

**Recommendation: option 1**, with legal review. Design for it now: keep personal identifiers in
as few tables as possible and reference them by id everywhere else, so pseudonymisation is a
single-table update rather than an archaeological dig. Retrofitting this after slice 4 is painful.

**Answer:** _pending_

---

## OD-06 · Authentication policy

**Question.** Session length, MFA requirement, password policy, and is SSO in scope for R1?

**Why it matters.** Supabase Auth is chosen but no journey is designed, and this is a
slice-1 prerequisite. (Gaps G-41, G-61.)

**Recommendation.** Email/password plus magic link for R1. MFA optional for `viewer`/`editor`,
**required for `admin` and `reviewer`** — those roles sign financial packs. Sessions 12 hours with
sliding refresh. SSO deferred to R2 and recorded as such.

**Answer:** _pending_

---

## OD-07 · Missing screens

**Question.** Who designs the four missing journeys, and when?

**Why it matters.** Organisation/outlet creation is **acceptance criterion #1** of the first
vertical slice and has no design. Auth, empty states and error states are the same.
(Gaps G-40 to G-43.)

**Recommendation.** Extend the v4.2 wireframe with a v4.3 addendum covering exactly these four
journeys, in the existing design language, before slice 1 UI work starts. Do not design them
incidentally during build — the empty state is the hardest UX problem in this product and deserves
deliberate attention.

**Answer:** _pending_

---

## OD-08 · `SC23` and `SC24`

**Question.** Were these deliberately retired, or lost in an earlier revision?

**Why it matters.** The screen set runs SC01–SC22 then jumps to SC25. The preservation audit
compares v4 to v4.2 and would not detect a loss that predates v4. This is a one-line confirmation
that closes a real uncertainty. (Gap G-49.)

**Answer:** _pending_

---

## OD-09 · Pack rendering

**Question.** Is the Owner Pack rendered server-side to PDF, or via browser print?

**Why it matters.** The schema already models it as a stored artefact with a SHA-256, which implies
server-side rendering — a browser print cannot produce a stable hash. Confirming this also settles
whether print CSS is needed at all, and it interacts with OD-01. (Gap G-50.)

**Recommendation.** Server-side rendering to PDF in the worker, stored in Storage with its hash,
served by signed URL. A signed artefact must be byte-stable; only server rendering gives that.

**Answer:** _pending_

---

## OD-10 · Materiality defaults

**Question.** What default absolute and percentage thresholds ship for a new outlet?

**Why it matters.** The spec is emphatic that there is no universal hard-coded threshold, and it is
right. But a new outlet needs *some* starting value or the first review cannot run. The distinction
is between a **default the customer can see and change** and a **constant buried in code** — the
first is fine, the second is what the spec forbids.

**Recommendation.** Ship visible, editable defaults on `materiality_setting` — scope `general`,
recorded as "product default, not an accounting judgement", surfaced in FRAME and requiring
explicit confirmation at first use. On the Amberside scale, an absolute threshold around 2,000 and a
percentage around 2% would flag the labour and net-sales movements while filtering the noise;
treat those as a starting proposal, not a recommendation with authority.

**Answer:** _pending_

---

## OD-11 · Tolerance constants

**Question.** What are the numeric tolerances for the calculation control checks?

**Why it matters.** The import spec names 0.5% and 2%; the calc spec says "within currency
tolerance" with no number. Two implementations will choose differently and the golden tests will
become flaky. (Gap G-25.)

**Recommendation.** Store as settings with defaults: variance decomposition tie-out at 0.01 in the
currency's minor unit (the decompositions are algebraically exact, so any larger difference is a
data problem, not a rounding one); POS↔P&L at 0.5%; T3 purchases↔P&L at 2%.

**Answer:** _pending_

---

## OD-12 · R1 scope confirmations

**Question.** Confirm these are deliberate R1 limits, not oversights:

- One reporting currency per outlet (stated in the architecture document).
- No billing or subscription management.
- No POS/accounting connectors — file upload only.
- No mobile application; responsive web only.
- No AI-generated narrative.
- SSO deferred (see OD-06).

**Why it matters.** Each is defensible for R1, but they should be recorded as **chosen** limits with
a revisit point rather than discovered as gaps during a customer conversation. (Gap G-67.)

**Answer:** _pending_
