import { Suspense } from "react";
import SetupCompleteClient from "./SetupCompleteClient";
import { Skeleton } from "@/components/ui";

export default function Page() {
  return (
    <Suspense
      fallback={
        <main className="shell">
          <div className="panel">
            <Skeleton />
            <Skeleton width="64%" />
          </div>
        </main>
      }
    >
      <SetupCompleteClient />
    </Suspense>
  );
}
