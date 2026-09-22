#!/usr/bin/env python3
"""Static architecture boundary checks for the Restaurant application.

Standard-library only so the guard runs before app dependencies are installed.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODE_SUFFIXES = {".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}

WEB_FORBIDDEN = (
    "calc_engine",
    "import_engine",
    "review_gate",
    "packages/calc_engine",
    "packages/import_engine",
    "packages/review_gate",
)

PURE_PY_FORBIDDEN_TOPLEVEL = {
    "asyncpg",
    "boto3",
    "django",
    "fastapi",
    "flask",
    "httpx",
    "psycopg",
    "psycopg2",
    "requests",
    "sqlalchemy",
    "supabase",
}

TS_NETWORK_DB_PATTERNS = (
    r"from\s+['\"]@supabase/",
    r"from\s+['\"]axios['\"]",
    r"from\s+['\"]pg['\"]",
    r"from\s+['\"]postgres['\"]",
    r"\bfetch\s*\(",
)


def iter_code(base: Path):
    if not base.exists():
        return
    for path in base.rglob("*"):
        if path.is_file() and path.suffix in CODE_SUFFIXES:
            yield path


def check_web() -> list[str]:
    errors: list[str] = []
    base = ROOT / "apps" / "web"
    for path in iter_code(base) or []:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for token in WEB_FORBIDDEN:
            if token in text:
                errors.append(
                    f"{path.relative_to(ROOT)}: web must not import/reference {token}"
                )
    return errors


def python_import_roots(path: Path) -> set[str]:
    roots: set[str] = set()
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except SyntaxError as exc:
        return {f"__SYNTAX_ERROR__:{exc.lineno}:{exc.msg}"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                roots.add(alias.name.split(".", 1)[0])
        elif isinstance(node, ast.ImportFrom) and node.module:
            roots.add(node.module.split(".", 1)[0])
    return roots


def check_pure_package(name: str) -> list[str]:
    errors: list[str] = []
    base = ROOT / "packages" / name
    for path in iter_code(base) or []:
        if path.suffix == ".py":
            for root in python_import_roots(path):
                if root.startswith("__SYNTAX_ERROR__"):
                    errors.append(f"{path.relative_to(ROOT)}: {root}")
                elif root in PURE_PY_FORBIDDEN_TOPLEVEL:
                    errors.append(
                        f"{path.relative_to(ROOT)}: pure package imports forbidden dependency {root}"
                    )
        else:
            text = path.read_text(encoding="utf-8", errors="ignore")
            for pattern in TS_NETWORK_DB_PATTERNS:
                if re.search(pattern, text):
                    errors.append(
                        f"{path.relative_to(ROOT)}: pure package matches forbidden pattern {pattern}"
                    )
    return errors


def main() -> int:
    errors = []
    errors.extend(check_web())
    errors.extend(check_pure_package("calc_engine"))
    errors.extend(check_pure_package("import_engine"))
    errors.extend(check_pure_package("review_gate"))

    if errors:
        print("Architecture boundary violations:")
        for err in errors:
            print(f" - {err}")
        return 1

    print("Architecture boundary checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
