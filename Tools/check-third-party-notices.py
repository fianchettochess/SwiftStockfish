#!/usr/bin/env python3
"""Check that THIRD_PARTY_NOTICES.md says what this package actually ships.

WHY THIS EXISTS. The notices are what a GPL corresponding-source reader follows.
They named `sf_18` while `.upstream-version` said `sf_19`, so anyone fetching the
source from the notice got the wrong tag; PR #4 fixed that by pointing at
`.upstream-version` instead of repeating the tag. They also listed swift-crypto
and swift-docc-plugin as dependencies after both had left `Package.swift`
(Fianchetto-b32.205). Nothing compared the prose with the files it describes.

WHAT IT CHECKS.
  1. The notices point at `.upstream-version`, and any Stockfish tag they name
     (`sf_<n>`) is the one it records, so a stale tag cannot be written back.
  2. The repositories linked under `## Swift package dependencies` are exactly
     the `.package(url:)` entries in `Package.swift`, in both directions. A
     `.package(` call this cannot read is a failure, not a skip.

Run from anywhere: python3 Tools/check-third-party-notices.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
MANIFEST = ROOT / "Package.swift"
UPSTREAM = ROOT / ".upstream-version"

STOCKFISH_TAG = re.compile(r"\bsf_[0-9][0-9A-Za-z.]*")
DEPENDENCY_SECTION = "## Swift package dependencies"
LINK = re.compile(r"\]\((https?://[^)\s]+)\)")
PACKAGE_CALL = re.compile(r"\.package\s*\(")
PACKAGE_URL = re.compile(r"\.package\s*\(\s*(?:name:\s*\"[^\"]*\"\s*,\s*)?url:\s*\"([^\"]+)\"")


def normalise(url: str) -> str:
    url = url.strip().lower().rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def strip_swift_comments(source: str) -> str:
    # String literals are matched first and kept, so the `//` inside a URL is
    # not mistaken for a comment. Prose in comments names dependencies that
    # left ("swift-crypto is never a dependency") and must not count.
    token = re.compile(r'("(?:\\.|[^"\\\n])*")|/\*.*?\*/|//[^\n]*', re.DOTALL)
    return token.sub(lambda match: match.group(1) or "", source)


def dependency_section(notices: str) -> str | None:
    start = notices.find(DEPENDENCY_SECTION)
    if start < 0:
        return None
    body = notices[start + len(DEPENDENCY_SECTION):]
    following = re.search(r"^## ", body, re.MULTILINE)
    return body[: following.start()] if following else body


def main() -> int:
    problems: list[str] = []
    notices = NOTICES.read_text(encoding="utf-8")

    pinned = UPSTREAM.read_text(encoding="utf-8").strip()
    if f"({UPSTREAM.name})" not in notices:
        problems.append(f"{NOTICES.name} does not point the reader at {UPSTREAM.name}")
    for tag in sorted(set(STOCKFISH_TAG.findall(notices)) - {pinned}):
        problems.append(f"{NOTICES.name} names Stockfish tag {tag!r} but {UPSTREAM.name} pins {pinned!r}")

    manifest = strip_swift_comments(MANIFEST.read_text(encoding="utf-8"))
    calls = len(PACKAGE_CALL.findall(manifest))
    declared = {normalise(url) for url in PACKAGE_URL.findall(manifest)}
    if calls != len(PACKAGE_URL.findall(manifest)):
        problems.append(
            f"{MANIFEST.name} has {calls} .package( call(s) but only "
            f"{len(PACKAGE_URL.findall(manifest))} read as .package(url:); "
            "teach this check the new form rather than letting it pass"
        )

    section = dependency_section(notices)
    if section is None:
        problems.append(f"{NOTICES.name} has no '{DEPENDENCY_SECTION}' section")
        listed: set[str] = set()
    else:
        listed = {normalise(url) for url in LINK.findall(section)}

    for url in sorted(listed - declared):
        problems.append(f"{NOTICES.name} lists {url}, which {MANIFEST.name} does not depend on")
    for url in sorted(declared - listed):
        problems.append(f"{MANIFEST.name} depends on {url}, which {NOTICES.name} does not list")

    if problems:
        print("third-party notices: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(
        f"third-party notices: PASS (upstream tag {pinned}; "
        f"{len(declared)} package dependenc{'y' if len(declared) == 1 else 'ies'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
