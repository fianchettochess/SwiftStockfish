#!/bin/bash
#
# Focused compile-time contract check for StockfishConfig.h.
#
# An arm64 source build must use baseline NEON without emitting SDOT. The
# explicit SF_ENABLE_DOTPROD opt-in must restore the optimized dot-product
# kernel used by the Apple XCFramework build.
#
set -euo pipefail

SF_HERE="$(cd "$(dirname "$0")" && pwd)"
SF_HEADER="$SF_HERE/../Sources/CStockfish/StockfishConfig.h"
SF_CXX_BIN="${CXX:-clang++}"

preprocess_arm64() {
  "$SF_CXX_BIN" \
    --target=aarch64-none-linux-gnu \
    -dM -E -x c++ \
    -include "$SF_HEADER" \
    "$@" \
    /dev/null
}

contains_define() {
  local macros="$1"
  local pattern="$2"
  grep -Eq "$pattern" <<< "$macros"
}

SF_BASELINE_MACROS="$(preprocess_arm64)"
SF_DOTPROD_MACROS="$(preprocess_arm64 -DSF_ENABLE_DOTPROD=1)"

if ! contains_define "$SF_BASELINE_MACROS" '^#define USE_NEON 8$'; then
  echo "error: baseline arm64 configuration did not enable USE_NEON=8" >&2
  exit 1
fi
if contains_define "$SF_BASELINE_MACROS" '^#define USE_NEON_DOTPROD 1$'; then
  echo "error: baseline arm64 configuration unexpectedly enabled dot-product" >&2
  exit 1
fi
if ! contains_define "$SF_DOTPROD_MACROS" '^#define USE_NEON 8$'; then
  echo "error: opted-in arm64 configuration did not retain USE_NEON=8" >&2
  exit 1
fi
if ! contains_define "$SF_DOTPROD_MACROS" '^#define USE_NEON_DOTPROD 1$'; then
  echo "error: SF_ENABLE_DOTPROD did not enable USE_NEON_DOTPROD" >&2
  exit 1
fi

echo "verified: arm64 source baseline = NEON (no dot-product)"
echo "verified: SF_ENABLE_DOTPROD opt-in = NEON+DOTPROD"
