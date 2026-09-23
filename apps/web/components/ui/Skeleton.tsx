export function Skeleton({ width = "100%" }: { width?: string }) {
  return <span className="sk" style={{ width }} aria-hidden="true" />;
}
