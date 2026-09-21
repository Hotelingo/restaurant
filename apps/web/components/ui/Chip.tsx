import type { ReactNode } from "react";

type Tone = "ok" | "warn" | "bad" | "info" | "mute";

export function Chip({ tone = "mute", children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`chip ${tone}`}>{children}</span>;
}
