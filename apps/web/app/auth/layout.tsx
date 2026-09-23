import type { ReactNode } from "react";
import { ResetApiSession } from "@/components/auth/ResetApiSession";

export default function AuthLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <ResetApiSession />
      {children}
    </>
  );
}
