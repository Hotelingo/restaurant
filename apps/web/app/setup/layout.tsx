import { SetupDraftProvider } from "./SetupDraftContext";

export default function SetupLayout({ children }: { children: React.ReactNode }) {
  return <SetupDraftProvider>{children}</SetupDraftProvider>;
}
