import { safeReturnTo } from "@/lib/navigation";
import SignInClient from "./SignInClient";

export default async function SignInPage({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string }>;
}) {
  const params = await searchParams;
  return <SignInClient returnTo={safeReturnTo(params.returnTo)} />;
}
