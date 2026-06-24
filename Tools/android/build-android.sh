#!/usr/bin/env bash
#
# Cross-compile SwiftStockfish for Android.
#
# Wraps `swift build` with the three things a host cross-compile to Android needs
# (see README → "Cross-compiling for Android"):
#
#   1. SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1 — `Package.swift` is evaluated on the
#      build HOST, so on macOS `#if os(macOS)` is true and the manifest would pick
#      the Apple xcframework arm even for an Android build. This forces the
#      from-source engine arm (and pulls swift-crypto for the NNUE SHA-256).
#   2. A host Swift toolchain that MATCHES the Swift Android SDK version (Swift
#      modules are not forward-compatible). Driven via `swiftly run` when present.
#   3. The NDK's `llvm-ar` as the librarian — Apple's cctools `ar` can't read the
#      `@responsefile` SwiftPM passes when archiving, failing with
#      "ar: @…/Objects.LinkFileList: No such file or directory". Supplied via a
#      generated --toolset.
#
# Usage:  Tools/android/build-android.sh [extra `swift build` args]
# Env:    ANDROID_ARCH (aarch64|x86_64|armv7, default aarch64)
#         ANDROID_API_LEVEL (default 28 — the Swift Android SDK floor)
set -euo pipefail

ARCH="${ANDROID_ARCH:-aarch64}"
API_LEVEL="${ANDROID_API_LEVEL:-28}"
TRIPLE="${ARCH}-unknown-linux-android${API_LEVEL}"

# Locate the installed Swift Android SDK artifactbundle and its bundled NDK llvm-ar.
SDK_ROOT="${HOME}/Library/org.swift.swiftpm/swift-sdks"
SDK_BUNDLE="$(find "${SDK_ROOT}" -maxdepth 1 -iname '*android*.artifactbundle' 2>/dev/null | sort | tail -1)"
[ -n "${SDK_BUNDLE}" ] || { echo "error: no Swift Android SDK found under ${SDK_ROOT} (run: skip android sdk install)" >&2; exit 1; }
LLVM_AR="$(find "${SDK_BUNDLE}" -path '*toolchains/llvm/prebuilt/*/bin/llvm-ar' 2>/dev/null | head -1)"
[ -n "${LLVM_AR}" ] || { echo "error: llvm-ar not found inside ${SDK_BUNDLE}" >&2; exit 1; }

# Generate a toolset that overrides the librarian with the NDK's llvm-ar.
TOOLSET="$(mktemp -t swiftstockfish-android-toolset.XXXXXX)"
trap 'rm -f "${TOOLSET}"' EXIT
printf '{ "schemaVersion": "1.0", "librarian": { "path": "%s" } }\n' "${LLVM_AR}" > "${TOOLSET}"

# Prefer `swiftly run` so the host compiler matches the SDK's Swift version.
RUN=(swift)
command -v swiftly >/dev/null 2>&1 && RUN=(swiftly run swift)

echo "SwiftStockfish → Android: triple=${TRIPLE}  toolchain=$("${RUN[@]}" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)" >&2
set -x
SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1 "${RUN[@]}" build \
  --swift-sdk "${TRIPLE}" \
  --toolset "${TOOLSET}" \
  "$@"
