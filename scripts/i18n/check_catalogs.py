#!/usr/bin/env python3
"""Fail when a translation is missing, inconsistent, stale or unused.

Checks shared/i18n/catalog.json (device and Web strings) against the sources
that use it and the generated tables against the catalog, and the iOS String
Catalogs for complete translations and Chinese literals left in Swift code.

  --ios-stringsdata DIR  also compare the keys Xcode extracted (*.stringsdata
                         of the app target) with Localizable.xcstrings
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_catalog  # noqa: E402

REPO_ROOT = build_catalog.REPO_ROOT
DEVICE_SOURCES = sorted((REPO_ROOT / "shared/nav_ui/src").glob("*.cpp"))
WEB_SHELL = REPO_ROOT / "platforms/web/shell"
WEB_SOURCES = sorted(WEB_SHELL.glob("*.js")) + sorted(WEB_SHELL.glob("*.html"))
PLURAL_SUFFIX = re.compile(r"\.(zero|one|two|few|many|other)$")
IOS_ROOT = REPO_ROOT / "platforms/ios"
IOS_CATALOGS = [IOS_ROOT / "App/Localizable.xcstrings", IOS_ROOT / "App/InfoPlist.xcstrings"]
IOS_LANGUAGES = ["pt-BR", "zh-Hans"]
# Data, not interface text: real road names in fixtures and golden vectors.
IOS_CJK_ALLOWED = {
    IOS_ROOT / "App/Adapters/Navigation/JinanDemoFixture.generated.swift",
    IOS_ROOT / "App/Adapters/BLE/BLEProtocolGoldenCheck.swift",
}
CJK = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
APPLE_FORMAT = re.compile(r"%(?:\d+\$)?((?:ll|l|h)?[a-zA-Z@%])")
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
    # i18n.plural("key", n) reads key.one, key.other... by CLDR category.
    plural_bases = {PLURAL_SUFFIX.sub("", key) for key in defined if PLURAL_SUFFIX.search(key)}
    for key in defined:
        base = PLURAL_SUFFIX.sub("", key)
        if base != key and base in used:
            used.setdefault(key, used[base])
    for base in plural_bases:
        used.pop(base, None)
    errors = [
        f"{used[key].relative_to(REPO_ROOT)} uses unknown key {key}"
        for key in sorted(used.keys() - defined)
    ]
    errors += [f"{key} is never used" for key in sorted(defined - used.keys())]
    return errors


def apple_formats(text: str) -> list[str]:
    return sorted(APPLE_FORMAT.findall(text))


def check_ios_catalogs() -> list[str]:
    errors = []
    for path in IOS_CATALOGS:
        document = json.loads(path.read_text(encoding="utf-8"))
        name = path.relative_to(REPO_ROOT)
        for key, entry in sorted(document["strings"].items()):
            localizations = entry.get("localizations", {})
            source = localizations.get("en", {}).get("stringUnit", {}).get("value", key)
            for language in IOS_LANGUAGES:
                unit = localizations.get(language, {}).get("stringUnit", {})
                if unit.get("state") != "translated" or not unit.get("value"):
                    errors.append(f"{name}: {key!r} is not translated to {language}")
                elif apple_formats(unit["value"]) != apple_formats(source):
                    errors.append(f"{name}: {key!r} {language} parameters differ")
    return errors


def check_swift_sources() -> list[str]:
    errors = []
    for directory in ("App", "Sources"):
        for path in sorted((IOS_ROOT / directory).rglob("*.swift")):
            if path in IOS_CJK_ALLOWED:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if CJK.search(line):
                    errors.append(f"{path.relative_to(REPO_ROOT)}:{number} has Chinese text outside the catalog")
    return errors


def check_web_sources() -> list[str]:
    errors = []
    for path in WEB_SOURCES + [WEB_SHELL / "manifest.webmanifest"]:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if CJK.search(line):
                errors.append(f"{path.relative_to(REPO_ROOT)}:{number} has Chinese text outside the catalog")
    return errors


def check_ios_extraction(directory: Path) -> list[str]:
    extracted = set()
    for path in directory.glob("*.stringsdata"):
        tables = json.loads(path.read_text(encoding="utf-8")).get("tables", {})
        extracted |= {item["key"] for item in tables.get("Localizable", [])}
    if not extracted:
        return [f"no extracted strings in {directory}; build the app first"]
    catalog = set(json.loads(IOS_CATALOGS[0].read_text(encoding="utf-8"))["strings"])
    errors = [f"code uses {key!r}, missing from Localizable.xcstrings" for key in sorted(extracted - catalog)]
    errors += [f"Localizable.xcstrings has {key!r}, no longer used" for key in sorted(catalog - extracted)]
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ios-stringsdata", type=Path)
    arguments = parser.parse_args()
    catalog = build_catalog.load_catalog()
    errors = check_messages(catalog)
    # Generating from an incomplete catalog would fail on the missing entry.
    if not errors:
        errors += check_generated(catalog)
    errors += check_usage(catalog, build_catalog.DEVICE_PREFIX, DEVICE_SOURCES,
                          re.compile(r'"(device\.[a-z0-9_.]+)"'))
    errors += check_usage(catalog, build_catalog.WEB_PREFIX, WEB_SOURCES,
                          re.compile(r'[":](web\.[a-z0-9_.]*[a-z0-9_])\b'))
    errors += check_web_sources()
    errors += check_ios_catalogs()
    errors += check_swift_sources()
    if arguments.ios_stringsdata:
        errors += check_ios_extraction(arguments.ios_stringsdata)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f"{len(errors)} catalog problem(s)", file=sys.stderr)
        return 1
    print("catalogs complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
