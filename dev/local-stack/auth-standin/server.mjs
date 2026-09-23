// DEV ONLY -- local stand-in for Neon Managed Better Auth. Never deploy.
//
// Neon Auth is built on Better Auth; this runs the same library version against
// a local database so the web app and API exercise their real auth code paths
// (EdDSA JWTs, JWKS, "__Secure-neon-auth.*" cookies) without Neon cloud access.
import http from "node:http";
import pg from "pg";
import { betterAuth } from "better-auth";
import { jwt } from "better-auth/plugins";
import { toNodeHandler } from "better-auth/node";
import { randomUUID } from "node:crypto";

const PORT = Number(process.env.AUTH_PORT ?? 4000);
const ORIGIN = `http://localhost:${PORT}`;

const pool = new pg.Pool({
  connectionString: process.env.AUTH_DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:5432/rpr_dev",
  options: "-c search_path=neon_auth",
});

export const auth = betterAuth({
  baseURL: ORIGIN,
  basePath: "/neondb/auth",
  secret: "local-dev-only-better-auth-secret-000000000000",
  database: pool,
  trustedOrigins: ["http://localhost:3000"],
  emailAndPassword: { enabled: true, requireEmailVerification: false, minPasswordLength: 12 },
  // Match Neon Managed Auth: cookies are "__Secure-neon-auth.*".
  advanced: { cookiePrefix: "neon-auth", useSecureCookies: true, database: { generateId: () => randomUUID() } },
  plugins: [
    jwt({
      jwks: { keyPairConfig: { alg: "EdDSA", crv: "Ed25519" } },
      jwt: { issuer: ORIGIN, audience: ORIGIN, expirationTime: "15m",
             definePayload: ({ user }) => ({ email: user.email, name: user.name }) },
    }),
  ],
});

const handler = toNodeHandler(auth);
http.createServer((req, res) => {
  // Neon publishes JWKS at /.well-known/jwks.json; Better Auth serves /jwks.
  if (req.url?.endsWith("/.well-known/jwks.json")) req.url = "/neondb/auth/jwks";
  handler(req, res);
}).listen(PORT, () => console.log(`local neon-auth stand-in on ${ORIGIN}/neondb/auth`));
