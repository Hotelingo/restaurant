import SettingsClient from "./SettingsClient";

export default async function Page({
  params,
}: {
  params: Promise<{ outletId: string }>;
}) {
  const { outletId } = await params;
  return <SettingsClient outletId={outletId} />;
}
