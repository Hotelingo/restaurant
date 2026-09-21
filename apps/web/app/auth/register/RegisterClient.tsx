"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { authClient } from "@/lib/auth/client";
import { Button, Card, Field } from "@/components/ui";

export default function RegisterClient({ returnTo }: { returnTo: string }) {
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [createdWithoutSession, setCreatedWithoutSession] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const name = String(form.get("name") ?? "").trim();
    const email = String(form.get("email") ?? "").trim();
    const password = String(form.get("password") ?? "");

    if (password.length < 12) {
      setError("Use at least 12 characters. Passphrases are allowed.");
      return;
    }

    setPending(true);
    setError(null);
    setCreatedWithoutSession(false);

    const { error: authError } = await authClient.signUp.email({
      email,
      password,
      name: name || email.split("@")[0] || "User",
    });

    if (authError) {
      setError("Account creation was not completed. Check the details and try again.");
      setPending(false);
      return;
    }

    const session = await authClient.getSession();
    if (session.data?.session) {
      router.replace(returnTo);
      return;
    }

    setCreatedWithoutSession(true);
    setPending(false);
  }

  return (
    <main className="shell">
      <div className="panel">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <div><b>Restaurant Performance Review</b><span>Evidence-led financial review</span></div>
        </div>
        <div className="page-head">
          <h1>Create account</h1>
          <p>Create your sign-in identity. Organisation access is granted separately by membership or invitation.</p>
        </div>

        <Card>
          <form onSubmit={submit} className="stack">
            <Field label="Name" name="name" autoComplete="name" />
            <Field label="Email" name="email" type="email" autoComplete="email" required />
            <Field
              label="Password"
              name="password"
              type="password"
              autoComplete="new-password"
              minLength={12}
              hint="Minimum 12 characters. Passphrases and password managers are supported."
              required
            />
            {error ? <div className="banner bad" role="alert">{error}</div> : null}
            {createdWithoutSession ? (
              <div className="banner info" role="status">
                Account created. Complete any email verification requested by the authentication service, then sign in.
              </div>
            ) : null}
            <Button type="submit" variant="primary" loading={pending}>Create account</Button>
          </form>
        </Card>

        <div className="row sb mt8">
          <Link href={`/auth/sign-in?returnTo=${encodeURIComponent(returnTo)}`}>Already have an account? Sign in</Link>
          <span className="muted">AUTH03 support</span>
        </div>
      </div>
    </main>
  );
}
