"use client";

import { createContext, useContext } from "react";
import type { SetupSummaryResponse } from "./contracts";

export type OutletContextValue = {
  outletId: string;
  summary: SetupSummaryResponse;
  /** The period in view: `?period=` if present, otherwise the latest period. */
  periodId: string | null;
  /** Outlet-scoped href that keeps the selected period, e.g. href("/data"). */
  href: (path?: string, extra?: Record<string, string>) => string;
  /** Re-read outlet summary (e.g. after creating a period). */
  refresh: () => void;
  /** The signed-in user, for "your decision" / independence hints. */
  userId: string;
  /** Organisation and outlet roles of the signed-in user. The API enforces them; the UI only hides what would be refused. */
  roles: string[];
  can: (...anyOf: string[]) => boolean;
};

export const OutletContext = createContext<OutletContextValue | null>(null);

export function useOutlet(): OutletContextValue {
  const value = useContext(OutletContext);
  if (!value) throw new Error("useOutlet must be used inside an outlet page");
  return value;
}

export function latestPeriodId(summary: SetupSummaryResponse): string | null {
  const sorted = [...summary.periods].sort((a, b) => b.period_start.localeCompare(a.period_start));
  return sorted[0]?.id ?? null;
}
