import Link from "next/link";
import { AuthView } from "@neondatabase/auth-ui";

export default function ResetPasswordPage() {
  return (
    <main className="shell">
      <div className="panel auth-panel">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <div><b>Restaurant Performance Review</b><span>Secure account recovery</span></div>
        </div>
        <div className="page-head">
          <h1>Choose a new password</h1>
          <p>Password-reset links are short-lived. Use at least 12 characters for the new password.</p>
        </div>
        <div className="managed-auth">
          <AuthView path="reset-password" />
        </div>
        <div className="row sb mt8">
          <Link href="/auth/reset">Request another link</Link>
          <span className="muted">AUTH04</span>
        </div>
      </div>
    </main>
  );
}
