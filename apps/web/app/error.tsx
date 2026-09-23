"use client";

import { Button, ErrorPanel } from "@/components/ui";

export default function ErrorPage({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <main className="shell"><div className="panel">
      <ErrorPanel
        message="The application could not complete this screen."
        correlationId={error.digest}
        action={<Button onClick={reset}>Retry</Button>}
      />
    </div></main>
  );
}
