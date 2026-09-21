#!/usr/bin/env python3
"""Fail closed when CI attempts a production database migration or seed."""

from __future__ import annotations

import argparse
import os
import sys


def truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=("local", "preview", "production"), required=True)
    parser.add_argument("--operation", choices=("migration", "seed"), required=True)
    args = parser.parse_args()

    in_ci = truthy(os.getenv("CI")) or truthy(os.getenv("GITHUB_ACTIONS"))

    if args.target == "production" and in_ci:
        print(
            f"REFUSED: CI may not run {args.operation} against production. "
            "Use the controlled manual release process.",
            file=sys.stderr,
        )
        return 42

    if args.target == "production":
        acknowledgement = os.getenv("ALLOW_PRODUCTION_DB_CHANGE")
        if acknowledgement != "YES_I_UNDERSTAND":
            print(
                "REFUSED: production database change requires "
                "ALLOW_PRODUCTION_DB_CHANGE=YES_I_UNDERSTAND.",
                file=sys.stderr,
            )
            return 43

    print(f"Allowed: {args.operation} target={args.target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
