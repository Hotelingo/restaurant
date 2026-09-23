-- DEV ONLY. Better Auth 1.6 core + jwt-plugin tables in the neon_auth schema,
-- with uuid ids so the application's FKs to neon_auth."user"(id) resolve
-- exactly as they do on Neon. Apply BEFORE db/migrations. Never run on Neon.
create schema if not exists neon_auth;
create table neon_auth."user" (
  id uuid primary key, name text not null default '', email text not null unique,
  "emailVerified" boolean not null default false, image text,
  "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now());
create table neon_auth.session (
  id uuid primary key, "expiresAt" timestamptz not null, token text not null unique,
  "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now(),
  "ipAddress" text, "userAgent" text,
  "userId" uuid not null references neon_auth."user"(id) on delete cascade);
create table neon_auth.account (
  id uuid primary key, "accountId" text not null, "providerId" text not null,
  "userId" uuid not null references neon_auth."user"(id) on delete cascade,
  "accessToken" text, "refreshToken" text, "idToken" text,
  "accessTokenExpiresAt" timestamptz, "refreshTokenExpiresAt" timestamptz, scope text, password text,
  "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now());
create table neon_auth.verification (
  id uuid primary key, identifier text not null, value text not null, "expiresAt" timestamptz not null,
  "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now());
create table neon_auth.jwks (
  id uuid primary key, "publicKey" text not null, "privateKey" text not null,
  "createdAt" timestamptz not null default now(), "expiresAt" timestamptz);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'restaurant_app') then
    create role restaurant_app login password 'local-dev-only';
  end if;
end $$;
