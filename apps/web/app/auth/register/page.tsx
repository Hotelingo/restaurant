import { safeReturnTo } from "@/lib/navigation";
import RegisterClient from "./RegisterClient";

export default async function RegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string }>;
}) {
  const params = await searchParams;
  return <RegisterClient returnTo={safeReturnTo(params.returnTo)} />;
}
