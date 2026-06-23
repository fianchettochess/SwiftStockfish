#!/usr/bin/env python3
"""Rewrite Package.swift's ACTIVE binaryTarget to `url:`+`checksum:`.

Used by .github/workflows/release.yml at release time. The committed Package.swift
keeps a PATH-based binaryTarget (so a plain `swift build` works); this script flips
it to a URL+checksum binaryTarget inside the CI run, once the release asset's URL
and checksum are known.

The rewrite is IDEMPOTENT across forms: it accepts an active binaryTarget that is
currently `path:`-based OR already `url:`+`checksum:`-based, and always emits the
url+checksum form. (A second release that runs against an already-url-based manifest
must still succeed — see release.yml.)

Robustness: Package.swift contains BOTH
  * a commented-out `url:`+`checksum:` example (every line prefixed with `//`), and
  * the real, active `.binaryTarget(... name: "StockfishEngine" ...)`.
We must only touch the active one. The matcher therefore:
  1. scans for `.binaryTarget(` openers whose line is NOT a `//` comment,
  2. brace-matches to the closing `)` of that call,
  3. requires the block to contain a non-comment line with
     `name: "StockfishEngine"` (true for both path- and url-based forms),
and replaces exactly that block, preserving its indentation AND whatever trailed
the closing `)` (e.g. the `,` that separates it from the next array element). The
commented example is skipped at step 1 (its lines start with `//`), so it is never
matched.

Usage: rewrite_binary_target.py <url> <checksum> [path-to-Package.swift]
Exits non-zero if it does not find exactly one active binaryTarget, or if the url
contains a character that would break out of the Swift string literal.
"""
import re
import sys

ENGINE_NAME = "StockfishEngine"


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("//")


def find_active_binary_target(lines):
    """Return (start_idx, end_idx_exclusive, indent) of the active
    `.binaryTarget(...)` block, or raise if not exactly one is found.

    "Active" = a non-comment `.binaryTarget(` call whose body names the
    StockfishEngine binary. This matches BOTH the path-based form (on `main`)
    and the already-url-based form (after a prior release), so the rewrite is
    idempotent. The commented-out example is excluded because all its lines
    start with `//`.
    """
    matches = []
    for i, line in enumerate(lines):
        if is_comment(line):
            continue
        if ".binaryTarget(" not in line:
            continue
        # Brace-match parentheses from the opener to the matching close,
        # ignoring any commented lines inside the block.
        depth = 0
        end = None
        started = False
        for j in range(i, len(lines)):
            cur = lines[j]
            if is_comment(cur):
                continue
            depth += cur.count("(") - cur.count(")")
            if cur.count("(") > 0:
                started = True
            if started and depth <= 0:
                end = j + 1
                break
        if end is None:
            continue
        block = lines[i:end]
        # The active StockfishEngine binaryTarget — path- OR url-based.
        names_engine = any(
            (not is_comment(b)) and f'name: "{ENGINE_NAME}"' in b for b in block
        )
        if names_engine:
            indent = re.match(r"\s*", line).group(0)
            matches.append((i, end, indent))

    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly 1 active binaryTarget naming {ENGINE_NAME}, "
            f"found {len(matches)}"
        )
    return matches[0]


def closing_suffix(last_block_line: str) -> str:
    """Everything after the final `)` on the block's last line.

    The active binaryTarget is an element of the `targets:` array, so its last
    line is `        ),` — the `)` PLUS the array-element comma (and possibly a
    trailing newline). We must carry that suffix into the replacement, otherwise
    the rewritten `.binaryTarget(...)` is no longer comma-separated from the next
    `.target(...)` and the manifest fails to parse. Returns e.g. `",\n"`.
    """
    paren = last_block_line.rfind(")")
    if paren == -1:
        # Should not happen (the brace-matcher guarantees a closing `)`), but
        # fall back to a bare newline to avoid emitting garbage.
        return "\n" if last_block_line.endswith("\n") else ""
    return last_block_line[paren + 1:]


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: rewrite_binary_target.py <url> <checksum> [Package.swift]")
    url = sys.argv[1]
    checksum = sys.argv[2]
    path = sys.argv[3] if len(sys.argv) > 3 else "Package.swift"

    # Defense-in-depth against manifest corruption: the url and checksum are
    # interpolated into Swift string literals. A `"` (or backslash/newline) would
    # break out of the literal and produce an invalid Package.swift. The workflow
    # also validates `version` up front, but reject here too so the script is
    # safe to run standalone.
    for label, value in (("url", url), ("checksum", checksum)):
        if '"' in value or "\\" in value or "\n" in value or "\r" in value:
            raise SystemExit(
                f'refusing to rewrite: {label} contains a quote, backslash or '
                f'newline that would break the Swift string literal: {value!r}'
            )

    with open(path, "r") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)

    start, end, indent = find_active_binary_target(lines)

    # Carry over whatever followed the original closing `)` (the array-element
    # comma + newline), so the rewritten element stays comma-separated.
    suffix = closing_suffix(lines[end - 1])

    replacement = (
        f"{indent}.binaryTarget(\n"
        f'{indent}    name: "{ENGINE_NAME}",\n'
        f'{indent}    url: "{url}",\n'
        f'{indent}    checksum: "{checksum}"\n'
        f"{indent}){suffix}"
    )

    new_lines = lines[:start] + [replacement] + lines[end:]
    with open(path, "w") as f:
        f.write("".join(new_lines))

    print(f"Rewrote active binaryTarget in {path}:")
    print(f"  url      = {url}")
    print(f"  checksum = {checksum}")


if __name__ == "__main__":
    main()
