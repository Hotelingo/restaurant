import { Suspense, type ReactNode } from "react";
import { OutletShell } from "@/components/shell/OutletShell";

export default async function OutletLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ outletId: string }>;
}) {
  const { outletId } = await params;
  // OutletShell reads ?period= via useSearchParams, which needs a Suspense boundary.
  return (
    <Suspense fallback={null}>
      <OutletShell outletId={outletId}>{children}</OutletShell>
    </Suspense>
  );
}
