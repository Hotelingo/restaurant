import { Suspense } from "react";
import PeriodSetupClient from "./PeriodSetupClient";
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
      <PeriodSetupClient />
    </Suspense>
  );
}
