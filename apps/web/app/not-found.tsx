import Link from "next/link";
import { EmptyState } from "@/components/ui";

export default function NotFound() {
  return (
    <main className="shell"><div className="panel">
      <EmptyState title="This resource is not available" action={<Link className="btn" href="/auth/continue">Return</Link>}>
        It may not exist, may have been removed, or may not be available in your authorised context.
      </EmptyState>
    </div></main>
  );
}
