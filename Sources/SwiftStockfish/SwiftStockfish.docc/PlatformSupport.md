# Platform Support

Where the engine runs, how it's delivered per platform, and how to cross-compile
for Android.

## Overview

SwiftStockfish presents the same source-level Swift API on every platform,
but delivers the engine in two ways: a prebuilt XCFramework on Apple, and a
from-source build everywhere else. `Package.swift` selects the appropriate
delivery path based on the build host.

## Supported Platforms

| Platform | Minimum | Engine | SIMD |
|---|---|---|---|
| macOS | 10.15 | prebuilt XCFramework | arm64 NEON+DOTPROD · x86_64 AVX2/BMI2 (PEXT, Haswell+) |
| iOS | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| tvOS | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| watchOS | 6 | prebuilt XCFramework | arm64_32 (watchOS 6+) + arm64 (watchOS 26+), NEON+DOTPROD; no armv7k |
| visionOS | 1 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| Mac Catalyst | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD · x86_64 AVX2/BMI2 (PEXT, Haswell+) |
| Linux arm64 | — | source build | NEON+DOTPROD (FEAT_DotProd required) |
| Linux x86_64 | — | source build | SSE2/generic; SSSE3/AVX2 opt-in |
| Android arm64 | API 28 | source build | NEON+DOTPROD (FEAT_DotProd required) |
| Android x86_64 | API 28 | source build | SSE2/generic (emulator) |
| Android armv7 | API 28 | source build | generic |
| WASM | — | **unsupported** | — (blocked on WASI threading) |

## How the engine is delivered

- **Apple — prebuilt `Stockfish.xcframework`.** A `binaryTarget` with 10 slices
  (ios/macos/tvos/watchos/xros/maccatalyst, device + simulator), all built from
  the same Stockfish 18 source. ARM slices preserve NEON+DOTPROD and require
  FEAT_DotProd-capable hardware; x86_64 preserves the AVX2/BMI2 (PEXT) path
  and requires Haswell-class hardware. Neither optimized path runtime-dispatches
  to a baseline implementation.
- **Non-Apple (Linux / Android) — compiled from source.** The bridge and all
  Stockfish translation units compile in the `CStockfish` target. SIMD follows
  the package config: NEON+DOTPROD on arm64 (FEAT_DotProd required); on x86_64
  the publishable default is the SSE2 baseline (correct and version-pinnable, with
  SSSE3/SSE4.1/AVX2 available as an opt-in).

The package carries **no `.unsafeFlags`**, which is what keeps it
version-publishable as a remote dependency. The Stockfish `.cpp` are kept on disk
for GPL source-availability but excluded from compilation on Apple (the binary
already contains them).

## x86_64 SIMD opt-in (Linux)

AVX2/BMI2 — and even SSSE3/SSE4.1 — need codegen flags that are `.unsafeFlags` in
SwiftPM, which would break remote version-pinning, so the publishable default is
the SSE2 baseline. For full x86_64 speed, opt in from *your own* build settings
(accepting revision-pinning on that platform):

```bash
# SSSE3 / SSE4.1:
swift build -Xcxx -mssse3 -Xcxx -msse4.1 -Xcxx -mpopcnt
# AVX2 as well:
swift build -Xcxx -mavx2 -Xcxx -mbmi2 -Xcxx -DSF_ENABLE_AVX2
```

**arm64 needs no opt-in flag**, but the selected optimized kernel emits DOTPROD
instructions and therefore requires FEAT_DotProd-capable hardware. The watchOS
device slice begins at arm64_32; legacy armv7k watches are not included.

## Cross-compiling for Android

Android uses the same from-source delivery path as Linux, compiled with the
[Swift Android SDK](https://github.com/swiftlang/swift-android). Three steps are
specific to building from a macOS host, all handled by
`Tools/android/build-android.sh`:

1. **Force the from-source build.** SwiftPM evaluates `Package.swift` on the
   build host, so on macOS `#if os(macOS)` is true and the manifest would select
   the Apple XCFramework even for an Android target. Set
   `SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1` to select the from-source delivery path
   (and pull in swift-crypto for the loader's SHA-256) regardless of host.
2. **Match the toolchain to the SDK.** Swift modules are not forward-compatible —
   a 6.3.2 Android SDK must be driven by a matching 6.3.2 host compiler. Install
   the matching toolchain and invoke it explicitly (e.g. `swiftly run swift
   build …`).
3. **Archive with the NDK's `llvm-ar`.** Apple's `ar` cannot read the response
   file SwiftPM passes when archiving; point the librarian at the NDK's `llvm-ar`.

```bash
# Defaults to aarch64 / API 28; override with ANDROID_ARCH / ANDROID_API_LEVEL.
Tools/android/build-android.sh                # debug
Tools/android/build-android.sh -c release     # release
```

The minimum Android API level is **28** (the lowest the Swift Android SDK
provides). arm64 builds use NEON+DOTPROD and require FEAT_DotProd; the x86_64
emulator slice uses the SSE2 baseline. The public C API and Swift surface are identical to every other
platform.

## WASM

WASM is not yet supported. The from-source build and the in-memory-queue bridge
are already WASI-compatible, but the current Swift WASM SDK lacks a working
multi-threading runtime and defaults to `-fno-exceptions`, while Stockfish uses
exceptions. The remaining work is in the toolchain, not the bridge.
