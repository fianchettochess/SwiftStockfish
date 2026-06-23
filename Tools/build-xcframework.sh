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
# DEPLOYMENT FLOOR: the slices are compiled at iOS 13.0 / macOS 10.15
# (Catalina) — matching Package.swift's platforms, which are pinned there by
# Swift-concurrency back-deployment. The engine imposes no OS floor of its own,
# so these are simply set to the package's minimum. Bump IOS_MIN / MAC_MIN here
# in lockstep if Package.swift's platforms ever change.
#
# LICENSING: Stockfish is licensed GPL-3. This script — together with the
# Stockfish source it references (Sources/CStockfish/stockfish) and the
# StockfishConfig.h prefix header — is the separately-distributable GPL
# component: it builds a standalone binary that the (otherwise separate)
# wrapper merely links. Releasing this source + script independently keeps the
# GPL boundary clean.
#
# Slices built: iphoneos (arm64), iphonesimulator (arm64,x86_64),
#               macosx (arm64,x86_64).  Native macOS — no Mac Catalyst.
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

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
SRC="$PKG/Sources/CStockfish/stockfish"
PREFIX="$PKG/Sources/CStockfish/StockfishConfig.h"
OUT="$HERE/build"
# Place Stockfish.xcframework in the package's Frameworks/ by default (the
# binaryTarget path); an arg overrides the containing directory.
XCF_DIR="${1:-$PKG/Frameworks}"

IOS_MIN=13.0
MAC_MIN=10.15

echo "Stockfish source : $SRC"
echo "Output framework : $XCF_DIR/Stockfish.xcframework"
echo "Minimums         : iOS $IOS_MIN / macOS $MAC_MIN"
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
  # x86_64 needs AVX2 + BMI2 enabled so the intrinsics StockfishConfig.h's
  # USE_AVX2 / USE_PEXT defines rely on are available — mirrors the app's
  # OTHER_CPLUSPLUSFLAGS[arch=x86_64] = (-mavx2, -mbmi2). arm64 NEON/DOTPROD
  # is baseline on Apple clang, so it needs no extra arch flags. (left
  # unquoted so it word-splits / vanishes when empty)
  local extra=""
  [ "$arch" = "x86_64" ] && extra="-mavx2 -mbmi2"
  local objdir="$OUT/obj/$sdk-$arch"; mkdir -p "$objdir"
  for f in "${CPP[@]}"; do
    local o="$objdir/$(printf '%s' "$f" | tr './' '__').o"
    xcrun --sdk "$sdk" clang++ -c "$SRC/$f" -o "$o" \
      -std=gnu++20 -O3 -DNDEBUG \
      -include "$PREFIX" -I "$SRC" \
      -arch "$arch" -isysroot "$sdkpath" "$minflag" $extra
  done
  local lib="$OUT/libStockfish-$sdk-$arch.a"
  rm -f "$lib"
  xcrun --sdk "$sdk" libtool -static -o "$lib" "$objdir"/*.o >/dev/null 2>&1
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

echo "== create xcframework =="
rm -rf "$XCF_DIR/Stockfish.xcframework"
xcodebuild -create-xcframework \
  -library "$IOS_DEV" \
  -library "$IOS_SIM" \
  -library "$MAC" \
  -output "$XCF_DIR/Stockfish.xcframework"

# Clean the intermediate objects; keep only the framework.
rm -rf "$OUT"
echo "Done: $XCF_DIR/Stockfish.xcframework"
