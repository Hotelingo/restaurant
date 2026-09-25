"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { CalculationPanel } from "@/components/data/CalculationPanel";
import { MappingForm } from "@/components/data/MappingForm";
import { Button, Card, Chip, ErrorPanel, Select, Skeleton } from "@/components/ui";
import { ApiError, apiFetch, apiMutate, idempotencyKey } from "@/lib/api";
import type {
  ImportCommitResponse, ImportExceptionsResponse, ImportParseResponse, ImportStatusResponse,
  ImportValidateResponse, MappingConfirmRequest, MappingConfirmResponse, Scenario,
} from "@/lib/contracts";
import { SCENARIO_LABEL, batchStatus, templateInfo } from "@/lib/domain";
import { useOutlet } from "@/lib/outlet-context";
import { useApi, useMutation } from "@/lib/use-api";

const STEPS = ["Upload", "Read", "Map", "Validate", "Commit"] as const;

/** Worksheet names when the API refused a multi-sheet workbook until one is chosen. */
function sheetChoices(cause: unknown): string[] | null {
  if (!(cause instanceof ApiError) || !cause.detail || typeof cause.detail !== "object") return null;
  const detail = cause.detail as { type?: unknown; sheets?: unknown };
  if (detail.type !== "sheet-selection-required" || !Array.isArray(detail.sheets)) return null;
  const sheets = detail.sheets.filter((name): name is string => typeof name === "string");
  return sheets.length > 0 ? sheets : null;
}

function stepIndex(status: string): number {
  switch (status) {
    case "uploaded": case "parsing": return 1;
    case "needs_mapping": return 2;
    case "validating": return 3;
    case "ready": case "warning": case "blocked": return 4;
    case "committed": return 5;
    default: return 1;
  }
}

export default function BatchWorkflow({ batchId }: { batchId: string }) {
  const search = useSearchParams();
  const { periodId, href, summary } = useOutlet();
  const status = useApi<ImportStatusResponse>(`/imports/${batchId}/status`);
  const batch = status.data;
  const needsMapping = batch?.status === "needs_mapping";
  const exceptions = useApi<ImportExceptionsResponse>(needsMapping ? `/imports/${batchId}/exceptions` : null);
  const step = useMutation();
  const commitKey = useRef(idempotencyKey()).current;
  const mappingKey = useRef(idempotencyKey()).current;
  const [notice, setNotice] = useState<string | null>(null);
  const [committedFacts, setCommittedFacts] = useState<number | null>(null);

  const info = batch ? templateInfo(batch.template_code) : undefined;
  const initialScenario = (search.get("scenario") as Scenario | null) ?? info?.scenarios[0] ?? "actual";
  const [scenario, setScenario] = useState<Scenario>(initialScenario);
  const [sheets, setSheets] = useState<string[] | null>(null);
  const [sheet, setSheet] = useState("");
  const autoRead = useRef(search.get("read") === "retry");
  const targetPeriod = batch?.period_id ?? periodId;
  const periodLabel = summary.periods.find((p) => p.id === targetPeriod)?.label ?? "this period";

  async function read() {
    if (sheets && !sheet) return;
    const r = await step.run(async () => {
      try {
        return await apiFetch<ImportParseResponse>(`/imports/${batchId}/parse`, {
          method: "POST",
          body: JSON.stringify({ period_id: targetPeriod, scenario, ...(sheets && sheet ? { sheet_name: sheet } : {}) }),
        });
      } catch (cause) {
        const choices = sheetChoices(cause);
        if (!choices) throw cause;
        setSheets(choices);
        setSheet((current) => (choices.includes(current) ? current : ""));
        throw new ApiError("This workbook has more than one worksheet. Choose the one to read.", 409,
          cause instanceof ApiError ? cause.correlationId : null);
      }
    });
    if (r) { setSheets(null); setNotice(r.profile_match_message); status.reload(); }
  }

  // The Data Centre reads the file straight after upload. When that read failed
  // (e.g. a workbook with several sheets), repeat it once here so the reason and
  // the way forward are shown instead of a bare "Read file" button.
  useEffect(() => {
    if (!autoRead.current || batch?.status !== "uploaded") return;
    autoRead.current = false;
    void read();
    // read() is recreated each render; this must run once, when the batch first loads.
  }, [batch?.status]);

  async function confirmMapping(request: MappingConfirmRequest) {
    const r = await step.run(() => apiMutate<MappingConfirmResponse>(`/imports/${batchId}/mapping/confirm`, request, { key: mappingKey }));
    if (r) { setNotice(`Mapping saved as version ${r.version_no}. Later uploads with this layout reuse it.`); status.reload(); }
  }

  async function validate() {
    const r = await step.run(() => apiFetch<ImportValidateResponse>(`/imports/${batchId}/validate`, { method: "POST" }));
    if (r) {
      setNotice(r.unresolved_block_count > 0
        ? `${r.unresolved_block_count} blocking ${r.unresolved_block_count === 1 ? "issue" : "issues"} found.`
        : r.warning_count > 0 ? `No blocking issues; ${r.warning_count} ${r.warning_count === 1 ? "warning" : "warnings"}.` : "No issues found.");
      status.reload();
    }
  }

  async function commit() {
    const r = await step.run(() => apiMutate<ImportCommitResponse>(`/imports/${batchId}/commit`, undefined, { key: commitKey }));
    if (r) { setCommittedFacts(r.fact_count); setNotice(null); status.reload(); }
  }

  if (status.loading && !batch) {
    return <main className="shell"><div className="panel wide"><Skeleton width="50%" /><Skeleton width="70%" /></div></main>;
  }
  if (status.error || !batch) {
    return (
      <main className="shell"><div className="panel wide">
        <ErrorPanel message={status.error?.status === 404 ? "This upload is not available." : status.error?.message ?? "Unable to load this upload."}
          correlationId={status.error?.correlationId} action={<Link className="btn" href={href("/data")}>Back to Data Centre</Link>} />
      </div></main>
    );
  }

  const current = stepIndex(batch.status);
  const hasSavedMapping = Boolean(batch.candidate_profile_version_id ?? batch.profile_version_id);
  const s = batchStatus(batch.status);

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <div className="row sb">
            <h1>{info?.label ?? batch.template_code}</h1>
            <Chip tone={s.tone}>{s.text}</Chip>
          </div>
          <p>Into <strong>{periodLabel}</strong> as <strong>{SCENARIO_LABEL[batch.scenario] ?? batch.scenario}</strong>. {info?.purpose}</p>
        </div>

        <ol className="steps" aria-label="Upload progress">
          {STEPS.map((label, i) => (
            <li key={label} className={i < current || batch.status === "committed" ? "done" : i === current ? "cur" : ""}
              aria-current={i === current && batch.status !== "committed" ? "step" : undefined}>
              {label}
            </li>
          ))}
        </ol>

        {notice ? <div className="banner info">{notice}</div> : null}
        {step.error ? <ErrorPanel message={step.error.message} correlationId={step.error.correlationId} /> : null}

        {batch.status === "uploaded" || batch.status === "parsing" ? (
          <Card title="Read the file">
            <div className="stack">
              <p className="muted" style={{ margin: 0 }}>We read the rows, recognise the layout, and check whether it matches a mapping you have already approved.</p>
              {info && info.scenarios.length > 1 ? (
                <Select label="Compared as" id="batch-scenario" value={scenario} onChange={(e) => setScenario(e.target.value as Scenario)}>
                  {info.scenarios.map((sc) => <option key={sc} value={sc}>{SCENARIO_LABEL[sc]}</option>)}
                </Select>
              ) : null}
              {sheets ? (
                <Select label="Worksheet to read" id="batch-sheet" value={sheet} onChange={(e) => setSheet(e.target.value)}>
                  <option value="">Choose a worksheet…</option>
                  {sheets.map((name) => <option key={name} value={name}>{name}</option>)}
                </Select>
              ) : null}
              <div className="actions-bar">
                <Button variant="primary" loading={step.busy} disabled={Boolean(sheets) && !sheet} onClick={() => void read()}>Read file</Button>
              </div>
            </div>
          </Card>
        ) : null}

        {needsMapping ? (
          <Card title="Map this layout">
            {exceptions.loading ? <Skeleton width="60%" /> : exceptions.error ? (
              <ErrorPanel message={exceptions.error.message} correlationId={exceptions.error.correlationId} />
            ) : exceptions.data && exceptions.data.exceptions.length > 0 ? (
              <MappingForm exceptions={exceptions.data.exceptions} defaultSourceLabel={`${info?.label ?? batch.template_code} export`} busy={step.busy} error={null} onConfirm={(r) => void confirmMapping(r)} />
            ) : (
              // Nothing needs a choice. Either the layout matched a saved mapping
              // for review (e.g. a month in which some accounts had no activity)
              // and every row is already mapped, or this template has no row
              // mappings at all. Confirming saves the layout; nothing new is asked.
              <div className="stack">
                <p className="muted" style={{ margin: 0 }}>
                  {hasSavedMapping
                    ? "Every row in this file already has a mapping. The layout differs slightly from the saved one, so confirm to read this file with the saved mapping."
                    : "Nothing in this file needs mapping. Confirm to save its layout so later uploads are recognised."}
                </p>
                <div className="actions-bar">
                  <Button variant="primary" loading={step.busy}
                    onClick={() => void confirmMapping(hasSavedMapping ? {} : { source_label: `${info?.label ?? batch.template_code} export` })}>
                    {hasSavedMapping ? "Use the saved mapping" : "Save this layout"}
                  </Button>
                  {hasSavedMapping ? <Link className="btn" href={href("/mappings")}>Review mappings</Link> : null}
                </div>
              </div>
            )}
          </Card>
        ) : null}

        {batch.status === "validating" ? (
          <Card title="Validate">
            <div className="stack">
              <p className="muted" style={{ margin: 0 }}>Checks every row against the mapping and the period: required fields, duplicates, signs and totals.</p>
              <div className="actions-bar"><Button variant="primary" loading={step.busy} onClick={() => void validate()}>Validate</Button></div>
            </div>
          </Card>
        ) : null}

        {batch.status === "blocked" ? (
          <Card title="Blocked">
            <div className="stack">
              <div className="banner bad">
                <strong>{batch.unresolved_block_count} blocking {batch.unresolved_block_count === 1 ? "issue" : "issues"}.</strong>{" "}
                Nothing from this file can be committed until they are fixed. The usual causes are a row in the wrong period,
                a duplicate account, or a non-numeric amount. Correct the file and upload it again.
              </div>
              <div className="actions-bar">
                <Link className="btn p" href={href("/data", { template: batch.template_code })}>Upload a corrected file</Link>
                <Button onClick={() => void validate()} loading={step.busy}>Validate again</Button>
              </div>
            </div>
          </Card>
        ) : null}

        {batch.status === "ready" || batch.status === "warning" ? (
          <Card title="Commit">
            <div className="stack">
              <dl className="kv">
                <dt>Rows read</dt><dd className="mono">{batch.staging_row_count}</dd>
                <dt>Blocking issues</dt><dd className="mono">{batch.unresolved_block_count}</dd>
                <dt>Warnings</dt><dd className="mono">{batch.warning_count}</dd>
              </dl>
              <p className="muted" style={{ margin: 0 }}>
                Committing makes this file&apos;s figures part of the period&apos;s record. It is atomic — all rows or none — and cannot be edited
                afterwards; a correction is a new upload that supersedes this one.
              </p>
              <div className="actions-bar"><Button variant="primary" loading={step.busy} onClick={() => void commit()}>Commit</Button></div>
            </div>
          </Card>
        ) : null}

        {batch.status === "committed" ? (
          <div className="stack">
            <div className="banner ok">
              <strong>Committed.</strong> {committedFacts !== null ? `${committedFacts} figures recorded. ` : ""}
              Every figure keeps a link back to this file.
            </div>
            {targetPeriod && info ? (
              <Card title="Calculate">
                <CalculationPanel periodId={targetPeriod} module={info.module} ready
                  resultHref={info.module === "pl" ? href("/analysis/pnl") : href("")} />
              </Card>
            ) : null}
            <div className="actions-bar"><Link className="btn" href={href("/data")}>Back to Data Centre</Link></div>
          </div>
        ) : null}
      </div>
    </main>
  );
}
