import LabourClient from "./LabourClient";

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ outletId: string }>;
  searchParams: Promise<{ period?: string }>;
}) {
  const { outletId } = await params;
  const { period } = await searchParams;
  return <LabourClient outletId={outletId} periodId={period} />;
}
