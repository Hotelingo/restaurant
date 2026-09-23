import ReconciliationClient from "./ReconciliationClient";

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ outletId: string }>;
  searchParams: Promise<{ period?: string }>;
}) {
  const { outletId } = await params;
  const { period } = await searchParams;
  return <ReconciliationClient outletId={outletId} periodId={period} />;
}
