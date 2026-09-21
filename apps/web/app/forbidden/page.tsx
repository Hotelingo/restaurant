import Link from "next/link";
import { EmptyState } from "@/components/ui";

export default function ForbiddenPage() {
  return (
    <main className="shell"><div className="panel">
      <EmptyState title="You do not have access to this area" action={<Link className="btn" href="/auth/continue">Return to an authorised area</Link>}>
        Ask an organisation administrator if you believe your role or outlet scope should be changed.
      </EmptyState>
    </div></main>
  );
}
