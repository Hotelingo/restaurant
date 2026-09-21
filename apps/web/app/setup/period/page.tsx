import PeriodSetupClient from "./PeriodSetupClient";

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{
    outlet?: string;
    organisation?: string;
    contextVersion?: string;
  }>;
}) {
  const params = await searchParams;
  return (
    <PeriodSetupClient
      outletId={params.outlet ?? null}
      organisationId={params.organisation ?? null}
      contextVersion={params.contextVersion ?? null}
    />
  );
}
