import AuditLogClient from "./AuditLogClient";

export default async function Page({
  params,
}: {
  params: Promise<{ organisationId: string }>;
}) {
  const { organisationId } = await params;
  return <AuditLogClient organisationId={organisationId} />;
}
