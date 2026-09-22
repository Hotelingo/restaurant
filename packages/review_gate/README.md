# Review gate engine

Pure, deterministic implementation of the Release 1 pre-sign review gate.

The engine has no database, HTTP, storage, clock or UI dependency. The API layer must build a
ReviewGateInput from authoritative persisted state, call enforce_review_gate, and refuse sign-off
when any outcome fails. There is deliberately no override argument.

The contract exposes exactly eleven outcomes:

1. RG.RECONCILIATION_DISCLOSURE — failed reconciliation is allowed only when the pack is explicitly stamped Not Reconciled.
2. RG.CLAIMS_RESOLVED — every claim has been accepted or rejected by the reviewer.
3. RG.ACT_REQUIREMENTS — every ACT decision has owner, lever, guardrail, metric, due date and cadence.
4. RG.COMMENTS_RESOLVED — no reviewer comment remains open.
5. RG.CLAIM_NUMBER_MATCH — every numeric magnitude agrees with cited engine output.
6. RG.CLAIM_CITATION — every claim has an allowed immutable citation/hypothesis basis.
7. RG.CLAIM_STATUS_ECHO — evidence/calculation status is not silently upgraded in prose.
8. RG.CLAIM_DIRECTION — directional wording agrees with the cited variance.
9. RG.CLAIM_BANNED_WORDING — no prohibited accusation, causal overclaim or absolute wording.
10. RG.CLAIM_SCOPE — the claim stays inside the pack period/comparator/input scope.
11. RG.REVIEWER_INDEPENDENCE — the signer is a Reviewer and did not make a management decision in the review.

Each failed outcome carries a stable code, an explanatory message, an actionable remediation and
affected record IDs where applicable. S4-8 will supply persisted reviewer comments/sign-off state
to this engine; it must not reimplement these rules.
