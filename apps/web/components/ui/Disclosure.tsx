import type { ReactNode } from "react";

export function Disclosure({
  summary,
  children,
}: {
  summary: ReactNode;
  children: ReactNode;
}) {
  return (
    <details className="dt">
      <summary>{summary}</summary>
      <div className="disclosure-body">{children}</div>
    </details>
  );
}
