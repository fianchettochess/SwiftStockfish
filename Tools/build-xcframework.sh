#!/bin/bash
#
# build-xcframework.sh — compile the package's bundled Stockfish source into
# Frameworks/Stockfish.xcframework (a static-library xcframework) that the
# `StockfishEngine` binaryTarget links, instead of recompiling Stockfish on
# every clean build.
#
# This is the SELF-CONTAINED, package-local build script: it reads the engine
# source straight out of this package (Sources/CStockfish/stockfish + the
# Sources/CStockfish/StockfishConfig.h prefix header) and writes the result to
# Frameworks/Stockfish.xcframework — no dependency on the host app's tree.
#
# REQUESTED DEPLOYMENT FLOOR: the slices are compiled at iOS 13.0 / macOS 10.15
# (Catalina) / tvOS 13.0 / watchOS 6.0 / visionOS 1.0 / Mac Catalyst 13.2 —
# matching Package.swift's platforms, which are pinned there by Swift-concurrency
# back-deployment. The engine imposes no OS floor of its own, so these are simply
# set to the package's minimum. Bump IOS_MIN / MAC_MIN / TVOS_MIN / WATCHOS_MIN /
# VISIONOS_MIN here in lockstep if Package.swift's platforms ever change.
# Architecture availability raises a few effective watch floors: arm64_32 device
# objects retain watchOS 6.0, arm64 device objects start at watchOS 26.0, and the
# arm64 simulator objects start at watchOS 7.0. The fat slices preserve those
# per-architecture Mach-O minimums. No legacy armv7k slice is produced.
#
# LICENSING: Stockfish is licensed GPL-3. This script — together with the
# Stockfish source it references (Sources/CStockfish/stockfish) and the
# StockfishConfig.h prefix header — is the separately-distributable GPL
# component: it builds a standalone binary that the (otherwise separate)
# wrapper merely links. Releasing this source + script independently keeps the
# GPL boundary clean.
#
# Slices built: iphoneos (arm64), iphonesimulator (arm64,x86_64),
#               macosx (arm64,x86_64), appletvos (arm64),
#               appletvsimulator (arm64,x86_64), watchos (arm64_32,arm64),
#               watchsimulator (arm64,x86_64),
#               xros/visionOS (arm64), xrsimulator (arm64,x86_64), and Mac
#               Catalyst (arm64,x86_64 via the -macabi triple; no sim slice).
#
# Flags mirror the original in-target build exactly:
#   -std=gnu++20 -O3, the StockfishConfig.h PREFIX header (which sets
#   NNUE_EMBEDDING_OFF + the per-arch SIMD defines), -DNDEBUG. The NNUE
#   network is NOT embedded (loaded from the .nnue resource at runtime), so the
#   binary stays small.
#
# Run after bumping the Stockfish version (or the package's min OS); commit the
# regenerated Stockfish.xcframework. Day-to-day builds never recompile
# Stockfish.
#
set -euo pipefail

# A developer may have `xcode-select` pointed at CommandLineTools even though
# full Xcode is installed. Use the conventional app bundle without changing
# their global selection; release CI sets DEVELOPER_DIR explicitly.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "error: full Xcode is required (set DEVELOPER_DIR to its Developer directory)" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
SRC="$PKG/Sources/CStockfish/stockfish"
# Directory holding StockfishConfig.h. It is force-included below via `-include`,
# but the engine's types.h ALSO does a plain `#include "StockfishConfig.h"` (so
# the publishable, flag-free SwiftPM source arm gets the same config). That
# source include resolves against this -I path on the Apple build; without it
# the new include would be "file not found". (The force-include + this source
# include are idempotent — StockfishConfig.h has its own header guard.)
CONFIG_DIR="$PKG/Sources/CStockfish"
PREFIX="$CONFIG_DIR/StockfishConfig.h"
OUT="$HERE/build"
# Place Stockfish.xcframework in the package's Frameworks/ by default (the
# binaryTarget path); an arg overrides the containing directory.
XCF_DIR="${1:-$PKG/Frameworks}"

IOS_MIN=13.0
MAC_MIN=10.15
TVOS_MIN=13.0
WATCHOS_MIN=6.0
VISIONOS_MIN=1.0
# Mac Catalyst uses the iOS-13.2 `-macabi` target triple (the earliest Catalyst).

echo "Stockfish source : $SRC"
echo "Output framework : $XCF_DIR/Stockfish.xcframework"
echo "Minimums         : iOS $IOS_MIN / macOS $MAC_MIN / tvOS $TVOS_MIN / watchOS $WATCHOS_MIN / visionOS $VISIONOS_MIN"
rm -rf "$OUT"; mkdir -p "$OUT"
mkdir -p "$XCF_DIR"

# Translation units (relative paths under stockfish/; none contain spaces).
CPP=()
while IFS= read -r f; do CPP+=("$f"); done < <(cd "$SRC" && find . -name "*.cpp" | sort)
echo "Translation units: ${#CPP[@]}"

# build_arch <sdk> <arch> <min-flag>  ->  prints the produced static-lib path
build_arch() {
  local sdk="$1" arch="$2" minflag="$3"
  local sdkpath; sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  # Preserve the optimized Intel engine: AVX2 + BMI2 enable Stockfish's
  # compile-time AVX2/PEXT path. This single binary does not runtime-dispatch,
  # so its documented CPU floor is Haswell-class hardware or newer.
  local extra=""
  [ "$arch" = "x86_64" ] && extra="-mavx2 -mbmi2 -DSF_ENABLE_AVX2"
  local objdir="$OUT/obj/$sdk-$arch"; mkdir -p "$objdir"
  for f in "${CPP[@]}"; do
    local o
    o="$objdir/$(printf '%s' "$f" | tr './' '__').o"
    # `extra` intentionally expands to three separate compiler arguments on
    # x86_64 and to no arguments on the other architectures.
    # shellcheck disable=SC2086
    xcrun --sdk "$sdk" clang++ -c "$SRC/$f" -o "$o" \
      -std=gnu++20 -O3 -DNDEBUG \
      -include "$PREFIX" -I "$SRC" -I "$CONFIG_DIR" \
      -ffile-prefix-map="$PKG=/src/SwiftStockfish" \
      -fdebug-prefix-map="$PKG=/src/SwiftStockfish" \
      -arch "$arch" -isysroot "$sdkpath" "$minflag" $extra
  done
  local lib="$OUT/libStockfish-$sdk-$arch.a"
  rm -f "$lib"
  xcrun --sdk "$sdk" libtool -static -o "$lib" "$objdir"/*.o >/dev/null 2>&1
  printf '%s' "$lib"
}

# build_macabi <arch>  ->  prints the produced Mac Catalyst static-lib path.
# Catalyst compiles against the macOS SDK but with the iOS-13.2 `-macabi`
# target TRIPLE (which stamps the maccatalyst platform into the Mach-O, so the
# xcframework keeps it distinct from the native macOS slice). The triple names
# the arch itself, so we pass `--target=<triple>` (single-token form — the
# space-separated `-target <triple>` form would be word-split by the per-arch
# call) and DROP the separate `-arch` flag build_arch uses.
build_macabi() {
  local arch="$1"
  local sdkpath; sdkpath="$(xcrun --sdk macosx --show-sdk-path)"
  local extra=""
  [ "$arch" = "x86_64" ] && extra="-mavx2 -mbmi2 -DSF_ENABLE_AVX2"
  local objdir="$OUT/obj/maccatalyst-$arch"; mkdir -p "$objdir"
  for f in "${CPP[@]}"; do
    local o
    o="$objdir/$(printf '%s' "$f" | tr './' '__').o"
    # `extra` intentionally expands to three separate compiler arguments on
    # x86_64 and to no arguments on arm64.
    # shellcheck disable=SC2086
    xcrun --sdk macosx clang++ -c "$SRC/$f" -o "$o" \
      -std=gnu++20 -O3 -DNDEBUG \
      -include "$PREFIX" -I "$SRC" -I "$CONFIG_DIR" \
      -ffile-prefix-map="$PKG=/src/SwiftStockfish" \
      -fdebug-prefix-map="$PKG=/src/SwiftStockfish" \
      --target="$arch-apple-ios13.2-macabi" -isysroot "$sdkpath" $extra
  done
  local lib="$OUT/libStockfish-maccatalyst-$arch.a"
  rm -f "$lib"
  xcrun --sdk macosx libtool -static -o "$lib" "$objdir"/*.o >/dev/null 2>&1
  printf '%s' "$lib"
}

fat() { local out="$1"; shift; lipo -create "$@" -output "$out"; printf '%s' "$out"; }

echo "== iphoneos arm64 =="
IOS_DEV="$(build_arch iphoneos arm64 "-mios-version-min=$IOS_MIN")"

echo "== iphonesimulator arm64 + x86_64 =="
SIM_A="$(build_arch iphonesimulator arm64   "-mios-simulator-version-min=$IOS_MIN")"
SIM_X="$(build_arch iphonesimulator x86_64  "-mios-simulator-version-min=$IOS_MIN")"
IOS_SIM="$(fat "$OUT/libStockfish-iphonesimulator.a" "$SIM_A" "$SIM_X")"

echo "== macosx arm64 + x86_64 =="
MAC_A="$(build_arch macosx arm64  "-mmacosx-version-min=$MAC_MIN")"
MAC_X="$(build_arch macosx x86_64 "-mmacosx-version-min=$MAC_MIN")"
MAC="$(fat "$OUT/libStockfish-macosx.a" "$MAC_A" "$MAC_X")"

echo "== appletvos arm64 =="
TVOS_DEV="$(build_arch appletvos arm64 "-mtvos-version-min=$TVOS_MIN")"

echo "== appletvsimulator arm64 + x86_64 =="
TVSIM_A="$(build_arch appletvsimulator arm64  "-mtvos-simulator-version-min=$TVOS_MIN")"
TVSIM_X="$(build_arch appletvsimulator x86_64 "-mtvos-simulator-version-min=$TVOS_MIN")"
TVOS_SIM="$(fat "$OUT/libStockfish-appletvsimulator.a" "$TVSIM_A" "$TVSIM_X")"

echo "== watchos arm64_32 + arm64 device =="
WATCH_A32="$(build_arch watchos arm64_32 "-mwatchos-version-min=$WATCHOS_MIN")"
WATCH_A64="$(build_arch watchos arm64    "-mwatchos-version-min=$WATCHOS_MIN")"
WATCHOS_DEV="$(fat "$OUT/libStockfish-watchos.a" "$WATCH_A32" "$WATCH_A64")"

echo "== watchsimulator arm64 + x86_64 =="
WSIM_A="$(build_arch watchsimulator arm64  "-mwatchos-simulator-version-min=$WATCHOS_MIN")"
WSIM_X="$(build_arch watchsimulator x86_64 "-mwatchos-simulator-version-min=$WATCHOS_MIN")"
WATCHOS_SIM="$(fat "$OUT/libStockfish-watchsimulator.a" "$WSIM_A" "$WSIM_X")"

echo "== xros (visionOS) arm64 =="
XROS_DEV="$(build_arch xros arm64 "-mtargetos=xros$VISIONOS_MIN")"

echo "== xrsimulator (visionOS) arm64 + x86_64 =="
XRSIM_A="$(build_arch xrsimulator arm64  "-mtargetos=xros$VISIONOS_MIN-simulator")"
XRSIM_X="$(build_arch xrsimulator x86_64 "-mtargetos=xros$VISIONOS_MIN-simulator")"
XROS_SIM="$(fat "$OUT/libStockfish-xrsimulator.a" "$XRSIM_A" "$XRSIM_X")"

echo "== Mac Catalyst arm64 + x86_64 (-macabi, no simulator slice) =="
CAT_A="$(build_macabi arm64)"
CAT_X="$(build_macabi x86_64)"
CATALYST="$(fat "$OUT/libStockfish-maccatalyst.a" "$CAT_A" "$CAT_X")"

echo "== create xcframework =="
rm -rf "$XCF_DIR/Stockfish.xcframework"
xcodebuild -create-xcframework \
  -library "$IOS_DEV" \
  -library "$IOS_SIM" \
  -library "$MAC" \
  -library "$TVOS_DEV" \
  -library "$TVOS_SIM" \
  -library "$WATCHOS_DEV" \
  -library "$WATCHOS_SIM" \
  -library "$XROS_DEV" \
  -library "$XROS_SIM" \
  -library "$CATALYST" \
  -output "$XCF_DIR/Stockfish.xcframework"

# Clean the intermediate objects; keep only the framework.
rm -rf "$OUT"
if LC_ALL=C grep -aR -F -l -- "$PKG" "$XCF_DIR/Stockfish.xcframework" >/dev/null; then
  echo "error: local checkout path remains in Stockfish.xcframework: $PKG" >&2
  exit 1
fi
echo "Done: $XCF_DIR/Stockfish.xcframework"
