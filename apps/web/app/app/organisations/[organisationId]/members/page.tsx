import MembersClient from "./MembersClient";

export default async function Page({
  params,
}: {
  params: Promise<{ organisationId: string }>;
}) {
  const { organisationId } = await params;
  return <MembersClient organisationId={organisationId} />;
}
