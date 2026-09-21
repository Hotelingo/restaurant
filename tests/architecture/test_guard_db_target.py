#!/usr/bin/env python3
"""Executable tests for the production database guard."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts" / "guard_db_target.py"


def run(target: str, ci: bool, acknowledgement: bool = False) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CI"] = "true" if ci else "false"
    env["GITHUB_ACTIONS"] = "false"
    if acknowledgement:
        env["ALLOW_PRODUCTION_DB_CHANGE"] = "YES_I_UNDERSTAND"
    else:
        env.pop("ALLOW_PRODUCTION_DB_CHANGE", None)
    return subprocess.run(
        [sys.executable, str(GUARD), "--target", target, "--operation", "migration"],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    cases = [
        ("CI production is refused", run("production", True).returncode != 0),
        ("CI preview is allowed", run("preview", True).returncode == 0),
        ("CI local is allowed", run("local", True).returncode == 0),
        ("manual production without acknowledgement is refused", run("production", False).returncode != 0),
        ("manual production with explicit acknowledgement is allowed", run("production", False, True).returncode == 0),
    ]
    failed = [label for label, ok in cases if not ok]
    for label, ok in cases:
        print(("PASS" if ok else "FAIL"), label)
    if failed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
