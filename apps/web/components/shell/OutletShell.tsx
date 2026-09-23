"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { apiFetch, ApiError, clearApiTokenCache } from "@/lib/api";
import { authClient } from "@/lib/auth/client";
import type { AuthContextResponse, SetupSummaryResponse } from "@/lib/contracts";
import { OutletContext, latestPeriodId } from "@/lib/outlet-context";
import { ErrorPanel, Skeleton } from "@/components/ui";

type NavItem = { label: string; path: string; match: (rest: string) => boolean };
type NavGroup = { area: string; items: NavItem[] };

// The v4.2 six customer areas. Paths are relative to /app/outlets/{id}.
const NAV: NavGroup[] = [
  { area: "Home", items: [{ label: "Outlet home", path: "", match: (r) => r === "" }] },
  {
    area: "Data Centre",
    items: [{ label: "Uploads and mapping", path: "/data", match: (r) => r.startsWith("/data") }],
  },
  {
    area: "Analysis",
    items: [
      { label: "Management P&L", path: "/analysis/pnl", match: (r) => r.startsWith("/analysis/pnl") },
      { label: "Reconciliation", path: "/analysis/reconciliation", match: (r) => r.startsWith("/analysis/reconciliation") },
    ],
  },
  {
    area: "Review & Actions",
    items: [
      { label: "Reviews", path: "/reviews", match: (r) => r.startsWith("/reviews") },
      { label: "Action register", path: "/actions", match: (r) => r.startsWith("/actions") },
    ],
  },
  {
    area: "Reports & History",
    items: [{ label: "Owner Packs", path: "/reports", match: (r) => r.startsWith("/reports") || r.startsWith("/packs") }],
  },
  { area: "Settings", items: [{ label: "Settings and controls", path: "/settings", match: (r) => r.startsWith("/settings") }] },
];

export function OutletShell({ outletId, children }: { outletId: string; children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const [summary, setSummary] = useState<SetupSummaryResponse | null>(null);
  const [auth, setAuth] = useState<AuthContextResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [navOpen, setNavOpen] = useState(false);
  const [version, setVersion] = useState(0);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      apiFetch<SetupSummaryResponse>(`/outlets/${outletId}/setup-summary`),
      apiFetch<AuthContextResponse>("/auth/context"),
    ])
      .then(([value, context]) => { if (!cancelled) { setSummary(value); setAuth(context); setError(null); } })
      .catch((cause) => {
        if (!cancelled) setError(cause instanceof ApiError ? cause : new ApiError("Unable to load this outlet.", 500, null));
      });
    return () => { cancelled = true; };
  }, [outletId, version]);

  const requested = search.get("period");
  const periodId = useMemo(() => {
    if (!summary) return requested;
    if (requested && summary.periods.some((p) => p.id === requested)) return requested;
    return latestPeriodId(summary);
  }, [summary, requested]);

  const roles = useMemo(() => {
    const org = auth?.organisations.find((o) => o.outlets.some((x) => x.id === outletId));
    const outlet = org?.outlets.find((x) => x.id === outletId);
    return [...new Set([...(org?.roles ?? []), ...(outlet?.roles ?? [])])];
  }, [auth, outletId]);
  const can = useCallback((...anyOf: string[]) => anyOf.some((r) => roles.includes(r)), [roles]);

  const base = `/app/outlets/${outletId}`;
  const href = useCallback(
    (path = "", extra: Record<string, string> = {}) => {
      const params = new URLSearchParams(extra);
      if (periodId && !params.has("period")) params.set("period", periodId);
      const qs = params.toString();
      return `${base}${path}${qs ? `?${qs}` : ""}`;
    },
    [base, periodId],
  );

  const rest = pathname.startsWith(base) ? pathname.slice(base.length) : "";
  useEffect(() => setNavOpen(false), [pathname]);

  async function signOut() {
    await authClient.signOut();
    clearApiTokenCache();
    router.replace("/auth/sign-in");
    router.refresh();
  }

  function choosePeriod(next: string) {
    const params = new URLSearchParams(search.toString());
    params.set("period", next);
    router.replace(`${pathname}?${params.toString()}`);
  }

  if (error) {
    return (
      <main className="shell">
        <div className="panel">
          <ErrorPanel message={error.status === 404 || error.status === 403 ? "This outlet is not available to you." : error.message} correlationId={error.correlationId}
            action={<Link className="btn" href="/app">Back to your outlets</Link>} />
        </div>
      </main>
    );
  }

  return (
    <div className="app-frame">
      <header className="app-top">
        <button type="button" className="app-menu" aria-expanded={navOpen} aria-controls="outlet-nav"
          onClick={() => setNavOpen((v) => !v)}>Menu</button>
        <Link href="/app" className="app-brand">
          <span className="brand-mark" aria-hidden="true" />
          <span>Restaurant Performance Review</span>
        </Link>
        <div className="app-where">
          {summary ? (
            <>
              <span className="app-org">{summary.organisation_name}{roles.length ? ` · ${roles.join(", ")}` : ""}</span>
              <span className="app-outlet">{summary.outlet_name}</span>
            </>
          ) : <Skeleton width="160px" />}
        </div>
        <div className="app-period">
          <label htmlFor="period-picker">Period</label>
          {summary && summary.periods.length > 0 ? (
            <select id="period-picker" value={periodId ?? ""} onChange={(e) => choosePeriod(e.target.value)}>
              {[...summary.periods]
                .sort((a, b) => b.period_start.localeCompare(a.period_start))
                .map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
            </select>
          ) : <span className="app-none">{summary ? "No period yet" : "…"}</span>}
        </div>
        <div className="app-top-actions">
          <Link className="app-top-link" href="/app">All outlets</Link>
          <button type="button" className="app-top-link" onClick={() => void signOut()}>Sign out</button>
        </div>
      </header>

      <nav id="outlet-nav" className={`app-nav${navOpen ? " open" : ""}`} aria-label="Outlet">
        {NAV.map((group) => (
          <div key={group.area} className="app-nav-group">
            <div className="app-nav-area">{group.area}</div>
            {group.items.map((item) => {
              const active = item.match(rest);
              return (
                <Link key={item.path} href={href(item.path)} className={`app-nav-link${active ? " on" : ""}`}
                  aria-current={active ? "page" : undefined}>
                  {item.label}
                </Link>
              );
            })}
          </div>
        ))}
      </nav>

      <div className="app-main">
        {summary && auth ? (
          <OutletContext.Provider value={{
            outletId, summary, periodId, href, refresh: () => setVersion((v) => v + 1), userId: auth.user_id, roles, can,
          }}>
            {children}
          </OutletContext.Provider>
        ) : (
          <div className="panel wide"><Skeleton width="40%" /><Skeleton width="70%" /><Skeleton width="55%" /></div>
        )}
      </div>
    </div>
  );
}
