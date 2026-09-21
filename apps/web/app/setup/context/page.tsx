import Link from "next/link";
import { EmptyState } from "@/components/ui";

export default function ContextSetupPage() {
  return (
    <main className="shell">
      <div className="panel">
        <ol className="stepper" aria-label="Setup progress">
          <li className="done">1 Organisation</li><li className="done">2 Outlet</li><li className="cur">3 Context</li><li>4 Period</li>
        </ol>
        <EmptyState
          title="Organisation and outlet created"
          action={<Link className="btn p" href="/app">Continue to foundation home</Link>}
        >
          The next implementation unit creates restaurant context version 1 and the first reporting period.
        </EmptyState>
      </div>
    </main>
  );
}
