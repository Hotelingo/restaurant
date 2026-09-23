/** Frozen R1 reference vocabulary used by the UI. Platform data, not customer data. */
import type { CalculationModule, Scenario, TemplateCode } from "./contracts";

export type LadderLine = { code: string; label: string; kind: "revenue" | "cost" | "subtotal" | "profit" };

export const LADDER: LadderLine[] = [
  { code: "NET_SALES", label: "Net Sales", kind: "revenue" },
  { code: "PRODUCT_COST", label: "Product Cost", kind: "cost" },
  { code: "PRODUCT_MARGIN", label: "Product Margin", kind: "subtotal" },
  { code: "CHANNEL_COST", label: "Acquisition / Channel Cost", kind: "cost" },
  { code: "DIRECT_LABOUR", label: "Direct Labour", kind: "cost" },
  { code: "OTHER_DIRECT_OPERATING", label: "Other Direct Operating Cost", kind: "cost" },
  { code: "CONTRIBUTION", label: "Contribution", kind: "subtotal" },
  { code: "SHARED_RESTAURANT_COST", label: "Shared Restaurant Costs", kind: "cost" },
  { code: "OPERATING_PROFIT", label: "Operating Profit", kind: "profit" },
  { code: "OWNER_STRUCTURAL_COST", label: "Owner / Structural Costs", kind: "cost" },
  { code: "OWNER_RESULT", label: "Owner Result", kind: "profit" },
];

/** Lines a source account or budget line can be mapped to (never a subtotal). */
export const MAPPABLE_LINES = LADDER.filter((l) => l.kind === "revenue" || l.kind === "cost");

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

/** Best-effort suggestion from a label such as "Shared Restaurant Costs". The user always confirms. */
export function suggestLadderCode(label: string | null | undefined): string {
  if (!label) return "";
  const n = norm(label);
  const exact = MAPPABLE_LINES.find((l) => norm(l.label) === n || norm(l.code) === n);
  if (exact) return exact.code;
  const partial = MAPPABLE_LINES.find((l) => n.includes(norm(l.label)) || norm(l.label).includes(n));
  return partial?.code ?? "";
}

export type TemplateInfo = {
  code: TemplateCode;
  label: string;
  purpose: string;
  scenarios: Scenario[];
  module: CalculationModule;
  core: boolean;
};

export const TEMPLATES: TemplateInfo[] = [
  { code: "T1", label: "P&L / trial balance (actual)", purpose: "The month's actual results by account.", scenarios: ["actual"], module: "pl", core: true },
  { code: "T6", label: "Budget, forecast or prior year", purpose: "What the month is compared against.", scenarios: ["budget", "forecast", "prior_year"], module: "pl", core: true },
  { code: "T1B", label: "Meal-period sales and covers", purpose: "Revenue by meal period.", scenarios: ["actual"], module: "revenue", core: false },
  { code: "T7", label: "Customer source / channel", purpose: "Revenue and cost by source.", scenarios: ["actual"], module: "revenue", core: false },
  { code: "T2", label: "POS item sales", purpose: "Units and revenue by menu item.", scenarios: ["actual"], module: "food_cost", core: false },
  { code: "T3", label: "Purchases and stock", purpose: "Opening, purchases and closing stock.", scenarios: ["actual"], module: "food_cost", core: false },
  { code: "T4A", label: "Item cost", purpose: "Approved cost per menu item.", scenarios: ["actual"], module: "food_cost", core: false },
  { code: "T5", label: "Labour and activity", purpose: "Hours, cost and workload by role group.", scenarios: ["actual"], module: "labour_other", core: false },
];

export const templateInfo = (code: string) => TEMPLATES.find((t) => t.code === code);

export const SCENARIO_LABEL: Record<Scenario, string> = {
  actual: "Actual", budget: "Budget", forecast: "Forecast", prior_year: "Prior year",
};

export const MODULE_LABEL: Record<CalculationModule, string> = {
  pl: "Management P&L", food_cost: "Food & beverage cost", revenue: "Revenue and contribution", labour_other: "Labour and other costs",
};

/** Batch status -> chip tone and plain-language meaning. */
export function batchStatus(status: string): { tone: "ok" | "warn" | "bad" | "info" | "mute"; text: string } {
  switch (status) {
    case "committed": return { tone: "ok", text: "Committed" };
    case "ready": return { tone: "info", text: "Ready to commit" };
    case "warning": return { tone: "warn", text: "Ready, with warnings" };
    case "blocked": return { tone: "bad", text: "Blocked — needs attention" };
    case "needs_mapping": return { tone: "warn", text: "Needs mapping" };
    case "validating": return { tone: "info", text: "Mapped — validate next" };
    case "uploaded": return { tone: "info", text: "Uploaded — read next" };
    case "superseded": return { tone: "mute", text: "Superseded" };
    case "rejected": return { tone: "bad", text: "Rejected" };
    default: return { tone: "mute", text: status };
  }
}
