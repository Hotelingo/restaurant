#!/usr/bin/env python3
"""Apply db/migrations safely to a persistent PostgreSQL/Neon database.

Each migration is recorded by its full filename and SHA-256 checksum. Applied
files are never replayed, and changing an already-applied file fails closed.

Use a privileged direct/unpooled migration credential in MIGRATION_DATABASE_URL.
Never point this script at the restaurant_app runtime credential.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import sys

import psycopg


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS_DIR = ROOT / "db" / "migrations"


def truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def guard_target(target: str) -> None:
    in_ci = truthy(os.getenv("CI")) or truthy(os.getenv("GITHUB_ACTIONS"))
    if target == "production" and in_ci:
        raise SystemExit("REFUSED: CI may not migrate production.")
    if target == "production" and os.getenv("ALLOW_PRODUCTION_DB_CHANGE") != "YES_I_UNDERSTAND":
        raise SystemExit(
            "REFUSED: production migration requires "
            "ALLOW_PRODUCTION_DB_CHANGE=YES_I_UNDERSTAND."
        )


def migration_files() -> list[Path]:
    return sorted(
        path
        for path in MIGRATIONS_DIR.glob("0*.sql")
        if path.is_file()
    )


def checksum(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ensure_ledger(conn: psycopg.Connection) -> None:
    with conn.transaction():
        conn.execute(
            """
            create table if not exists public.schema_migrations (
              filename text primary key,
              sha256 char(64) not null,
              applied_at timestamptz not null default now()
            )
            """
        )


def read_applied(conn: psycopg.Connection) -> dict[str, str]:
    rows = conn.execute(
        "select filename, sha256 from public.schema_migrations order by filename"
    ).fetchall()
    return {row[0]: row[1] for row in rows}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=("local", "preview", "production"), required=True)
    parser.add_argument(
        "--database-url",
        default=os.getenv("MIGRATION_DATABASE_URL"),
        help="Privileged direct/unpooled PostgreSQL URL. Defaults to MIGRATION_DATABASE_URL.",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Show applied/pending migrations without applying anything.",
    )
    args = parser.parse_args()

    guard_target(args.target)
    if not args.database_url:
        print(
            "MIGRATION_DATABASE_URL (or --database-url) is required. "
            "Do not use the restaurant_app runtime URL.",
            file=sys.stderr,
        )
        return 2

    files = migration_files()
    if not files:
        print("No migrations found.", file=sys.stderr)
        return 3

    with psycopg.connect(args.database_url) as conn:
        ensure_ledger(conn)
        applied = read_applied(conn)

        for path in files:
            digest = checksum(path)
            prior = applied.get(path.name)
            if prior is not None and prior != digest:
                print(
                    f"REFUSED: applied migration changed: {path.name}\n"
                    f"database={prior}\nrepo={digest}",
                    file=sys.stderr,
                )
                return 4

        pending = [path for path in files if path.name not in applied]

        if args.status:
            print(f"Applied: {len(applied)}")
            print(f"Pending: {len(pending)}")
            for path in pending:
                print(f"  {path.name}")
            return 0

        for path in pending:
            digest = checksum(path)
            print(f"Applying {path.name}")
            sql = path.read_text(encoding="utf-8")
            with conn.transaction():
                conn.execute(sql)
                conn.execute(
                    """
                    insert into public.schema_migrations(filename, sha256)
                    values (%s, %s)
                    """,
                    (path.name, digest),
                )

        print(f"Migration complete. Applied {len(pending)} new migration(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
