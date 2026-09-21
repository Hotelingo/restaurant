"use server";

import { auth } from "@/lib/auth/server";
import { redirect } from "next/navigation";

export type SignInState = { error?: string };

export async function signInWithEmail(
  _previous: SignInState,
  formData: FormData,
): Promise<SignInState> {
  const email = String(formData.get("email") ?? "");
  const password = String(formData.get("password") ?? "");

  if (!email || !password) return { error: "Email and password are required." };

  const { error } = await auth.signIn.email({ email, password });

  if (error) {
    return { error: "Sign-in was not accepted. Check your details and try again." };
  }

  redirect("/auth/continue");
}
