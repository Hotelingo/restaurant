"use client";

import { useEffect, useState } from "react";
import { apiFetch } from "@/lib/api";
import type { DecisionRead, IssueDecisionWorkspaceResponse } from "@/lib/contracts";

/** Active decision per issue id (null = not decided yet). */
export function useIssueDecisions(issueIds: string[]) {
  const [decisions, setDecisions] = useState<Record<string, DecisionRead | null>>({});
  const [loading, setLoading] = useState(false);
  const key = issueIds.join(",");

  useEffect(() => {
    if (!key) { setDecisions({}); return; }
    let cancelled = false;
    setLoading(true);
    Promise.all(key.split(",").map((id) =>
      apiFetch<IssueDecisionWorkspaceResponse>(`/issues/${id}/decisions`)
        .then((w) => [id, w.active_decision] as const)
        .catch(() => [id, null] as const),
    ))
      .then((pairs) => { if (!cancelled) setDecisions(Object.fromEntries(pairs)); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [key]);

  return { decisions, loading };
}
