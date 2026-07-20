# Platform Support

SwiftStockfish presents a byte-for-byte identical Swift API on every platform, but
delivers the engine two ways: a prebuilt xcframework on Apple, and a from-source
build everywhere else. `Package.swift` selects the appropriate target based on the
build host.

## Supported platforms

| Platform | Minimum | Engine | SIMD |
|---|---|---|---|
| macOS | 10.15 | prebuilt xcframework | arm64 NEON+DOTPROD · x86_64 AVX2+PEXT |
| iOS | 13 | prebuilt xcframework | arm64 NEON+DOTPROD |
| tvOS | 13 | prebuilt xcframework | arm64 NEON |
| watchOS | 6 | prebuilt xcframework | arm64 NEON (use a small `Hash`) |
| visionOS | 1 | prebuilt xcframework | arm64 NEON |
| Mac Catalyst | 13 | prebuilt xcframework | arm64 NEON · x86_64 AVX2 |
| Linux arm64 | — | source build | NEON+DOTPROD (full speed) |
| Linux x86_64 | — | source build | SSE2/generic; SSSE3/AVX2 opt-in |
| Android arm64 | API 28 | source build | NEON+DOTPROD (full speed) |
| Android x86_64 | API 28 | source build | SSE2/generic (emulator) |
| Android armv7 | API 28 | source build | generic |
| WASM | — | **unsupported** | — (blocked on WASI threading) |

## How the engine is delivered

- **Apple — prebuilt `Stockfish.xcframework`.** A `binaryTarget` with 10 slices
  (ios/macos/tvos/watchos/xros/maccatalyst, device + simulator), all built from
  the same Stockfish 18 source. Per-architecture SIMD flags are baked in at build
  time, so every Apple architecture links with full SIMD and the package carries no
  per-architecture compile flags.
- **Non-Apple (Linux / Android) — compiled from source.** The bridge plus all the
  Stockfish translation units compile in the `CStockfish` target. SIMD follows the
  compiler's own feature predefines: full NEON on arm64; on x86_64 the publishable
  default is the SSE2 baseline (correct and version-pinnable, with SSSE3/SSE4.1/AVX2
  available as an opt-in).

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

**arm64 incurs no penalty** — NEON is the architecture baseline on both Linux and
Apple.

## Cross-compiling for Android

Android uses the same from-source target as Linux, compiled with the
[Swift Android SDK](https://github.com/swiftlang/swift-android). The package builds
`aarch64-unknown-linux-android28` on a macOS host. Three steps are specific to
cross-compiling from macOS, all handled by `Tools/android/build-android.sh`:

1. **Force the source target.** SwiftPM evaluates `Package.swift` on the build host,
   so on macOS `#if os(macOS)` is true and the manifest would otherwise select the
   Apple xcframework target even for an Android build. Set
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
provides). arm64 builds at full NEON speed; the x86_64 emulator slice uses the SSE2
baseline. The public C API and Swift surface are identical to every other platform.

## WASM

WASM is not yet supported. The source target and the in-memory-queue bridge are
already WASI-compatible, but the current Swift WASM SDK lacks a working
multi-threading runtime and defaults to `-fno-exceptions`, while Stockfish uses
exceptions. The remaining work is in the toolchain, not the bridge.

## Releasing (maintainers)

Releases are produced by the **`Release binary`** GitHub Actions workflow, not by
hand. Push a semver **tag** (e.g. `git tag 18.0.10 && git push origin 18.0.10`); the
workflow builds `Stockfish.xcframework`, publishes it as a release asset, computes
its checksum, rewrites the active `binaryTarget` from `path:` to `url:` +
`checksum:` on a detached commit, and force-points the tag at that commit. **`main`
is never pushed** — it keeps its committed binary and stays path-based, so a plain
local `swift build` keeps working; the url form lives solely on release tags.
