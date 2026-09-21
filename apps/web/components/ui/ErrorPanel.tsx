import type { ReactNode } from "react";

export function ErrorPanel({
  title = "Something went wrong",
  message,
  correlationId,
  action,
}: {
  title?: string;
  message: ReactNode;
  correlationId?: string | null;
  action?: ReactNode;
}) {
  return (
    <section className="banner bad" role="alert">
      <strong>{title}</strong>
      <div>{message}</div>
      {correlationId ? (
        <div className="mono">Correlation ID: {correlationId}</div>
      ) : null}
      {action ? <div className="mt8">{action}</div> : null}
    </section>
  );
}
