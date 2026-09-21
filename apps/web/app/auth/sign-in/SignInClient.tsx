"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { Button, Card, Field } from "@/components/ui";
import { signInWithEmail } from "./actions";
import { MagicLinkForm } from "./MagicLinkForm";

export default function SignInClient({ returnTo }: { returnTo: string }) {
  const [mode, setMode] = useState<"password" | "magic">("password");
  const [state, formAction, pending] = useActionState(signInWithEmail, {});

  return (
    <main className="shell">
      <div className="panel">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <div><b>Restaurant Performance Review</b><span>Evidence-led financial review</span></div>
        </div>
        <div className="page-head">
          <h1>Sign in</h1>
          <p>Access is resolved after authentication. No tenant information is exposed here.</p>
        </div>

        <div className="row" role="group" aria-label="Sign-in method">
          <Button type="button" variant={mode === "password" ? "primary" : "default"} onClick={() => setMode("password")}>
            Password
          </Button>
          <Button type="button" variant={mode === "magic" ? "primary" : "default"} onClick={() => setMode("magic")}>
            Magic link
          </Button>
        </div>

        <Card>
          {mode === "password" ? (
            <form action={formAction} className="stack">
              <input type="hidden" name="return_to" value={returnTo} />
              <Field label="Email" name="email" type="email" autoComplete="email" required />
              <Field label="Password" name="password" type="password" autoComplete="current-password" required />
              {state.error ? <div className="banner bad" role="alert">{state.error}</div> : null}
              <Button type="submit" variant="primary" loading={pending}>Sign in</Button>
            </form>
          ) : <MagicLinkForm callbackURL={returnTo} />}
        </Card>

        <div className="row sb mt8">
          <Link href="/auth/reset">Forgot password?</Link>
          <Link href={`/auth/register?returnTo=${encodeURIComponent(returnTo)}`}>Create account</Link>
        </div>
      </div>
    </main>
  );
}
