#!/usr/bin/env python3
"""Apply db/migrations to a database exactly once, recorded in a ledger.

    python scripts/migrate.py --target preview status
    python scripts/migrate.py --target preview up
    python scripts/migrate.py --target preview baseline --through 0040_pack_server_role.sql

The connection string comes from MIGRATION_DATABASE_URL (or --database-url). It
must be the schema owner, never restaurant_app. --target is required and goes
through scripts/guard_db_target.py, so CI can never migrate production and a
manual production run needs ALLOW_PRODUCTION_DB_CHANGE=YES_I_UNDERSTAND.

Rules, all fail-closed:
- Each pending file runs in one transaction together with its ledger row.
- An applied file whose bytes changed (SHA-256) stops the run: applied history
  is immutable, so fix forward with a new migration.
- An applied file missing from disk, a duplicate version, or a pending file that
  sorts before already-applied history stops the run.
- A session advisory lock serialises concurrent runs (e.g. two deploys).
- `baseline` adopts a database migrated before the ledger existed: it records
  files up to --through as applied without running them. It only runs on an
  empty ledger, and only when the schema visibly exists.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parent))
from guard_db_target import evaluate as guard_evaluate  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIR = ROOT / "db" / "migrations"
FILE_PATTERN = re.compile(r"^(?P<version>\d{4}[a-z]?)_[a-z0-9_]+\.sql$")
LOCK_KEY = 7_223_014_551  # arbitrary, stable: "restaurant migrations"

LEDGER_DDL = """
create schema if not exists ops;
revoke all on schema ops from public;
create table if not exists ops.schema_migrations (
  version text primary key,
  filename text not null unique,
  checksum_sha256 text not null check (checksum_sha256 ~ '^[0-9a-f]{64}$'),
  applied_at timestamptz not null default now(),
  applied_by text not null default current_user,
  execution_ms integer,
  baselined boolean not null default false
);
revoke all on ops.schema_migrations from public;
"""


class MigrationError(Exception):
    """A condition that must stop the run."""


@dataclass(frozen=True)
class Migration:
    version: str
    filename: str
    path: Path
    checksum: str

    @property
    def sql(self) -> str:
        return self.path.read_text(encoding="utf-8")


def discover(directory: Path) -> list[Migration]:
    migrations: list[Migration] = []
    seen: dict[str, str] = {}
    for path in sorted(directory.glob("*.sql")):
        match = FILE_PATTERN.match(path.name)
        if not match:
            raise MigrationError(f"{path.name}: not a migration name (expected NNNN[_a-z]_name.sql)")
        version = match.group("version")
        if version in seen:
            raise MigrationError(f"duplicate migration version {version}: {seen[version]} and {path.name}")
        seen[version] = path.name
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        migrations.append(Migration(version, path.name, path, checksum))
    return migrations


def applied_rows(conn: psycopg.Connection) -> dict[str, tuple[str, str]]:
    if conn.execute("select to_regclass('ops.schema_migrations') is null").fetchone()[0]:
        return {}
    rows = conn.execute("select version, filename, checksum_sha256 from ops.schema_migrations").fetchall()
    return {version: (filename, checksum) for version, filename, checksum in rows}


def plan(migrations: list[Migration], applied: dict[str, tuple[str, str]]) -> list[Migration]:
    """Verify applied history against disk and return the pending migrations in order."""
    by_version = {m.version: m for m in migrations}
    for version, (filename, checksum) in sorted(applied.items()):
        on_disk = by_version.get(version)
        if on_disk is None:
            raise MigrationError(f"{filename} is recorded as applied but is missing from disk")
        if on_disk.filename != filename:
            raise MigrationError(f"version {version} was applied as {filename} but is now {on_disk.filename}")
        if on_disk.checksum != checksum:
            raise MigrationError(
                f"{filename} changed after it was applied (checksum drift). "
                "Applied migrations are immutable: revert the edit and add a new migration."
            )
    pending = [m for m in migrations if m.version not in applied]
    if applied and pending:
        last_applied = max(applied)
        early = [m.filename for m in pending if m.version < last_applied]
        if early:
            raise MigrationError(
                f"{', '.join(early)} sort(s) before already-applied history (last applied {last_applied}). "
                "Renumber the new migration after the latest one."
            )
    return pending


def connect(url: str) -> psycopg.Connection:
    conn = psycopg.connect(url, autocommit=True)
    conn.add_notice_handler(lambda notice: print(f"    notice: {notice.message_primary}"))
    return conn


def cmd_status(conn: psycopg.Connection, migrations: list[Migration]) -> int:
    applied = applied_rows(conn)
    pending = plan(migrations, applied)
    print(f"applied: {len(applied)}   pending: {len(pending)}")
    for m in pending:
        print(f"  pending  {m.filename}")
    return 0


def cmd_up(conn: psycopg.Connection, migrations: list[Migration]) -> int:
    pending = plan(migrations, applied_rows(conn))
    if not pending:
        print("up to date: nothing to apply")
        return 0
    for m in pending:
        started = time.monotonic()
        print(f"  applying {m.filename}")
        try:
            with conn.transaction():
                conn.execute(m.sql)
                conn.execute(
                    "insert into ops.schema_migrations(version, filename, checksum_sha256, execution_ms) "
                    "values (%s, %s, %s, %s)",
                    (m.version, m.filename, m.checksum, int((time.monotonic() - started) * 1000)),
                )
        except psycopg.Error as exc:
            raise MigrationError(f"{m.filename} failed and was rolled back: {exc}") from exc
    print(f"applied {len(pending)} migration(s)")
    return 0


def cmd_baseline(conn: psycopg.Connection, migrations: list[Migration], through: str) -> int:
    if applied_rows(conn):
        raise MigrationError("baseline is only for an empty ledger; this database already has one")
    names = [m.filename for m in migrations]
    if through not in names:
        raise MigrationError(f"--through {through} is not a migration file")
    schema_present = conn.execute("select to_regclass('public.organisation') is not null").fetchone()[0]
    if not schema_present:
        raise MigrationError("refusing to baseline: the schema does not exist here. Use `up` on a new database.")
    adopted = migrations[: names.index(through) + 1]
    with conn.transaction():
        for m in adopted:
            conn.execute(
                "insert into ops.schema_migrations(version, filename, checksum_sha256, baselined) values (%s, %s, %s, true)",
                (m.version, m.filename, m.checksum),
            )
    print(f"baselined {len(adopted)} migration(s) through {through} without running them")
    print("run `up` next to apply anything newer")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", choices=("local", "preview", "production"), required=True)
    parser.add_argument("--database-url", default=os.getenv("MIGRATION_DATABASE_URL"))
    parser.add_argument("--dir", type=Path, default=DEFAULT_DIR)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("up")
    base = sub.add_parser("baseline")
    base.add_argument("--through", required=True, help="last migration file already applied to this database")
    args = parser.parse_args(argv)

    if not args.database_url:
        print("MIGRATION_DATABASE_URL (or --database-url) is required", file=sys.stderr)
        return 2

    if args.command != "status":
        code, message = guard_evaluate(args.target, "migration")
        print(message, file=sys.stderr if code else sys.stdout)
        if code:
            return code

    try:
        migrations = discover(args.dir)
        with connect(args.database_url) as conn:
            conn.execute("select pg_advisory_lock(%s)", (LOCK_KEY,))
            try:
                if args.command != "status":  # status never writes, not even the ledger table
                    conn.execute(LEDGER_DDL)
                if args.command == "status":
                    return cmd_status(conn, migrations)
                if args.command == "up":
                    return cmd_up(conn, migrations)
                return cmd_baseline(conn, migrations, args.through)
            finally:
                conn.execute("select pg_advisory_unlock(%s)", (LOCK_KEY,))
    except MigrationError as exc:
        print(f"STOPPED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
