import ContextSetupClient from "./ContextSetupClient";

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ outlet?: string; organisation?: string }>;
}) {
  const params = await searchParams;
  return (
    <ContextSetupClient
      outletId={params.outlet ?? null}
      organisationId={params.organisation ?? null}
    />
  );
}
