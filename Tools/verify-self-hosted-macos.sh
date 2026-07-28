#!/bin/bash
#
# Validate the capabilities required to rebuild SwiftStockfish's Apple binary.
#
# Release reproducibility depends on the Xcode and Swift major lines plus the
# Intel instruction-set floor baked into the XCFramework. Patch-level Xcode,
# build, and Swift versions may advance without changing that contract.
#
set -euo pipefail

SF_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [ "$(uname -m)" != "x86_64" ]; then
  fail "the Apple binary must be rebuilt on x86_64"
fi
if [ ! -d "$SF_DEVELOPER_DIR" ]; then
  fail "full Xcode developer directory not found at $SF_DEVELOPER_DIR"
fi

XCODE_VERSION="$(DEVELOPER_DIR="$SF_DEVELOPER_DIR" xcodebuild -version)"
SWIFT_VERSION="$(DEVELOPER_DIR="$SF_DEVELOPER_DIR" xcrun swift --version)"
XCODE_PRODUCT_LINE="$(printf '%s\n' "$XCODE_VERSION" | sed -n '1p')"
XCODE_BUILD_LINE="$(printf '%s\n' "$XCODE_VERSION" | sed -n '2p')"

printf '%s\n' "$XCODE_VERSION"
printf '%s\n' "$SWIFT_VERSION"

if ! grep -Eq '^Xcode 26([.][0-9]+)*([[:space:]].*)?$' \
  <<< "$XCODE_PRODUCT_LINE"; then
  fail "Xcode 26.x is required (found: $XCODE_PRODUCT_LINE)"
fi
if ! grep -Eq '^Build version [^[:space:]]+$' <<< "$XCODE_BUILD_LINE"; then
  fail "xcodebuild did not report a full Xcode build version"
fi
if ! grep -Eq 'Apple Swift version 6([.]|[[:space:](]|$)' \
  <<< "$SWIFT_VERSION"; then
  fail "an Apple Swift 6.x toolchain is required"
fi

MACOS_SDK="$(DEVELOPER_DIR="$SF_DEVELOPER_DIR" xcrun \
  --sdk macosx --show-sdk-path)"
if [ ! -d "$MACOS_SDK" ]; then
  fail "the selected Xcode does not provide a macOS SDK"
fi

LEAF7_FEATURES="$(sysctl -n machdep.cpu.leaf7_features)"
if ! grep -qw AVX2 <<< "$LEAF7_FEATURES"; then
  fail "the release host CPU does not provide AVX2"
fi
if ! grep -qw BMI2 <<< "$LEAF7_FEATURES"; then
  fail "the release host CPU does not provide BMI2"
fi

echo "verified: full Xcode 26.x with Apple Swift 6.x"
echo "verified: x86_64 release host with AVX2/BMI2"
