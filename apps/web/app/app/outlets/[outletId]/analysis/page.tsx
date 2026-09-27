import AnalyticsHomeClient from "./AnalyticsHomeClient";

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ outletId: string }>;
  searchParams: Promise<{ period?: string }>;
}) {
  const { outletId } = await params;
  const { period } = await searchParams;
  return <AnalyticsHomeClient outletId={outletId} periodId={period} />;
}
