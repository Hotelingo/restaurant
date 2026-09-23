#!/usr/bin/env python3
"""Integration tests for scripts/migrate.py against a real PostgreSQL server.

Each case runs in a throwaway database created and dropped here. The server
comes from PG* environment variables (as in CI); PGUSER must be able to
CREATE DATABASE. restaurant_app must already exist (it is cluster-wide).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "migrate.py"
MIGRATIONS = ROOT / "db" / "migrations"
FILES = sorted(p.name for p in MIGRATIONS.glob("*.sql"))

HOST = os.getenv("PGHOST", "localhost")
PORT = os.getenv("PGPORT", "5432")
USER = os.getenv("PGUSER", "postgres")
PASSWORD = os.getenv("PGPASSWORD", "postgres")

NEON_AUTH_STUB = """
create schema neon_auth;
create table neon_auth."user" (
  id uuid primary key, name text not null default '', email text not null default '',
  "emailVerified" boolean not null default false
);
"""


def url(db: str) -> str:
    return f"postgresql://{USER}:{PASSWORD}@{HOST}:{PORT}/{db}"


class Database:
    def __init__(self) -> None:
        self.name = f"migtest_{uuid.uuid4().hex[:10]}"

    def __enter__(self) -> "Database":
        with psycopg.connect(url("postgres"), autocommit=True) as conn:
            conn.execute(f'create database "{self.name}"')
        with psycopg.connect(self.url, autocommit=True) as conn:
            conn.execute(NEON_AUTH_STUB)
        return self

    def __exit__(self, *exc: object) -> None:
        with psycopg.connect(url("postgres"), autocommit=True) as conn:
            conn.execute(f'drop database if exists "{self.name}" with (force)')

    @property
    def url(self) -> str:
        return url(self.name)

    def scalar(self, sql: str):
        with psycopg.connect(self.url, autocommit=True) as conn:
            return conn.execute(sql).fetchone()[0]


def run(db: Database, *args: str, directory: Path = MIGRATIONS, env_extra: dict[str, str] | None = None):
    env = {**os.environ, "CI": "false", "GITHUB_ACTIONS": "false", "MIGRATION_DATABASE_URL": db.url}
    env.update(env_extra or {})
    target = args[0]
    return subprocess.run(
        [sys.executable, str(RUNNER), "--target", target, "--dir", str(directory), *args[1:]],
        env=env, text=True, capture_output=True, check=False,
    )


def copy_migrations() -> Path:
    directory = Path(tempfile.mkdtemp(prefix="migrations_"))
    for name in FILES:
        shutil.copy(MIGRATIONS / name, directory / name)
    return directory


results: list[tuple[str, bool, str]] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    results.append((label, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'} {label}" + (f"\n     {detail}" if not ok and detail else ""), flush=True)


def main() -> int:
    total = len(FILES)

    with Database() as db:
        r = run(db, "local", "status")
        check("status on a new database writes nothing", r.returncode == 0 and f"pending: {total}" in r.stdout
              and db.scalar("select to_regclass('ops.schema_migrations') is null"), r.stdout + r.stderr)
        r = run(db, "local", "up")
        check(f"up applies all {total} migrations", r.returncode == 0
              and db.scalar("select count(*) from ops.schema_migrations") == total, r.stdout[-400:] + r.stderr)
        r = run(db, "local", "up")
        check("second up is a no-op", r.returncode == 0 and "up to date" in r.stdout, r.stdout + r.stderr)
        check("ledger is invisible to restaurant_app",
              not db.scalar("select has_table_privilege('restaurant_app', 'ops.schema_migrations', 'select')")
              and not db.scalar("select has_schema_privilege('restaurant_app', 'ops', 'usage')"))

        drifted = copy_migrations()
        (drifted / FILES[3]).write_text((drifted / FILES[3]).read_text() + "\n-- edited after apply\n")
        r = run(db, "local", "up", directory=drifted)
        check("an edited applied migration stops the run", r.returncode == 1 and "checksum drift" in r.stderr, r.stderr)

        missing = copy_migrations()
        (missing / FILES[5]).unlink()
        r = run(db, "local", "up", directory=missing)
        check("a missing applied migration stops the run", r.returncode == 1 and "missing from disk" in r.stderr, r.stderr)

        early = copy_migrations()
        (early / "0005z_late_arrival.sql").write_text("select 1;\n")
        r = run(db, "local", "up", directory=early)
        check("a new file sorting before applied history is refused",
              r.returncode == 1 and "before already-applied history" in r.stderr, r.stderr)

        dup = copy_migrations()
        (dup / "0040_duplicate_number.sql").write_text("select 1;\n")
        r = run(db, "local", "up", directory=dup)
        check("a duplicate version number is refused", r.returncode == 1 and "duplicate migration version" in r.stderr, r.stderr)

        failing = copy_migrations()
        (failing / "9998_partial.sql").write_text("create table public.partial_should_vanish(id int);\nselect 1/0;\n")
        r = run(db, "local", "up", directory=failing)
        check("a failing migration is rolled back with its ledger row",
              r.returncode == 1 and "rolled back" in r.stderr
              and db.scalar("select to_regclass('public.partial_should_vanish') is null")
              and db.scalar("select count(*) from ops.schema_migrations where version='9998'") == 0, r.stderr)

        r = run(db, "production", "up", env_extra={"CI": "true"})
        check("CI cannot migrate production", r.returncode == 42 and "REFUSED" in r.stderr, r.stderr)

    with Database() as db:
        with psycopg.connect(db.url, autocommit=True) as conn:
            for name in FILES:  # the pre-ledger way: every file, no record
                conn.execute((MIGRATIONS / name).read_text())
        r = run(db, "local", "baseline", "--through", FILES[-1])
        check("baseline adopts a database migrated without a ledger",
              r.returncode == 0 and db.scalar("select count(*) from ops.schema_migrations where baselined") == total,
              r.stdout + r.stderr)
        r = run(db, "local", "up")
        check("up after baseline has nothing to apply", r.returncode == 0 and "up to date" in r.stdout, r.stdout + r.stderr)
        r = run(db, "local", "baseline", "--through", FILES[-1])
        check("baseline refuses a non-empty ledger", r.returncode == 1 and "empty ledger" in r.stderr, r.stderr)

    with Database() as db:
        r = run(db, "local", "baseline", "--through", FILES[-1])
        check("baseline refuses a database without the schema",
              r.returncode == 1 and "does not exist here" in r.stderr, r.stderr)

    failed = [label for label, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
