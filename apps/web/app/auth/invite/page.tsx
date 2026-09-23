import InviteClient from "./InviteClient";

export default async function InvitePage({
  searchParams,
}: {
  searchParams: Promise<{ token?: string }>;
}) {
  const params = await searchParams;
  return <InviteClient token={params.token ?? ""} />;
}
