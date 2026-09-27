import FoodCostClient from "./FoodCostClient";

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ outletId: string }>;
  searchParams: Promise<{ period?: string }>;
}) {
  const { outletId } = await params;
  const { period } = await searchParams;
  return <FoodCostClient outletId={outletId} periodId={period} />;
}
