#!/usr/bin/env python3
"""Guard: no unescaped literal `%` in SQL passed to psycopg.

psycopg treats `%` as the start of a placeholder whenever a query is executed
with parameters, so `like 'pl-%'` raises
    ProgrammingError: only '%s', '%b', '%t' are allowed as placeholders
at runtime. A literal percent must be written `%%`.

Three instances shipped undetected (P&L read model, reconciliation, and the
calc-run results `module` filter) because the API unit tests mock the database
connection and so never reach psycopg's placeholder parser. This static check
catches the whole class without needing a database.

Standard library only, so it runs in the architecture job before dependencies
are installed.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCANNED = ("api/app", "workers")
SQL_HINT = re.compile(r"\b(select|insert|update|delete|where|like|ilike|values|from)\b", re.I)
BARE_PERCENT = re.compile(r"%(?![sbt(])")  # after removing %%; %(name)s is a named placeholder


def offending_literals() -> list[str]:
    problems: list[str] = []
    for base in SCANNED:
        for path in sorted((ROOT / base).rglob("*.py")):
            if "tests" in path.parts:
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            for node in ast.walk(tree):
                if not (isinstance(node, ast.Constant) and isinstance(node.value, str)):
                    continue
                text = node.value
                if "%" not in text or not SQL_HINT.search(text):
                    continue
                if BARE_PERCENT.search(text.replace("%%", "")):
                    snippet = " ".join(text.split())[:80]
                    problems.append(f"{path.relative_to(ROOT)}:{node.lineno}: {snippet!r}")
    return problems


def test_no_unescaped_percent_in_sql() -> None:
    problems = offending_literals()
    assert not problems, (
        "Unescaped literal % in SQL (write %% instead):\n  " + "\n  ".join(problems)
    )


def test_guard_detects_the_original_defect() -> None:
    # Keep the detector honest: it must flag the exact pattern that shipped.
    assert BARE_PERCENT.search("and r.engine_version like 'pl-%'".replace("%%", ""))
    assert not BARE_PERCENT.search("and r.engine_version like 'pl-%%'".replace("%%", ""))
    assert not BARE_PERCENT.search("where id=%s and name=%(name)s".replace("%%", ""))


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except AssertionError as exc:
                failures += 1
                print(f"FAIL {name}\n{exc}")
    sys.exit(1 if failures else 0)
