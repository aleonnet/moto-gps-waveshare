#!/usr/bin/env python3
"""Fail when a translation is missing, inconsistent, stale or unused.

Checks shared/i18n/catalog.json (device and Web strings) against the sources
that use it, and the generated tables against the catalog.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_catalog  # noqa: E402

REPO_ROOT = build_catalog.REPO_ROOT
DEVICE_SOURCES = sorted((REPO_ROOT / "shared/nav_ui/src").glob("*.cpp"))
# "{name}" parameters and printf conversions must match across languages.
PLACEHOLDER = re.compile(r"\{[a-z_]+\}|%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[a-zA-Z@]")


def placeholders(text: str) -> list[str]:
    return sorted(PLACEHOLDER.findall(text))


def check_messages(catalog: dict) -> list[str]:
    errors = []
    languages = catalog["languages"]
    for key, message in sorted(catalog["messages"].items()):
        if not message.get("comment"):
            errors.append(f"{key}: missing translator comment")
        for language in languages:
            if not message.get(language):
                errors.append(f"{key}: missing {language}")
        reference = placeholders(message.get(languages[0], ""))
        for language in languages[1:]:
            if placeholders(message.get(language, "")) != reference:
                errors.append(
                    f"{key}: {language} parameters differ from {languages[0]}")
    return errors


def check_generated(catalog: dict) -> list[str]:
    return [
        f"{path.relative_to(REPO_ROOT)} is stale; run scripts/i18n/build_catalog.py"
        for path in build_catalog.stale_outputs(catalog)
    ]


def check_usage(catalog: dict, prefix: str, sources: list[Path],
                pattern: re.Pattern) -> list[str]:
    used: dict[str, Path] = {}
    for source in sources:
        for key in pattern.findall(source.read_text(encoding="utf-8")):
            used.setdefault(key, source)
    defined = {key for key in catalog["messages"] if key.startswith(prefix)}
    errors = [
        f"{used[key].relative_to(REPO_ROOT)} uses unknown key {key}"
        for key in sorted(used.keys() - defined)
    ]
    errors += [f"{key} is never used" for key in sorted(defined - used.keys())]
    return errors


def main() -> int:
    catalog = build_catalog.load_catalog()
    errors = check_messages(catalog)
    # Generating from an incomplete catalog would fail on the missing entry.
    if not errors:
        errors += check_generated(catalog)
    errors += check_usage(catalog, build_catalog.DEVICE_PREFIX, DEVICE_SOURCES,
                          re.compile(r'"(device\.[a-z0-9_.]+)"'))
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f"{len(errors)} catalog problem(s)", file=sys.stderr)
        return 1
    print("catalogs complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
