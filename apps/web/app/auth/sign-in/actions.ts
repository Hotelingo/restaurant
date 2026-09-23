"use server";

import { auth } from "@/lib/auth/server";
import { safeReturnTo } from "@/lib/navigation";
import { redirect } from "next/navigation";

export type SignInState = { error?: string };

export async function signInWithEmail(
  _previous: SignInState,
  formData: FormData,
): Promise<SignInState> {
  const email = String(formData.get("email") ?? "");
  const password = String(formData.get("password") ?? "");
  const returnTo = safeReturnTo(String(formData.get("return_to") ?? ""));

  if (!email || !password) return { error: "Email and password are required." };

  const { error } = await auth.signIn.email({ email, password });

  if (error) {
    return { error: "Sign-in was not accepted. Check your details and try again." };
  }

  redirect(returnTo);
}
