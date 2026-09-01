#!/bin/bash
#
# Focused compile-time contract check for StockfishConfig.h.
#
# TWO ARCHITECTURES, BOTH DIRECTIONS. For each of arm64 and x86_64 this asserts
# what the DEFAULT source build gets and what each documented opt-in restores.
# Both halves matter: an assertion that the opt-in works is worth little without
# the paired assertion that the default does NOT silently already have it, which
# is how an accidental baseline change reaches consumers unnoticed.
#
# WHY x86_64 IS HERE NOW. Until 2026-09-01 this script preprocessed
# `--target=aarch64-none-linux-gnu` and nothing else, while being run from a
# release step named "Verify source-engine SIMD configuration". It would have
# passed unchanged if the entire x86 branch of StockfishConfig.h had been
# deleted. That gap mattered more once Windows became a gated platform: Windows
# takes the same from-source arm as Linux, so its x86_64 baseline is this
# header's x86 branch and nothing was checking it.
#
# WHAT THE x86_64 BASELINE IS, AND WHY IT IS NOT AVX2. StockfishConfig.h gates
# USE_AVX2 on `SF_ENABLE_AVX2 && __AVX2__ && __BMI2__`. The latter two are
# compiler predefines that only `-mavx2 -mbmi2` set, and codegen flags are
# `.unsafeFlags` in SwiftPM, which would make this package ineligible as a
# version-pinned dependency. So SSE2 is the publishable default by deliberate
# design, not by oversight — see PlatformSupport.md — and the opt-ins below are
# the documented route to more. This script gates that documented promise.
#
set -euo pipefail

SF_HERE="$(cd "$(dirname "$0")" && pwd)"
SF_HEADER="$SF_HERE/../Sources/CStockfish/StockfishConfig.h"
SF_CXX_BIN="${CXX:-clang++}"

preprocess() {
  local triple="$1"
  shift
  "$SF_CXX_BIN" \
    --target="$triple" \
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

require_define() {
  local macros="$1" pattern="$2" what="$3"
  if ! contains_define "$macros" "$pattern"; then
    echo "error: $what" >&2
    exit 1
  fi
}

refuse_define() {
  local macros="$1" pattern="$2" what="$3"
  if contains_define "$macros" "$pattern"; then
    echo "error: $what" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- arm64 -----
#
# An arm64 source build must use baseline NEON without emitting SDOT. The
# explicit SF_ENABLE_DOTPROD opt-in must restore the optimized dot-product
# kernel used by the Apple XCFramework build.

SF_ARM64_TRIPLE='aarch64-none-linux-gnu'
SF_BASELINE_MACROS="$(preprocess "$SF_ARM64_TRIPLE")"
SF_DOTPROD_MACROS="$(preprocess "$SF_ARM64_TRIPLE" -DSF_ENABLE_DOTPROD=1)"

require_define "$SF_BASELINE_MACROS" '^#define USE_NEON 8$' \
  "baseline arm64 configuration did not enable USE_NEON=8"
refuse_define "$SF_BASELINE_MACROS" '^#define USE_NEON_DOTPROD 1$' \
  "baseline arm64 configuration unexpectedly enabled dot-product"
require_define "$SF_DOTPROD_MACROS" '^#define USE_NEON 8$' \
  "opted-in arm64 configuration did not retain USE_NEON=8"
require_define "$SF_DOTPROD_MACROS" '^#define USE_NEON_DOTPROD 1$' \
  "SF_ENABLE_DOTPROD did not enable USE_NEON_DOTPROD"

echo "verified: arm64 source baseline = NEON (no dot-product)"
echo "verified: SF_ENABLE_DOTPROD opt-in = NEON+DOTPROD"

# --------------------------------------------------------------- x86_64 -----
#
# Checked against BOTH x86_64 triples the from-source arm is actually built for.
# Linux and Windows share this header branch, and Windows is the one with no
# other coverage, so a divergence between them has to fail here.

SF_X86_TRIPLES=(
  'x86_64-unknown-linux-gnu'
  'x86_64-unknown-windows-msvc'
)

# The tiers StockfishConfig.h can reach above the baseline. Every one of these
# must be ABSENT by default and PRESENT under the matching opt-in; the pairing
# is the point.
SF_AVX2_TIER=(USE_AVX2 USE_PEXT USE_POPCNT USE_SSE41 USE_SSSE3)

for triple in "${SF_X86_TRIPLES[@]}"; do
  baseline="$(preprocess "$triple")"

  # The floor, and it is a floor rather than an accident: SSE2 is guaranteed by
  # the x86_64 ABI, so it needs no flag and no opt-in.
  require_define "$baseline" '^#define USE_SSE2 1$' \
    "baseline $triple configuration did not enable USE_SSE2"

  for tier in "${SF_AVX2_TIER[@]}"; do
    refuse_define "$baseline" "^#define $tier 1\$" \
      "baseline $triple configuration unexpectedly enabled $tier — the \
publishable default must stay SSE2, because anything above it needs codegen \
flags that are .unsafeFlags in SwiftPM"
  done

  # The documented full opt-in (PlatformSupport.md, 'x86_64 SIMD opt-in').
  avx2="$(preprocess "$triple" -mavx2 -mbmi2 -DSF_ENABLE_AVX2)"
  for tier in "${SF_AVX2_TIER[@]}"; do
    require_define "$avx2" "^#define $tier 1\$" \
      "the documented AVX2 opt-in did not enable $tier on $triple"
  done

  # The documented INTERMEDIATE opt-in, which the docs advertise separately and
  # which must not silently collapse into either neighbour.
  mid="$(preprocess "$triple" -mssse3 -msse4.1 -mpopcnt)"
  require_define "$mid" '^#define USE_SSSE3 1$' \
    "the documented SSSE3/SSE4.1 opt-in did not enable USE_SSSE3 on $triple"
  require_define "$mid" '^#define USE_SSE41 1$' \
    "the documented SSSE3/SSE4.1 opt-in did not enable USE_SSE41 on $triple"
  require_define "$mid" '^#define USE_POPCNT 1$' \
    "the documented SSSE3/SSE4.1 opt-in did not enable USE_POPCNT on $triple"
  refuse_define "$mid" '^#define USE_AVX2 1$' \
    "the SSSE3/SSE4.1 opt-in unexpectedly reached AVX2 on $triple"

  echo "verified: $triple source baseline = SSE2 only"
  echo "verified: $triple SSSE3/SSE4.1 opt-in = SSSE3+SSE41+POPCNT (no AVX2)"
  echo "verified: $triple AVX2 opt-in = AVX2+PEXT+POPCNT+SSE41+SSSE3"
done
