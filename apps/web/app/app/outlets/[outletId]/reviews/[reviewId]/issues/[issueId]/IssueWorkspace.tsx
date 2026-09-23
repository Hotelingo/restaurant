"use client";

import Link from "next/link";
import { useState } from "react";
import { Button, Card, Chip, ErrorPanel, Field, Select, Skeleton, TextArea } from "@/components/ui";
import { apiMutate } from "@/lib/api";
import type {
  ActionListResponse, ActionMutationResponse, DecisionCreateRequest, DecisionRead, Disposition, EvidenceStatus,
  IssueDecisionWorkspaceResponse, IssueEvidenceWorkspaceResponse, ReviewIssueListResponse,
} from "@/lib/contracts";
import { formatAmount, formatDate, formatDateTime, humanise } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import {
  ACTION_STATUS_LABEL, DECISION_FIELD, DISPOSITIONS, DRIVERS, EVIDENCE_LABEL, evidenceTone, isNegative,
  type DecisionField,
} from "@/lib/review";
import { useApi, useMutation, useSubmitKey } from "@/lib/use-api";

type DiagnosisState = "supported" | "hypothesis" | "unknown";

const STATE_META: Record<DiagnosisState, { label: string; help: string; evidence: EvidenceStatus[]; summary: "supported_summary" | "hypothesis_summary" | "unknowns"; summaryLabel: string }> = {
  supported: {
    label: "Supported",
    help: "Evidence shows what drove the movement.",
    evidence: ["supported", "validated"],
    summary: "supported_summary",
    summaryLabel: "What the evidence shows",
  },
  hypothesis: {
    label: "Hypothesis",
    help: "A likely explanation that is not yet evidenced.",
    evidence: ["partly_supported", "evidence_required", "not_reconciled", "not_applicable"],
    summary: "hypothesis_summary",
    summaryLabel: "The hypothesis",
  },
  unknown: {
    label: "Unknown",
    help: "The cause is not known yet. Say what is missing.",
    evidence: ["evidence_required", "partly_supported", "not_reconciled", "not_applicable"],
    summary: "unknowns",
    summaryLabel: "What is unknown",
  },
};

export default function IssueWorkspace({ reviewId, issueId }: { reviewId: string; issueId: string }) {
  const { href, can } = useOutlet();
  const issues = useApi<ReviewIssueListResponse>(`/reviews/${reviewId}/issues`);
  const evidence = useApi<IssueEvidenceWorkspaceResponse>(`/issues/${issueId}/evidence`);
  const decisions = useApi<IssueDecisionWorkspaceResponse>(`/issues/${issueId}/decisions`);
  const actions = useApi<ActionListResponse>(`/reviews/${reviewId}/actions`);
  const canEdit = can("admin", "editor");

  const issue = issues.data?.issues.find((i) => i.id === issueId) ?? null;
  if (issues.loading || evidence.loading || decisions.loading) {
    return <main className="shell"><div className="panel wide"><Skeleton width="45%" /><Skeleton width="70%" /></div></main>;
  }
  if (!issue || evidence.error) {
    return (
      <main className="shell"><div className="panel wide">
        <ErrorPanel message={evidence.error?.message ?? "This movement is not available."} correlationId={evidence.error?.correlationId}
          action={<Link className="btn" href={href(`/reviews/${reviewId}`)}>Back to the review</Link>} />
      </div></main>
    );
  }

  const ws = evidence.data!;
  const active = decisions.data?.active_decision ?? null;
  const issueActions = (actions.data?.actions ?? []).filter((a) => a.review_issue_id === issueId);
  const refreshAll = () => { evidence.reload(); decisions.reload(); issues.reload(); actions.reload(); };

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <p className="muted" style={{ margin: 0 }}><Link href={href(`/reviews/${reviewId}`)}>← Review</Link></p>
          <div className="row sb">
            <h1>{issue.title}</h1>
            <Chip tone={evidenceTone(ws.issue_evidence_status)}>{EVIDENCE_LABEL[ws.issue_evidence_status as EvidenceStatus] ?? humanise(ws.issue_evidence_status)}</Chip>
          </div>
          <p>
            Profit effect <strong className={isNegative(issue.movement_amount) ? "adverse" : "favourable"}>{formatAmount(issue.movement_amount)}</strong>
            {" · "}shortlisted by {issue.materiality_rules.map(humanise).join(", ")}
          </p>
        </div>

        <div className="stack">
          <Card title="1 · Diagnose">
            <DiagnosisPanel issueId={issueId} workspace={ws} canEdit={canEdit && !active} onSaved={refreshAll} />
          </Card>

          <Card title="2 · Decide">
            {active ? (
              <DecisionSummary decision={active} />
            ) : canEdit ? (
              // Remount on a new diagnosis so the allowed options and the default are re-evaluated.
              <DecisionForm key={ws.latest_diagnosis?.id ?? "none"} issueId={issueId} workspace={ws} onSaved={refreshAll} />
            ) : (
              <p className="muted" style={{ margin: 0 }}>No decision yet. An admin or editor records it.</p>
            )}
          </Card>

          {active && active.disposition !== "CLOSE" ? (
            <Card title="3 · Action">
              <ActionPanel decision={active} actions={issueActions} canEdit={canEdit} onSaved={refreshAll} actionsHref={href("/actions")} />
            </Card>
          ) : null}

          <div className="actions-bar"><Link className="btn" href={href(`/reviews/${reviewId}`)}>Back to the review</Link></div>
        </div>
      </div>
    </main>
  );
}

function DiagnosisPanel({ issueId, workspace, canEdit, onSaved }: {
  issueId: string; workspace: IssueEvidenceWorkspaceResponse; canEdit: boolean; onSaved: () => void;
}) {
  const latest = workspace.latest_diagnosis;
  const [editing, setEditing] = useState(!latest);
  const [state, setState] = useState<DiagnosisState>((latest?.diagnosis_state as DiagnosisState) ?? "supported");
  const meta = STATE_META[state];
  const [driver, setDriver] = useState(latest?.driver_code ?? "");
  const [status, setStatus] = useState<EvidenceStatus>(meta.evidence[0]);
  const [summary, setSummary] = useState("");
  const save = useMutation();
  const key = useSubmitKey();

  function chooseState(next: DiagnosisState) {
    setState(next);
    setStatus(STATE_META[next].evidence[0]);
    if (next === "unknown") setDriver("");
  }

  async function submit() {
    const body = {
      diagnosis_state: state,
      driver_code: state === "unknown" ? null : driver || null,
      evidence_status: status,
      supported_summary: state === "supported" ? summary.trim() : null,
      hypothesis_summary: state === "hypothesis" ? summary.trim() : null,
      unknowns: state === "unknown" ? summary.trim() : null,
    };
    const r = await save.run(() => apiMutate(`/issues/${issueId}/diagnosis`, body, { key: key.current() }));
    if (r) { key.rotate(); setEditing(false); setSummary(""); onSaved(); }
  }

  const valid = summary.trim().length > 0 && (state !== "supported" || driver !== "");

  return (
    <div className="stack">
      {latest ? (
        <div className="stack">
          <div className="row sb">
            <div>
              <strong>{STATE_META[latest.diagnosis_state].label}</strong>{latest.driver_name ? <> · {latest.driver_name}</> : null}
              <div className="muted">Version {latest.version_no} · {formatDateTime(latest.created_at)}</div>
            </div>
            <div className="row">
              <Chip tone={evidenceTone(latest.evidence_status)}>{EVIDENCE_LABEL[latest.evidence_status]}</Chip>
              <Chip tone={latest.diagnostic_status === "ready_for_decision" ? "ok" : "warn"}>{humanise(latest.diagnostic_status)}</Chip>
            </div>
          </div>
          <p style={{ margin: 0 }}>{latest.supported_summary ?? latest.hypothesis_summary ?? latest.unknowns}</p>
          {canEdit && !editing ? (
            <div className="actions-bar"><Button type="button" onClick={() => setEditing(true)}>Revise diagnosis</Button></div>
          ) : null}
        </div>
      ) : !canEdit ? <p className="muted" style={{ margin: 0 }}>Not diagnosed yet.</p> : null}

      {canEdit && editing ? (
        <form className="stack" onSubmit={(e) => { e.preventDefault(); if (valid) void submit(); }}>
          <fieldset className="choice">
            <legend>How well is the cause understood?</legend>
            {(Object.keys(STATE_META) as DiagnosisState[]).map((s) => (
              <label key={s} className={state === s ? "on" : ""}>
                <input type="radio" name="diagnosis-state" value={s} checked={state === s} onChange={() => chooseState(s)} />
                <span>{STATE_META[s].label}<small>{STATE_META[s].help}</small></span>
              </label>
            ))}
          </fieldset>
          <div className="g2">
            {state !== "unknown" ? (
              <Select label={state === "supported" ? "Driver" : "Likely driver (optional)"} id="diagnosis-driver" value={driver}
                onChange={(e) => setDriver(e.target.value)} required={state === "supported"}>
                <option value="">{state === "supported" ? "Choose the driver…" : "Not yet known"}</option>
                {DRIVERS.map((d) => <option key={d.code} value={d.code}>{d.name}</option>)}
              </Select>
            ) : <div />}
            <Select label="Evidence status" id="diagnosis-evidence" value={status} onChange={(e) => setStatus(e.target.value as EvidenceStatus)}>
              {meta.evidence.map((e) => <option key={e} value={e}>{EVIDENCE_LABEL[e]}</option>)}
            </Select>
          </div>
          <TextArea label={meta.summaryLabel} id="diagnosis-summary" value={summary} onChange={(e) => setSummary(e.target.value)} required
            hint="Describe the evidence, not a person. Avoid absolute words such as always or never." />
          {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
          <div className="actions-bar">
            <Button type="submit" variant="primary" loading={save.busy} disabled={!valid}>Save diagnosis</Button>
            {latest ? <Button type="button" onClick={() => setEditing(false)}>Cancel</Button> : null}
          </div>
        </form>
      ) : null}
    </div>
  );
}

function allowedDispositions(workspace: IssueEvidenceWorkspaceResponse): { disposition: Disposition; allowed: boolean; why?: string }[] {
  const evidenceRequired = workspace.issue_evidence_status === "evidence_required";
  const ready = workspace.latest_diagnosis?.diagnostic_status === "ready_for_decision";
  return (Object.keys(DISPOSITIONS) as Disposition[]).map((d) => {
    if (evidenceRequired && (d === "ACT" || d === "MONITOR" || d === "CLOSE")) {
      return { disposition: d, allowed: false, why: "Evidence is required first: investigate or escalate." };
    }
    if (d === "ACT" && !ready) return { disposition: d, allowed: false, why: "Needs a supported diagnosis first." };
    return { disposition: d, allowed: true };
  });
}

function DecisionForm({ issueId, workspace, onSaved }: { issueId: string; workspace: IssueEvidenceWorkspaceResponse; onSaved: () => void }) {
  const options = allowedDispositions(workspace);
  const firstAllowed = options.find((o) => o.allowed)?.disposition ?? "INVESTIGATE";
  const [disposition, setDisposition] = useState<Disposition>(firstAllowed);
  const [text, setText] = useState("");
  const [fields, setFields] = useState<Partial<Record<DecisionField, string>>>({});
  const save = useMutation();
  const key = useSubmitKey();
  const meta = DISPOSITIONS[disposition];
  const openRequests = workspace.evidence_requests.filter((r) => r.status === "open");
  const shown: DecisionField[] = [...new Set([...meta.required, ...meta.optional])];

  const value = (f: DecisionField) => (fields[f] ?? "").trim();
  const missing = meta.required.filter((f) => !value(f));
  const anyOfMissing = meta.anyOf ? !meta.anyOf.some((f) => value(f)) : false;
  const valid = text.trim().length > 0 && missing.length === 0 && !anyOfMissing;

  async function submit() {
    const body: DecisionCreateRequest = { disposition, decision_text: text.trim() };
    for (const f of shown) if (value(f)) (body as Record<string, string>)[f] = value(f);
    const r = await save.run(() => apiMutate<{ decision: DecisionRead }>(`/issues/${issueId}/decision`, body, { key: key.current() }));
    if (r) { key.rotate(); onSaved(); }
  }

  return (
    <form className="stack" onSubmit={(e) => { e.preventDefault(); if (valid) void submit(); }}>
      <fieldset className="choice">
        <legend>Decision</legend>
        {options.map((o) => (
          <label key={o.disposition} className={disposition === o.disposition ? "on" : ""} aria-disabled={!o.allowed}
            style={o.allowed ? undefined : { opacity: 0.55, cursor: "not-allowed" }}>
            <input type="radio" name="disposition" value={o.disposition} checked={disposition === o.disposition}
              disabled={!o.allowed} onChange={() => setDisposition(o.disposition)} />
            <span>{DISPOSITIONS[o.disposition].label}<small>{o.allowed ? DISPOSITIONS[o.disposition].help : o.why}</small></span>
          </label>
        ))}
      </fieldset>

      <TextArea label="Decision" id="decision-text" value={text} onChange={(e) => setText(e.target.value)} required
        hint="One or two sentences the owner can act on." />

      {disposition === "INVESTIGATE" ? (
        <EvidenceRequestBlock issueId={issueId} openRequests={openRequests} selected={fields.evidence_request_id ?? ""}
          onSelect={(id) => setFields((s) => ({ ...s, evidence_request_id: id }))} onCreated={onSaved} />
      ) : null}

      <div className="g2">
        {shown.filter((f) => f !== "evidence_request_id").map((f) => {
          const def = DECISION_FIELD[f];
          const required = meta.required.includes(f);
          const common = { id: `decision-${f}`, value: fields[f] ?? "", required,
            onChange: (e: { target: { value: string } }) => setFields((s) => ({ ...s, [f]: e.target.value })) };
          const label = `${def.label}${required ? "" : meta.anyOf?.includes(f) ? " (this or the other)" : " (optional)"}`;
          return def.type === "long"
            ? <TextArea key={f} label={label} hint={def.hint} {...common} />
            : <Field key={f} label={label} hint={def.hint} type={def.type === "date" ? "date" : "text"} {...common} />;
        })}
      </div>

      {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
      <div className="actions-bar">
        <Button type="submit" variant="primary" loading={save.busy} disabled={!valid}>Record decision</Button>
        {!valid ? <span className="muted">{anyOfMissing ? "Give a due date or a cadence. " : ""}{missing.length ? `${missing.length} required field(s) left.` : text.trim() ? "" : "Write the decision."}</span> : null}
      </div>
    </form>
  );
}

function EvidenceRequestBlock({ issueId, openRequests, selected, onSelect, onCreated }: {
  issueId: string; openRequests: IssueEvidenceWorkspaceResponse["evidence_requests"]; selected: string;
  onSelect: (id: string) => void; onCreated: () => void;
}) {
  const [creating, setCreating] = useState(openRequests.length === 0);
  const [form, setForm] = useState({ requested_dataset: "", reason: "", minimum_fields: "", owner: "", due_date: "" });
  const save = useMutation();
  const key = useSubmitKey();
  const valid = form.requested_dataset.trim() && form.reason.trim() && form.owner.trim() && form.due_date;

  async function submit() {
    const r = await save.run(() => apiMutate<{ evidence_request: { id: string } }>(`/issues/${issueId}/evidence-requests`, {
      requested_dataset: form.requested_dataset.trim(),
      reason: form.reason.trim(),
      minimum_fields: form.minimum_fields.split(",").map((s) => s.trim()).filter(Boolean),
      owner: form.owner.trim(),
      due_date: form.due_date,
    }, { key: key.current() }));
    if (r) { key.rotate(); setCreating(false); onCreated(); }
  }

  return (
    <div className="card" style={{ border: "1px solid var(--line)" }}>
      <div className="card-h"><h2>Evidence request</h2></div>
      {openRequests.length > 0 ? (
        <Select label="Request this decision waits on" id="decision-evidence_request_id" value={selected} onChange={(e) => onSelect(e.target.value)} required>
          <option value="">Choose…</option>
          {openRequests.map((r) => <option key={r.id} value={r.id}>{r.requested_dataset} · {r.owner} · due {formatDate(r.due_date)}</option>)}
        </Select>
      ) : null}
      {creating ? (
        <div className="stack">
          <div className="g2">
            <Field id="er-dataset" label="Data needed" value={form.requested_dataset} onChange={(e) => setForm({ ...form, requested_dataset: e.target.value })} hint="e.g. Stock count by category" required />
            <Field id="er-owner" label="Owner" value={form.owner} onChange={(e) => setForm({ ...form, owner: e.target.value })} required />
            <Field id="er-fields" label="Minimum fields (comma-separated)" value={form.minimum_fields} onChange={(e) => setForm({ ...form, minimum_fields: e.target.value })} />
            <Field id="er-due" label="Due date" type="date" value={form.due_date} onChange={(e) => setForm({ ...form, due_date: e.target.value })} required />
          </div>
          <TextArea id="er-reason" label="Why it is needed" value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} required />
          {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
          <div className="actions-bar">
            <Button type="button" loading={save.busy} disabled={!valid} onClick={() => void submit()}>Create evidence request</Button>
            {openRequests.length > 0 ? <Button type="button" onClick={() => setCreating(false)}>Cancel</Button> : null}
          </div>
        </div>
      ) : (
        <div className="actions-bar"><Button type="button" onClick={() => setCreating(true)}>New evidence request</Button></div>
      )}
    </div>
  );
}

function DecisionSummary({ decision }: { decision: DecisionRead }) {
  const meta = DISPOSITIONS[decision.disposition];
  const shown = [...new Set([...meta.required, ...meta.optional])].filter((f) => f !== "evidence_request_id" && decision[f]);
  return (
    <div className="stack">
      <div className="row sb">
        <div><Chip tone="ok">{meta.label}</Chip> <span className="muted">Version {decision.version_no} · {formatDateTime(decision.decided_at)}</span></div>
      </div>
      <p style={{ margin: 0 }}>{decision.decision_text}</p>
      {shown.length ? (
        <dl className="kv">
          {shown.map((f) => (
            <FragmentRow key={f} label={DECISION_FIELD[f].label}
              value={DECISION_FIELD[f].type === "date" ? formatDate(decision[f]) : String(decision[f])} />
          ))}
        </dl>
      ) : null}
    </div>
  );
}

function FragmentRow({ label, value }: { label: string; value: string }) {
  return <><dt>{label}</dt><dd>{value}</dd></>;
}

function ActionPanel({ decision, actions, canEdit, onSaved, actionsHref }: {
  decision: DecisionRead; actions: ActionListResponse["actions"]; canEdit: boolean; onSaved: () => void; actionsHref: string;
}) {
  const [owner, setOwner] = useState(decision.owner ?? "");
  const [forecast, setForecast] = useState("");
  const save = useMutation();
  const key = useSubmitKey();

  async function submit() {
    const r = await save.run(() => apiMutate<ActionMutationResponse>(`/decisions/${decision.id}/actions`, {
      owner: owner.trim(), forecast_effect: forecast.trim() || null,
    }, { key: key.current() }));
    if (r) { key.rotate(); onSaved(); }
  }

  if (actions.length > 0) {
    return (
      <div className="stack">
        {actions.map((a) => (
          <div key={a.id} className="row sb">
            <div>
              <strong>{a.owner}</strong>{a.lever ? <> · {a.lever}</> : null}
              <div className="muted">{a.due_date ? `Due ${formatDate(a.due_date)}` : a.cadence ? `Checked ${a.cadence}` : null}</div>
            </div>
            <Chip tone={a.status === "CLOSED" ? "ok" : a.status === "OPEN_ON_TRACK" ? "info" : "warn"}>{ACTION_STATUS_LABEL[a.status] ?? a.status}</Chip>
          </div>
        ))}
        <div className="actions-bar"><Link className="btn" href={actionsHref}>Open the action register</Link></div>
      </div>
    );
  }
  if (!canEdit) return <p className="muted" style={{ margin: 0 }}>No action registered yet.</p>;
  return (
    <form className="stack" onSubmit={(e) => { e.preventDefault(); if (owner.trim()) void submit(); }}>
      <p className="muted" style={{ margin: 0 }}>Put the decision on the action register so it is followed up next period.</p>
      <div className="g2">
        <Field id="action-owner" label="Owner" value={owner} onChange={(e) => setOwner(e.target.value)} required />
        <Field id="action-forecast" label="Forecast effect (optional)" value={forecast} onChange={(e) => setForecast(e.target.value)}
          hint="How the forecast treats this, in words." />
      </div>
      {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
      <div className="actions-bar"><Button type="submit" variant="primary" loading={save.busy} disabled={!owner.trim()}>Add to action register</Button></div>
    </form>
  );
}
