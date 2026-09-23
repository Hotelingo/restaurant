"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useState } from "react";
import { CalculationPanel } from "@/components/data/CalculationPanel";
import { Button, Card, Chip, DataTable, Disclosure, EmptyState, ErrorPanel, Select, Skeleton } from "@/components/ui";
import { apiFetch } from "@/lib/api";
import type { ImportBatchListResponse, ImportBatchSummary, ImportUploadResponse, Scenario, TemplateCode } from "@/lib/contracts";
import { SCENARIO_LABEL, TEMPLATES, batchStatus, templateInfo } from "@/lib/domain";
import { formatBytes, formatDateTime } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { useApi, useMutation } from "@/lib/use-api";

export default function DataCentre() {
  const router = useRouter();
  const search = useSearchParams();
  const { outletId, summary, periodId, href } = useOutlet();
  const period = summary.periods.find((p) => p.id === periodId) ?? null;
  const imports = useApi<ImportBatchListResponse>(periodId ? `/outlets/${outletId}/imports?period_id=${periodId}` : null);

  const initialTemplate = (TEMPLATES.find((t) => t.code === search.get("template"))?.code ?? "T1") as TemplateCode;
  const [template, setTemplate] = useState<TemplateCode>(initialTemplate);
  const [scenario, setScenario] = useState<Scenario>(templateInfo(initialTemplate)!.scenarios[0]);
  const [file, setFile] = useState<File | null>(null);
  const upload = useMutation();

  if (!period) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head"><h1>Data Centre</h1></div>
          <EmptyState title="Add a reporting period first"
            action={<Link className="btn p" href={`/setup/period?outlet=${outletId}`}>Add a reporting period</Link>}>
            Every file is uploaded into a period — the month it describes.
          </EmptyState>
        </div>
      </main>
    );
  }

  const batches = imports.data?.batches ?? [];
  const latestFor = (code: string) => batches.find((b) => b.template_code === code) ?? null;
  const committed = (code: string) => batches.some((b) => b.template_code === code && b.status === "committed");
  const info = templateInfo(template)!;

  function chooseTemplate(code: TemplateCode) {
    setTemplate(code);
    setScenario(templateInfo(code)!.scenarios[0]);
  }

  async function uploadAndRead() {
    if (!file || !periodId) return;
    const result = await upload.run(async () => {
      const form = new FormData();
      form.append("outlet_id", outletId);
      form.append("template_code", template);
      form.append("file", file);
      const uploaded = await apiFetch<ImportUploadResponse>("/imports/upload", { method: "POST", body: form });
      // Read the file straight away. If reading fails, the batch page offers a retry.
      try {
        await apiFetch(`/imports/${uploaded.batch_id}/parse`, {
          method: "POST",
          body: JSON.stringify({ period_id: periodId, scenario }),
        });
      } catch {
        /* surfaced on the batch page */
      }
      return uploaded;
    });
    if (result) router.push(href(`/data/${result.batch_id}`, { scenario }));
  }

  const statusRow = (code: TemplateCode) => {
    const t = templateInfo(code)!;
    const latest = latestFor(code);
    const s = latest ? batchStatus(latest.status) : null;
    return (
      <li key={code} className="row sb">
        <div>
          <strong>{t.label}</strong>
          <div className="muted">{t.purpose}</div>
        </div>
        <div className="row">
          {committed(code) ? <Chip tone="ok">Committed</Chip> : s ? <Chip tone={s.tone}>{s.text}</Chip> : <Chip tone="mute">Not uploaded</Chip>}
          {latest && latest.status !== "committed" ? (
            <Link className="btn" href={href(`/data/${latest.batch_id}`)}>Continue</Link>
          ) : (
            <button type="button" className="btn" onClick={() => { chooseTemplate(code); document.getElementById("upload-file")?.focus(); }}>
              {committed(code) ? "Upload a new version" : "Upload"}
            </button>
          )}
        </div>
      </li>
    );
  };

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <h1>Data Centre · {period.label}</h1>
          <p>Upload the reports you already produce. Each layout is mapped once and reused on later uploads.</p>
        </div>

        {imports.loading ? <><Skeleton width="60%" /><Skeleton width="40%" /></> : imports.error ? (
          <ErrorPanel message={imports.error.message} correlationId={imports.error.correlationId} />
        ) : (
          <div className="stack">
            <Card title="Needed for the Management P&L">
              <ul className="list-plain">{TEMPLATES.filter((t) => t.core).map((t) => statusRow(t.code))}</ul>
            </Card>

            <Card title="Calculation">
              <CalculationPanel periodId={period.id} ready={committed("T1")} resultHref={href("/analysis/pnl")}
                onCompleted={imports.reload} />
            </Card>

            <Card title="Upload a file">
              <div className="stack">
                <div className="g2">
                  <Select label="What is this file?" id="upload-template" value={template}
                    onChange={(e) => chooseTemplate(e.target.value as TemplateCode)}>
                    {TEMPLATES.map((t) => <option key={t.code} value={t.code}>{t.label}</option>)}
                  </Select>
                  {info.scenarios.length > 1 ? (
                    <Select label="Compared as" id="upload-scenario" value={scenario}
                      onChange={(e) => setScenario(e.target.value as Scenario)}>
                      {info.scenarios.map((s) => <option key={s} value={s}>{SCENARIO_LABEL[s]}</option>)}
                    </Select>
                  ) : <div />}
                </div>
                <div className="fld">
                  <label className="fld-l" htmlFor="upload-file">File (CSV or Excel, up to 25 MB)</label>
                  <input id="upload-file" type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
                  <span className="hint">{info.purpose} Into period <strong>{period.label}</strong>.</span>
                </div>
                {upload.error ? <ErrorPanel message={upload.error.message} correlationId={upload.error.correlationId} /> : null}
                <div className="actions-bar">
                  <Button type="button" variant="primary" disabled={!file} loading={upload.busy} onClick={() => void uploadAndRead()}>
                    Upload and read
                  </Button>
                  <span className="muted">Files are checked for safety before anything is read.</span>
                </div>
              </div>
            </Card>

            <Disclosure summary={`More data for deeper analysis (${TEMPLATES.filter((t) => !t.core).length} optional files)`}>
              <ul className="list-plain">{TEMPLATES.filter((t) => !t.core).map((t) => statusRow(t.code))}</ul>
            </Disclosure>

            {batches.length > 0 ? (
              <DataTable<ImportBatchSummary>
                caption={`Files for ${period.label}`}
                rows={batches}
                rowKey={(b) => b.batch_id}
                columns={[
                  { key: "file", header: "File", render: (b) => <Link href={href(`/data/${b.batch_id}`)}>{b.original_filename}</Link> },
                  { key: "type", header: "Type", render: (b) => templateInfo(b.template_code)?.label ?? b.template_code },
                  { key: "scenario", header: "As", render: (b) => SCENARIO_LABEL[b.scenario] ?? b.scenario },
                  { key: "size", header: "Size", align: "right", render: (b) => formatBytes(b.size_bytes) },
                  { key: "status", header: "Status", render: (b) => { const s = batchStatus(b.status); return <Chip tone={s.tone}>{s.text}</Chip>; } },
                  { key: "when", header: "Uploaded", render: (b) => formatDateTime(b.uploaded_at) },
                ]}
              />
            ) : (
              <EmptyState title="No files for this period yet">Start with the month’s P&amp;L, then the budget.</EmptyState>
            )}
          </div>
        )}
      </div>
    </main>
  );
}
