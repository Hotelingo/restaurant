#!/usr/bin/env python3
"""Fail closed when CI attempts a production database migration or seed."""

from __future__ import annotations

import argparse
import os
import sys


def truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def evaluate(target: str, operation: str, env: dict[str, str] | None = None) -> tuple[int, str]:
    """Decide whether a database change may run. Returns (exit code, message)."""
    env = os.environ if env is None else env
    in_ci = truthy(env.get("CI")) or truthy(env.get("GITHUB_ACTIONS"))

    if target == "production" and in_ci:
        return 42, (
            f"REFUSED: CI may not run {operation} against production. "
            "Use the controlled manual release process."
        )

    if target == "production" and env.get("ALLOW_PRODUCTION_DB_CHANGE") != "YES_I_UNDERSTAND":
        return 43, (
            "REFUSED: production database change requires "
            "ALLOW_PRODUCTION_DB_CHANGE=YES_I_UNDERSTAND."
        )

    return 0, f"Allowed: {operation} target={target}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=("local", "preview", "production"), required=True)
    parser.add_argument("--operation", choices=("migration", "seed"), required=True)
    args = parser.parse_args()

    code, message = evaluate(args.target, args.operation)
    print(message, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
