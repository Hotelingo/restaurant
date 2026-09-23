// Review-loop vocabulary shared by the review screens. Nothing here computes a
// financial figure: amounts shown or written into claim text are the server's
// own decimal strings, reformatted for reading only.

import type { CalcResultRead, Disposition, EvidenceStatus } from "./contracts";

/** Driver taxonomy reference data (db/migrations/0001_reference.sql). */
export const DRIVERS: { code: string; name: string; domain: "general" | "food" }[] = [
  { code: "volume", name: "Volume", domain: "general" },
  { code: "rate_price", name: "Rate / price", domain: "general" },
  { code: "mix", name: "Mix", domain: "general" },
  { code: "productivity_intensity", name: "Productivity / intensity", domain: "general" },
  { code: "timing_cutoff", name: "Timing / cut-off", domain: "general" },
  { code: "classification_mapping", name: "Classification / mapping", domain: "general" },
  { code: "one_off_structural", name: "One-off / structural", domain: "general" },
  { code: "food_price_spec", name: "Food price / specification", domain: "food" },
  { code: "food_yield", name: "Food yield", domain: "food" },
  { code: "food_portion", name: "Food portion", domain: "food" },
  { code: "food_production", name: "Food production", domain: "food" },
  { code: "food_waste", name: "Food waste", domain: "food" },
  { code: "food_transfer_nonrevenue", name: "Food transfer / non-revenue use", domain: "food" },
  { code: "food_inventory_data", name: "Food inventory / data quality", domain: "food" },
  { code: "other_supported", name: "Other supported driver", domain: "general" },
];

export const EVIDENCE_LABEL: Record<EvidenceStatus, string> = {
  validated: "Validated",
  supported: "Supported",
  partly_supported: "Partly supported",
  evidence_required: "Evidence required",
  not_reconciled: "Not reconciled",
  not_applicable: "Not applicable",
};

export function evidenceTone(status: string): "ok" | "warn" | "bad" | "info" | "mute" {
  if (status === "validated" || status === "supported") return "ok";
  if (status === "partly_supported") return "info";
  if (status === "evidence_required" || status === "not_reconciled") return "warn";
  return "mute";
}

export type DecisionField =
  | "owner" | "lever" | "guardrail" | "verification_metric" | "target_trigger" | "due_date" | "cadence"
  | "evidence_request_id" | "decision_required" | "consequence_of_waiting" | "forecast_treatment" | "closure_evidence";

/**
 * Per-disposition fields, mirroring the `decision_requirements_check` constraint
 * (db/migrations/0024_decisions.sql). `anyOf` groups need at least one member.
 */
export const DISPOSITIONS: Record<Disposition, {
  label: string; help: string; required: DecisionField[]; optional: DecisionField[]; anyOf?: DecisionField[];
}> = {
  ACT: {
    label: "Act",
    help: "The driver is supported. Change something, with an owner, a guardrail and a way to check it worked.",
    required: ["owner", "lever", "guardrail", "verification_metric"],
    anyOf: ["due_date", "cadence"],
    optional: ["target_trigger", "due_date", "cadence"],
  },
  MONITOR: {
    label: "Monitor",
    help: "Understood, no change yet. Say what would trigger action and how often it is checked.",
    required: ["target_trigger", "cadence"],
    optional: ["owner"],
  },
  INVESTIGATE: {
    label: "Investigate",
    help: "The cause is not yet evidenced. Request the data needed, with an owner and a due date.",
    required: ["evidence_request_id", "owner", "due_date"],
    optional: [],
  },
  ESCALATE: {
    label: "Escalate",
    help: "The decision sits above this review's authority. State the decision needed and the cost of waiting.",
    required: ["decision_required", "consequence_of_waiting", "owner", "due_date"],
    optional: [],
  },
  CLOSE: {
    label: "Close",
    help: "No further action. Record why, and how the forecast treats it.",
    required: ["forecast_treatment", "closure_evidence"],
    optional: [],
  },
};

export const DECISION_FIELD: Record<DecisionField, { label: string; hint?: string; type?: "date" | "long" }> = {
  owner: { label: "Owner", hint: "The person accountable, by name or role." },
  lever: { label: "Lever", hint: "What will be changed, e.g. rota template for weekday lunch." },
  guardrail: { label: "Guardrail", hint: "What must not get worse while the lever is pulled." },
  verification_metric: { label: "Verification metric", hint: "The measure that shows it worked." },
  target_trigger: { label: "Target / trigger", hint: "The level that counts as success, or that triggers action." },
  due_date: { label: "Due date", type: "date" },
  cadence: { label: "Cadence", hint: "How often it is checked, e.g. weekly." },
  evidence_request_id: { label: "Evidence request" },
  decision_required: { label: "Decision required", type: "long" },
  consequence_of_waiting: { label: "Consequence of waiting", type: "long" },
  forecast_treatment: { label: "Forecast treatment", hint: "e.g. one-off, excluded from run-rate." },
  closure_evidence: { label: "Closure evidence", type: "long" },
};

export const ACTION_STATUS_LABEL: Record<string, string> = {
  OPEN_ON_TRACK: "Open · on track",
  CLOSED: "Closed",
  OVERDUE_NOT_COMPLETED: "Overdue",
  REPEATED_ISSUE: "Repeated issue",
  REOPENED: "Reopened",
};

export const REVIEW_STATUS_LABEL: Record<string, string> = {
  draft: "Not framed",
  in_review: "In review",
  signed: "Signed",
  released: "Released",
  closed: "Closed",
};

export const PACK_STATUS_LABEL: Record<string, string> = {
  draft: "Draft",
  in_review: "With reviewer",
  changes_requested: "Changes requested",
  signed: "Signed",
  superseded: "Superseded",
};

/**
 * Render a server decimal string exactly, with thousands separators, trimming
 * only trailing zeros. Never rounds: claim text must repeat the cited figure,
 * and the server's claim check compares it digit for digit.
 */
export function exactAmount(value: string, { absolute = false } = {}): string {
  let text = value.trim();
  let sign = "";
  if (text.startsWith("-")) { sign = absolute ? "" : "-"; text = text.slice(1); }
  const [whole, fraction = ""] = text.split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const trimmed = fraction.replace(/0+$/, "");
  return `${sign}${grouped}${trimmed ? `.${trimmed}` : ""}`;
}

export function isNegative(value: string | null | undefined): boolean {
  return typeof value === "string" && value.trim().startsWith("-");
}

export function isZero(value: string | null | undefined): boolean {
  return typeof value === "string" && /^-?0*(\.0*)?$/.test(value.trim());
}

const COMPARATOR_WORD: Record<string, string> = { budget: "Budget", forecast: "Forecast", prior_year: "Prior Year" };
export const comparatorWord = (scenario: string | null | undefined) =>
  scenario ? COMPARATOR_WORD[scenario] ?? scenario : "the comparator";

/**
 * Draft claim wording for one P&L line from its three cited results. The
 * direction words follow the sign of the server's profit effect; the reviewer
 * still confirms direction, status and scope before accepting.
 */
export function draftLineClaim(
  label: string,
  actual: CalcResultRead,
  comparator: CalcResultRead,
  variance: CalcResultRead,
  scenario: string | null,
): string | null {
  if (actual.value_numeric === null || comparator.value_numeric === null || variance.value_numeric === null) return null;
  const versus = comparatorWord(scenario);
  if (isZero(variance.value_numeric)) {
    return `${label} was ${exactAmount(actual.value_numeric)}, in line with ${versus} of ${exactAmount(comparator.value_numeric)}.`;
  }
  const effect = isNegative(variance.value_numeric) ? "an adverse" : "a favourable";
  return `${label} was ${exactAmount(actual.value_numeric)} against ${versus} of ${exactAmount(comparator.value_numeric)}, `
    + `${effect} profit effect of ${exactAmount(variance.value_numeric, { absolute: true })}.`;
}

/** Whether a calculation run captured general materiality thresholds, which FRAME requires. */
export function runHasMateriality(run: { settings_snapshot: Record<string, unknown> } | null | undefined): boolean {
  const group = run?.settings_snapshot?.materiality;
  return typeof group === "object" && group !== null && typeof (group as Record<string, unknown>).general === "object"
    && (group as Record<string, unknown>).general !== null;
}
