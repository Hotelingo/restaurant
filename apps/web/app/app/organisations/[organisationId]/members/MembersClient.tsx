"use client";

import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type {
  InvitationCreateResponse,
  MembersResponse,
  MemberRow,
} from "@/lib/contracts";
import {
  Button,
  Card,
  Chip,
  DataTable,
  ErrorPanel,
  Field,
  Select,
  Skeleton,
} from "@/components/ui";

export default function MembersClient({ organisationId }: { organisationId: string }) {
  const [data, setData] = useState<MembersResponse | null>(null);
  const [scope, setScope] = useState<"all_outlets" | "selected_outlets">("all_outlets");
  const [selectedOutlets, setSelectedOutlets] = useState<string[]>([]);
  const [pending, setPending] = useState(false);
  const [memberPending, setMemberPending] = useState<string | null>(null);
  const [inviteLink, setInviteLink] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  async function reload() {
    setError(null);
    try {
      setData(await apiFetch<MembersResponse>(`/organisations/${organisationId}/members`));
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Members and invitations could not be loaded.", 500, null),
      );
    }
  }

  useEffect(() => {
    void reload();
  }, [organisationId]);

  function toggleOutlet(outletId: string) {
    setSelectedOutlets((current) =>
      current.includes(outletId)
        ? current.filter((id) => id !== outletId)
        : [...current, outletId],
    );
  }

  async function invite(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError(null);
    setInviteLink(null);
    setCopied(false);

    try {
      const result = await apiFetch<InvitationCreateResponse>(
        `/organisations/${organisationId}/invitations`,
        {
          method: "POST",
          body: JSON.stringify({
            email: String(form.get("email") ?? ""),
            role: String(form.get("role") ?? "viewer"),
            scope_mode: scope,
            outlet_ids: scope === "selected_outlets" ? selectedOutlets : [],
            expires_in_hours: Number(form.get("expires_in_hours") ?? 72),
          }),
        },
      );

      setInviteLink(`${window.location.origin}${result.accept_path}`);
      event.currentTarget.reset();
      setScope("all_outlets");
      setSelectedOutlets([]);
      await reload();
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Invitation could not be created.", 500, null),
      );
    } finally {
      setPending(false);
    }
  }

  async function setActive(member: MemberRow, active: boolean) {
    setMemberPending(member.membership_id);
    setError(null);
    try {
      await apiFetch(
        `/organisations/${organisationId}/members/${member.membership_id}`,
        {
          method: "PATCH",
          body: JSON.stringify({ active }),
        },
      );
      await reload();
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Membership could not be updated.", 500, null),
      );
    } finally {
      setMemberPending(null);
    }
  }

  async function copyInvite() {
    if (!inviteLink) return;
    await navigator.clipboard.writeText(inviteLink);
    setCopied(true);
  }

  const memberRows = useMemo(() => data?.members ?? [], [data]);
  const invitationRows = useMemo(() => data?.invitations ?? [], [data]);

  return (
    <main className="shell">
      <div className="panel" style={{ width: "min(100%, 1080px)" }}>
        <div className="page-head">
          <h1>Users and roles</h1>
          <p>{data ? data.organisation_name : "Loading authorised organisation access."}</p>
        </div>

        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
        {!data && !error ? <><Skeleton /><Skeleton width="70%" /></> : null}

        {data ? (
          <div className="stack">
            <Card title="Invite person">
              <form onSubmit={invite} className="stack">
                <div className="g2">
                  <Field label="Email" name="email" type="email" autoComplete="email" required />
                  <Select label="Role" name="role" defaultValue="viewer">
                    <option value="admin">Admin</option>
                    <option value="editor">Editor</option>
                    <option value="viewer">Viewer</option>
                    <option value="reviewer">Reviewer</option>
                  </Select>
                  <Select
                    label="Outlet scope"
                    name="scope_mode"
                    value={scope}
                    onChange={(event) => {
                      const value = event.target.value as "all_outlets" | "selected_outlets";
                      setScope(value);
                      if (value === "all_outlets") setSelectedOutlets([]);
                    }}
                  >
                    <option value="all_outlets">All outlets</option>
                    <option value="selected_outlets">Selected outlets</option>
                  </Select>
                  <Field
                    label="Invitation validity (hours)"
                    name="expires_in_hours"
                    type="number"
                    min={1}
                    max={168}
                    defaultValue={72}
                    required
                  />
                </div>

                {scope === "selected_outlets" ? (
                  <fieldset className="card">
                    <legend>Permitted outlets</legend>
                    <div className="stack">
                      {data.outlets.map((outlet) => (
                        <label className="row" key={outlet.id}>
                          <input
                            type="checkbox"
                            checked={selectedOutlets.includes(outlet.id)}
                            onChange={() => toggleOutlet(outlet.id)}
                          />
                          <span>{outlet.name}{outlet.code ? ` · ${outlet.code}` : ""}</span>
                        </label>
                      ))}
                    </div>
                  </fieldset>
                ) : null}

                <div className="banner info">
                  Setup analyst access is not a customer role. It remains a time-limited staff assignment with separate audit controls.
                </div>
                <Button
                  type="submit"
                  variant="primary"
                  loading={pending}
                  disabled={scope === "selected_outlets" && selectedOutlets.length === 0}
                >
                  Create invitation
                </Button>
              </form>

              {inviteLink ? (
                <div className="banner info">
                  <strong>Invitation created.</strong>
                  <p className="mono" style={{ overflowWrap: "anywhere" }}>{inviteLink}</p>
                  <div className="row">
                    <Button type="button" onClick={() => void copyInvite()}>
                      {copied ? "Copied" : "Copy invitation link"}
                    </Button>
                    <span className="muted">
                      Email delivery is not yet configured in-app; share this link securely with the invited person.
                    </span>
                  </div>
                </div>
              ) : null}
            </Card>

            <Card title="People">
              <DataTable
                caption="Organisation memberships"
                rows={memberRows}
                rowKey={(row) => row.membership_id}
                columns={[
                  {
                    key: "person",
                    header: "Person",
                    render: (row) => (
                      <span>{row.display_name || row.email || "User"}{row.email ? <span className="muted"> · {row.email}</span> : null}</span>
                    ),
                  },
                  { key: "role", header: "Role", render: (row) => <Chip tone="info">{row.role}</Chip> },
                  {
                    key: "scope",
                    header: "Outlet scope",
                    render: (row) => row.scope_mode === "all_outlets" ? "All outlets" : row.outlet_names.join(", "),
                  },
                  { key: "status", header: "Status", render: (row) => <Chip tone={row.active ? "ok" : "mute"}>{row.active ? "Active" : "Inactive"}</Chip> },
                  {
                    key: "action",
                    header: "Action",
                    render: (row) => (
                      <Button
                        type="button"
                        loading={memberPending === row.membership_id}
                        disabled={memberPending !== null}
                        onClick={() => void setActive(row, !row.active)}
                      >
                        {row.active ? "Deactivate" : "Reactivate"}
                      </Button>
                    ),
                  },
                ]}
              />
            </Card>

            <Card title="Invitation history">
              {invitationRows.length ? (
                <DataTable
                  caption="Recent invitations"
                  rows={invitationRows}
                  rowKey={(row) => row.invitation_id}
                  columns={[
                    { key: "email", header: "Email", render: (row) => row.email },
                    { key: "role", header: "Role", render: (row) => row.role },
                    {
                      key: "scope",
                      header: "Scope",
                      render: (row) => row.scope_mode === "all_outlets" ? "All outlets" : row.outlet_names.join(", "),
                    },
                    { key: "status", header: "Status", render: (row) => <Chip tone={row.status === "pending" ? "warn" : row.status === "accepted" ? "ok" : "mute"}>{row.status}</Chip> },
                    { key: "expires", header: "Expires", render: (row) => new Date(row.expires_at).toLocaleString() },
                  ]}
                />
              ) : (
                <div className="empty">No invitations have been created yet.</div>
              )}
            </Card>
          </div>
        ) : null}
      </div>
    </main>
  );
}
