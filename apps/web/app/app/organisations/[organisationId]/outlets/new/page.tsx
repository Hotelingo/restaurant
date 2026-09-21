import NewOutletClient from "./NewOutletClient";

export default async function Page({
  params,
}: {
  params: Promise<{ organisationId: string }>;
}) {
  const { organisationId } = await params;
  return <NewOutletClient organisationId={organisationId} />;
}
