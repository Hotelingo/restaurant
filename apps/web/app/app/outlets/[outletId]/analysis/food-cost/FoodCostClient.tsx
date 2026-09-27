"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { FoodCostAnalysisResponse, FoodCostGroupRead } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";
import { calcNumber, EffectBars, EvidenceChip, FoodCostBridge, ReadinessStrip, resultText } from "@/components/analytics/ModuleAnalytics";
import { formatAmount } from "@/lib/format";

function decisionLabel(value: string | null | undefined): string {
  if (!value) return "Not calculated";
  const labels: Record<string, string> = {
    VALIDATE_FIRST: "Validate data first",
    OPERATING_CONTROL_INVESTIGATION: "Operating-control investigation",
    FAVOURABLE_VALIDATE_DATA: "Favourable — validate data",
    MENU_ECONOMIC_HANDOFF: "Menu-economics handoff",
    NO_MATERIAL_GAP: "No material gap",
  };
  return labels[value] ?? value.replaceAll("_", " ");
}

function strongest(groups: FoodCostGroupRead[], field: "menu_mix_effect" | "actual_vs_expected" | "residual") {
  return groups
    .map((group) => ({ group, value: calcNumber(group[field]) }))
    .filter((row): row is { group: FoodCostGroupRead; value: number } => row.value !== null)
    .sort((a, b) => Math.abs(b.value) - Math.abs(a.value))[0] ?? null;
}

export default function FoodCostClient({ outletId, periodId }: { outletId: string; periodId?: string }) {
  const [data, setData] = useState<FoodCostAnalysisResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    let cancelled = false;
    const query = periodId ? `?period_id=${encodeURIComponent(periodId)}` : "";
    apiFetch<FoodCostAnalysisResponse>(`/outlets/${outletId}/analysis/food-cost${query}`)
      .then((response) => {
        if (!cancelled) {
          setData(response);
          setError(null);
        }
      })
      .catch((cause) => {
        if (!cancelled) setError(cause instanceof ApiError ? cause : new ApiError("Unable to load Food Cost analysis.", 500, null));
      });
    return () => { cancelled = true; };
  }, [outletId, periodId]);

  const groups = useMemo(() => [...(data?.groups ?? [])].sort((a, b) => a.product_group.localeCompare(b.product_group)), [data]);

  if (!data) {
    return <main className="shell"><div className="panel wide"><div className="page-head"><h1>Food &amp; Beverage Cost</h1></div>{error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /></>}</div></main>;
  }

  const biggestMenu = strongest(groups, "menu_mix_effect");
  const biggestOperating = strongest(groups, "actual_vs_expected");
  const biggestResidual = strongest(groups, "residual");

  return (
    <main className="shell">
      <div className="panel wide analytics-page">
        <div className="row sb">
          <div className="page-head">
            <h1>Food &amp; Beverage Cost</h1>
            <p>Separate budget/menu economics from actual-versus-expected operating control before investigating causes.</p>
          </div>
          <div className="row"><Chip tone="mute">{data.period.label}</Chip>{data.run ? <Chip tone="ok">Calculated</Chip> : <Chip tone="warn">Not calculated</Chip>}</div>
        </div>

        <ReadinessStrip status={data.readiness.status} missingInputs={data.readiness.missing_inputs} explanation={data.readiness.explanation_code} />
        <div className="banner info"><strong>Methodology guardrail:</strong> a budget gap alone does not establish operating leakage. The operating signal is Actual vs Expected; supported drivers reduce that signal to an explicit residual.</div>

        {!data.run ? (
          <EmptyState title="Food Cost analysis is not ready">
            Complete the missing Food Cost inputs shown above and run the calculation. The application will not manufacture expected usage or substitute missing item costs.
          </EmptyState>
        ) : (
          <>
            <div className="analytics-primary-grid">
              <Card title="Menu-mix effect by product group">
                <p className="muted analytics-card-intro">Menu economics is shown separately from operating-control variance.</p>
                <EffectBars rows={groups.map((group) => ({ label: group.product_group, value: calcNumber(group.menu_mix_effect) }))} />
              </Card>
              <Card title="Actual vs Expected by product group">
                <p className="muted analytics-card-intro">This is the operating gap used for the Food Cost decision path.</p>
                <EffectBars rows={groups.map((group) => ({ label: group.product_group, value: calcNumber(group.actual_vs_expected) }))} />
              </Card>
            </div>

            <div className="analytics-secondary-grid">
              <Card title="Management observations">
                <div className="analytics-observations">
                  <div className="analytics-observation"><strong>Largest menu-economics movement</strong><span>{biggestMenu ? `${biggestMenu.group.product_group}: ${formatAmount(Math.abs(biggestMenu.value))} ${biggestMenu.value >= 0 ? "adverse" : "favourable"} menu-mix effect.` : "Menu-mix effect not calculated."}</span></div>
                  <div className="analytics-observation"><strong>Largest operating gap</strong><span>{biggestOperating ? `${biggestOperating.group.product_group}: ${formatAmount(Math.abs(biggestOperating.value))} ${biggestOperating.value >= 0 ? "adverse" : "favourable"} Actual vs Expected.` : "Actual vs Expected not calculated."}</span></div>
                  <div className="analytics-observation"><strong>Largest residual</strong><span>{biggestResidual ? `${biggestResidual.group.product_group}: ${formatAmount(Math.abs(biggestResidual.value))} remains after supported drivers.` : "Residual evidence is not yet available."}</span></div>
                </div>
              </Card>
              <Card title="Interpretation">
                <div className="analytics-observations">
                  <div className="analytics-observation"><strong>Budget gap</strong><span>Context only; it must not be labelled leakage.</span></div>
                  <div className="analytics-observation"><strong>Menu mix</strong><span>Economic/menu composition movement, handled separately from operating control.</span></div>
                  <div className="analytics-observation"><strong>Residual</strong><span>Unexplained remainder after supported/validated operating evidence.</span></div>
                </div>
              </Card>
            </div>

            {groups.map((group) => (
              <Card key={group.product_group} title={`${group.product_group[0]?.toUpperCase() ?? ""}${group.product_group.slice(1)} Cost Bridge`}>
                <div className="module-group-head">
                  <div className="module-stat"><span>Actual cost %</span><strong>{resultText(group.actual_cost_pct, "ratio")}</strong></div>
                  <div className="module-stat"><span>Expected cost %</span><strong>{resultText(group.expected_cost_pct, "ratio")}</strong></div>
                  <div className="module-stat"><span>Budget gap</span><strong>{resultText(group.budget_gap)}</strong></div>
                  <div className="module-stat"><span>Actual vs Expected</span><strong>{resultText(group.actual_vs_expected)}</strong></div>
                  <div className="module-stat"><span>Residual</span><strong>{resultText(group.residual)}</strong></div>
                  <div className="module-stat"><span>Decision path</span><strong className="module-decision">{decisionLabel(group.decision_path?.value_text)}</strong></div>
                </div>
                <FoodCostBridge budget={group.budget_benchmark} menuMix={group.menu_mix_effect} expected={group.expected_usage} operatingGap={group.actual_vs_expected} actual={group.actual_consumption} />
                <div className="module-driver-strip">
                  <span><b>Supported drivers:</b> {resultText(group.supported_driver_total)}</span>
                  <span><b>Residual:</b> {resultText(group.residual)}</span>
                  <span><b>Evidence:</b> <EvidenceChip status={group.evidence_status} /></span>
                </div>
              </Card>
            ))}

            <Card title="Food Cost control table">
              <div className="tw"><table className="tbl analysis-table">
                <thead><tr><th>Product group</th><th className="n">Budget benchmark</th><th className="n">Menu mix</th><th className="n">Expected usage</th><th className="n">Actual consumption</th><th className="n">Actual vs Expected</th><th className="n">Supported drivers</th><th className="n">Residual</th><th>Decision path</th><th>Evidence</th></tr></thead>
                <tbody>{groups.map((group) => (
                  <tr key={group.product_group}><th scope="row">{group.product_group}</th><td className="n">{resultText(group.budget_benchmark)}</td><td className="n">{resultText(group.menu_mix_effect)}</td><td className="n">{resultText(group.expected_usage)}</td><td className="n">{resultText(group.actual_consumption)}</td><td className="n">{resultText(group.actual_vs_expected)}</td><td className="n">{resultText(group.supported_driver_total)}</td><td className="n">{resultText(group.residual)}</td><td>{decisionLabel(group.decision_path?.value_text)}</td><td><EvidenceChip status={group.evidence_status} /></td></tr>
                ))}</tbody>
              </table></div>
            </Card>
          </>
        )}

        <div className="row mt8"><Link className="btn" href={`/app/outlets/${outletId}/analysis?period=${data.period.id}`}>Back to Analysis Home</Link><Link className="btn p" href={`/app/outlets/${outletId}/reviews?period=${data.period.id}`}>Continue to review</Link></div>
      </div>
    </main>
  );
}
