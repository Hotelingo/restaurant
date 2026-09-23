import { useId, type ReactNode } from "react";

export function EmptyState({
  title,
  children,
  action,
}: {
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}) {
  const titleId = useId();

  return (
    <section className="empty" aria-labelledby={titleId}>
      <h2 id={titleId}>{title}</h2>
      {children ? <div className="empty-copy">{children}</div> : null}
      {action ? <div className="empty-action">{action}</div> : null}
    </section>
  );
}
