# Platform Support

SwiftStockfish presents the same source-level Swift API on every platform, but
delivers the engine two ways: a prebuilt XCFramework on Apple, and a from-source
build everywhere else. `Package.swift` selects the appropriate target based on the
build host.

## Supported platforms

| Platform | Minimum | Engine | SIMD |
|---|---|---|---|
| macOS | 10.15 | prebuilt XCFramework | arm64 NEON+DOTPROD · x86_64 AVX2/BMI2 (PEXT, Haswell+) |
| iOS | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| tvOS | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| watchOS | 6 | prebuilt XCFramework | arm64_32 (watchOS 6+) + arm64 (watchOS 26+), NEON+DOTPROD; no armv7k |
| visionOS | 1 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| Mac Catalyst | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD · x86_64 AVX2/BMI2 (PEXT, Haswell+) |
| Linux arm64 | — | source build | NEON baseline; DOTPROD opt-in |
| Linux x86_64 | — | source build | SSE2/generic; SSSE3/AVX2 opt-in |
| Android arm64 | API 28 | source build | NEON baseline; DOTPROD opt-in |
| Android x86_64 | API 28 | source build | SSE2/generic (emulator) |
| Android armv7 | API 28 | source build | generic |
| WASM | — | **unsupported** | — (blocked on WASI threading) |

## How the engine is delivered

- **Apple — prebuilt `Stockfish.xcframework`.** A `binaryTarget` with 10 slices
  (ios/macos/tvos/watchos/xros/maccatalyst, device + simulator), all built from
  the same Stockfish 18 source. Apple ARM slices preserve NEON+DOTPROD and
  require FEAT_DotProd-capable hardware; x86_64 preserves the optimized
  AVX2/BMI2 (PEXT) build and requires Haswell-class hardware. Neither path has runtime
  baseline dispatch.
- **Non-Apple (Linux / Android) — compiled from source.** The bridge plus all the
  Stockfish translation units compile in the `CStockfish` target. SIMD follows the
  package config: baseline NEON on arm64 and baseline SSE2 on x86_64.
  DOTPROD on ARM and SSSE3/SSE4.1/AVX2 on x86_64 are explicit opt-ins.

The package carries **no `.unsafeFlags`**, which keeps it
version-publishable as a remote dependency. The Stockfish `.cpp` files are retained
on disk for GPL source availability but excluded from compilation on Apple, where
the prebuilt binary already contains them.

## x86_64 SIMD opt-in (Linux)

AVX2/BMI2 — and SSSE3/SSE4.1 — require codegen flags that are `.unsafeFlags` in
SwiftPM, which would break remote version-pinning, so the publishable default is
the SSE2 baseline. For full x86_64 speed, opt in from your own build settings,
accepting revision-pinning on that platform:

```bash
# SSSE3 / SSE4.1:
swift build -Xcxx -mssse3 -Xcxx -msse4.1 -Xcxx -mpopcnt
# AVX2 as well:
swift build -Xcxx -mavx2 -Xcxx -mbmi2 -Xcxx -DSF_ENABLE_AVX2
```

## ARM64 SIMD opt-in (Linux and Android)

ARM64 source builds default to the architecture's baseline NEON instructions.
This is safe across the full ARM64 device range, including Android API 28
devices that do not implement FEAT_DotProd. If every deployment target is known
to implement that feature, opt into Stockfish's faster SDOT kernel:

```bash
SWIFTSTOCKFISH_ENABLE_DOTPROD=1 swift build
```

The package translates the environment opt-in to `SF_ENABLE_DOTPROD` without
adding `.unsafeFlags`. There is no runtime dispatch: do not distribute an
opted-in build to CPUs without FEAT_DotProd. The prebuilt Apple ARM slices
remain explicitly opted in and retain their documented CPU floor.

## Cross-compiling for Android

Android uses the same from-source target as Linux, compiled with the
[Swift Android SDK](https://github.com/swiftlang/swift-android). The package builds
`aarch64-unknown-linux-android28` on a macOS host. Three steps are specific to
cross-compiling from macOS, all handled by `Tools/android/build-android.sh`:

1. **Force the source target.** SwiftPM evaluates `Package.swift` on the build host,
   so on macOS `#if os(macOS)` is true and the manifest would otherwise select the
   Apple XCFramework target even for an Android build. Set
   `SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1` to select the from-source target (and pull
   in swift-crypto for the loader's SHA-256) regardless of host.
2. **Match the toolchain to the SDK.** Swift modules are not forward-compatible: a
   6.3.2 Android SDK must be driven by a matching 6.3.2 host compiler. Install the
   matching toolchain and invoke it explicitly (e.g. `swiftly run swift build …`).
3. **Archive with the NDK's `llvm-ar`.** Apple's `ar` cannot read the response file
   SwiftPM passes when archiving; point the librarian at the NDK's `llvm-ar`.

```bash
# Defaults to aarch64 / API 28; override with ANDROID_ARCH / ANDROID_API_LEVEL.
Tools/android/build-android.sh                # debug
Tools/android/build-android.sh -c release     # release
```

The minimum Android API level is **28** (the lowest the Swift Android SDK
provides). arm64 builds use baseline NEON; set
`SWIFTSTOCKFISH_ENABLE_DOTPROD=1` only for a fleet that guarantees
FEAT_DotProd. The x86_64 emulator slice uses the SSE2 baseline. The public C API
and Swift surface are identical to every other platform.

## WASM

WASM is not yet supported. The source target and the in-memory-queue bridge are
already WASI-compatible, but the current Swift WASM SDK lacks a working
multi-threading runtime and defaults to `-fno-exceptions`, while Stockfish uses
exceptions. The remaining work is in the toolchain, not the bridge.

## Releasing (maintainers)

Releases are produced by the manual **`Release binary`** GitHub Actions workflow,
not by pushing a tag. Run it from the current default branch with a new semver
version. It rebuilds and tests the exact XCFramework (including the live engine),
archives and checksum-verifies it, creates the detached URL-based manifest commit,
then uploads and re-downloads the asset through a draft release before publishing.
The final tag is created once and is never force-moved. **`main` is never pushed**
by the workflow; it retains the committed path-based binary for local builds.
