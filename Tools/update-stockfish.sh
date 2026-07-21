#!/usr/bin/env bash
#
# Re-vendor the Stockfish engine source from upstream at a pinned tag.
#
# WHY THIS EXISTS (and why the source is committed rather than fetched):
# SwiftStockfish MUST keep the engine source in-tree. The non-Apple SwiftPM arm
# (Linux/Android — e.g. FianchettoAndroid) compiles
# `Sources/CStockfish/stockfish/*.cpp` DIRECTLY, the Apple bridge resolves the
# engine headers from that directory, and GPL-3.0 §3 requires shipping the
# corresponding source. SwiftPM cannot fetch-and-compile external source at
# build time (build-tool plugins run network-denied; dependency submodules are
# not recursed), so "tag-sourcing" is impossible. This script is the automated
# equivalent of the old manual copy: fetch upstream at the tag, sync the source,
# and re-apply our local patches.
#
# Our local modifications are kept as EXPLICIT patches under Tools/patches/,
# applied in sorted order — each a GPLv3 §5(a)-noticed change. If a future
# upstream tag moves the code a patch touches, `patch` fails LOUDLY here; rebase
# the patch (the SwiftPM analogue of rebasing the SwiftReckless fork) and re-run.
#
# Usage:
#   Tools/update-stockfish.sh [<tag>]
#     no arg   -> re-vendor the tag already in .upstream-version (re-apply patches)
#     <tag>    -> bump to <tag> (e.g. sf_18.1) and update .upstream-version
#
# Idempotent: rsync --delete restores a pristine upstream tree each run before
# the patches re-apply, so repeated runs converge to the same result.
#
# After it succeeds: rebuild the xcframework (Tools/build-xcframework.sh), run
# `swift test`, review the diff, then cut an N.N.N release tag (CI publishes).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

UPSTREAM_REPO="https://github.com/official-stockfish/Stockfish.git"
DEST="Sources/CStockfish/stockfish"
PATCH_DIR="Tools/patches"
VERSION_FILE=".upstream-version"

tag="${1:-}"
if [ -z "$tag" ]; then
  tag="$(tr -d '[:space:]' < "$VERSION_FILE")"
  echo "No tag argument; re-vendoring the pinned tag: $tag"
fi

for tool in git rsync patch; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is required on PATH" >&2; exit 1; }
done

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

echo "==> Cloning Stockfish @ ${tag} (shallow)"
if ! git clone --depth 1 --branch "$tag" "$UPSTREAM_REPO" "$work/sf" 2>"$work/clone.log"; then
  sed 's/^/    /' "$work/clone.log" >&2
  echo "error: could not clone tag '${tag}' — does it exist upstream?" >&2
  exit 1
fi

echo "==> Syncing src/ -> ${DEST} (excluding Makefile, main.cpp)"
# --delete so files removed upstream are removed here; the excludes are protected
# from deletion, and our patched files exist upstream too (overwritten, then
# re-patched below), so nothing we need is lost.
rsync -a --delete \
  --exclude='Makefile' \
  --exclude='main.cpp' \
  "$work/sf/src/" "$DEST/"

echo "==> Applying local patches from ${PATCH_DIR}/"
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  echo "    (none found)"
else
  for p in "${patches[@]}"; do
    echo "    - $(basename "$p")"
    if ! ( cd "$DEST" && patch -p1 -N -s < "$repo_root/$p" ); then
      echo "error: patch '$p' did not apply cleanly against ${tag}." >&2
      echo "       Upstream likely moved the code it touches — rebase the patch and re-run." >&2
      exit 1
    fi
  done
fi

echo "==> Recording pinned version: ${tag}"
printf '%s\n' "$tag" > "$VERSION_FILE"

cat <<DONE

Done — Stockfish source is now at ${tag} with local patches applied.

Next steps:
  1. Review the diff:          git status && git diff --stat
  2. Rebuild the xcframework:  Tools/build-xcframework.sh
  3. Run the tests:            swift test
  4. Commit, then run Actions → Release binary with a new N.N.N version.
DONE
