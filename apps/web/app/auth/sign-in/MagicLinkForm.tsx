"use client";

import { useState } from "react";
import { authClient } from "@/lib/auth/client";
import { Button, Field } from "@/components/ui";

export function MagicLinkForm({ callbackURL }: { callbackURL: string }) {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent" | "error">("idle");

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setState("sending");
    const { error } = await authClient.signIn.magicLink({
      email,
      callbackURL,
    });
    setState(error ? "error" : "sent");
  }

  if (state === "sent") {
    return <div className="banner info" role="status">If the address can receive a sign-in link, check your email.</div>;
  }

  return (
    <form onSubmit={submit} className="stack">
      <Field
        label="Email"
        name="magic-email"
        type="email"
        autoComplete="email"
        value={email}
        onChange={(event) => setEmail(event.target.value)}
        required
      />
      {state === "error" ? (
        <div className="banner bad" role="alert">
          A sign-in link could not be sent. Try again or use your password.
        </div>
      ) : null}
      <Button type="submit" loading={state === "sending"}>Email me a magic link</Button>
    </form>
  );
}
