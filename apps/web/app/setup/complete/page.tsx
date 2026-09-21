import SetupCompleteClient from "./SetupCompleteClient";

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ outlet?: string }>;
}) {
  const params = await searchParams;
  return <SetupCompleteClient outletId={params.outlet ?? null} />;
}
