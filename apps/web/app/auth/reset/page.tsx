import Link from "next/link";
import { AuthView } from "@neondatabase/auth-ui";

export default function ResetPage() {
  return (
    <main className="shell">
      <div className="panel auth-panel">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <div><b>Restaurant Performance Review</b><span>Secure account recovery</span></div>
        </div>
        <div className="page-head">
          <h1>Reset password</h1>
          <p>Request a short-lived password-reset link from the managed authentication service.</p>
        </div>
        <div className="managed-auth">
          <AuthView path="forgot-password" />
        </div>
        <div className="row sb mt8">
          <Link href="/auth/sign-in">Back to sign in</Link>
          <span className="muted">AUTH04</span>
        </div>
      </div>
    </main>
  );
}
