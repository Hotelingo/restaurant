"use client";

import { createContext, useContext, useMemo, useState, type ReactNode } from "react";

type OrganisationDraft = { name: string; slug: string };
type SetupDraftValue = {
  organisation: OrganisationDraft | null;
  setOrganisation: (value: OrganisationDraft) => void;
};

const SetupDraftContext = createContext<SetupDraftValue | null>(null);

export function SetupDraftProvider({ children }: { children: ReactNode }) {
  const [organisation, setOrganisation] = useState<OrganisationDraft | null>(null);
  const value = useMemo(() => ({ organisation, setOrganisation }), [organisation]);
  return <SetupDraftContext.Provider value={value}>{children}</SetupDraftContext.Provider>;
}

export function useSetupDraft() {
  const value = useContext(SetupDraftContext);
  if (!value) throw new Error("useSetupDraft must be used inside SetupDraftProvider");
  return value;
}
