import Link from "next/link";
import { EmptyState } from "@/components/ui";

export default function ResetPage() {
  return (
    <main className="shell">
      <div className="panel">
        <EmptyState
          title="Password recovery is being wired"
          action={<Link className="btn" href="/auth/sign-in">Back to sign in</Link>}
        >
          Neon supports password-reset links, but its current SDK requires the managed reset UI.
          We will integrate that flow without introducing a second visual system.
        </EmptyState>
      </div>
    </main>
  );
}
