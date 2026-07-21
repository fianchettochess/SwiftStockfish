# SwiftStockfish

[![Swift Package Index — Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FSwiftStockfish%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/fianchettochess/SwiftStockfish)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FSwiftStockfish%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/fianchettochess/SwiftStockfish)
[![Release](https://img.shields.io/github/v/release/fianchettochess/SwiftStockfish?sort=semver&label=release&color=blue)](https://github.com/fianchettochess/SwiftStockfish/releases)
[![CI](https://github.com/fianchettochess/SwiftStockfish/actions/workflows/ci.yml/badge.svg)](https://github.com/fianchettochess/SwiftStockfish/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A Swift Package Manager wrapper around the [Stockfish](https://stockfishchess.org)
chess engine. On **Apple** platforms, the engine links the prebuilt, multi-arch
`Stockfish.xcframework`; on **Linux**, the same Stockfish source is compiled from
source.
In both cases, a small C++ bridge in the `CStockfish` target drives Stockfish's
UCI loop over an in-process queue. The `SwiftStockfish` target provides a Swift
API (`StockfishEngine`) and a version-aware NNUE network manager
(`StockfishNetworkLoader`).

The package is distributed under **GPL-3.0** because it ships Stockfish. See
[License](#license).

- Wraps Stockfish source version **18** (`StockfishNetworks.stockfishVersion`).
- Platforms — **Apple:** macOS 10.15+, iOS 13+, tvOS 13+, watchOS 6+, visionOS 1+,
  and Mac Catalyst 13+. **Non-Apple:** Linux (x86_64 and arm64) and **Android**
  (API 28+; arm64, x86_64, and armv7). WASM is not yet supported. See
  [Platform support](#platform-support) for the full matrix and
  [Cross-compiling for Android](#cross-compiling-for-android) for Android setup.
- The prebuilt Apple **x86_64** slices intentionally retain AVX2/BMI2 performance
  and require a Haswell-class Intel CPU or newer; there is no runtime baseline
  fallback in that binary.
- The optimized **arm64/arm64_32** engine path likewise requires ARM
  **FEAT_DotProd**. It emits dot-product instructions directly and has no scalar
  runtime fallback; the watchOS device archive does not include legacy `armv7k`.
- **Conditional engine delivery (selected by the build host in `Package.swift`).**
  On **Apple**, the engine links a **prebuilt, multi-arch `Stockfish.xcframework`**
  (10 slices covering device and simulator variants of iOS, macOS, Mac Catalyst,
  tvOS, watchOS, and visionOS). On **non-Apple**, the same Stockfish source is
  **compiled from source** in the
  `CStockfish` target. The public API and the `CStockfish` product are identical
  either way, and the bridge carries **no `.unsafeFlags`**, so the package stays
  version-publishable. On `main`, the binary target uses `path:`; each release
  tag changes it to a checksum-protected `url:`. See [Releasing](#releasing).

## Installation

Add SwiftStockfish to your package dependencies:

```swift
.package(url: "https://github.com/fianchettochess/SwiftStockfish.git", from: "18.0.10")
```

Package versions track the wrapped Stockfish version. Stockfish 18 maps to the
`18.0.x` series; patch releases contain wrapper, binary, documentation, or test
changes without changing the engine version. A future Stockfish 18.1 wrapper
would begin at `18.1.0`.

## Quick start

```swift
import SwiftStockfish

// 1. Create a directory for exactly the NNUE nets the engine needs. This must
//    happen before the engine is created (see the warning below).
let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stockfish-nets")
try await StockfishNetworkLoader().ensure(in: dir) { p in
    print("\(p.file): \(p.bytesDownloaded)/\(p.totalBytes)")
}

// 2. Create the engine, pointed at that directory.
guard let engine = StockfishEngine(networkDirectory: dir) else {
    fatalError("engine failed to start")
}

// 3. Read UCI output as an AsyncStream, send UCI commands.
Task {
    for await line in engine.output {
        print("sf>", line)
        if line == "uciok" { engine.isReady() }
    }
}
engine.uci()
engine.send("position startpos")
engine.send("go depth 20")
```

> [!WARNING]
> **Run the loader before creating the engine.** Stockfish verifies its NNUE
> nets on the first `go`/`ucinewgame` and calls `exit(EXIT_FAILURE)` if one is
> missing or invalid, terminating the entire host process rather than throwing
> a catchable Swift error. `StockfishEngine.init?` preflights the nets and
> returns `nil` instead, but the preflight can pass only when the directory is
> already correct. Always run
> `StockfishNetworkLoader.ensure(in:)` (and `await` it) before
> `StockfishEngine(networkDirectory:)`. Raw `CStockfish` consumers get no
> preflight.

> [!WARNING]
> **Use one engine at a time per process.** The bridge swaps the process-global
> `std::cin`/`std::cout` stream buffers so Stockfish talks to an in-memory
> command queue and output callback. The bridge enforces the single-instance
> rule with a lifecycle gate: creating a second `StockfishEngine` blocks the
> calling thread until the first is fully torn down. Never create or tear down
> an engine on the main actor. Call `shutdown()` (or release the engine) before
> creating another; a leaked engine blocks the next creation indefinitely.

## NNUE weight provisioning

The NNUE networks are large binaries that are **not** embedded in the compiled
engine (`StockfishConfig.h` sets `NNUE_EMBEDDING_OFF`); the engine loads them
from disk at startup. You choose when the loader runs:

### Bundle at build time

Run `StockfishNetworkLoader().ensure(in:)` once on your machine (a build step, a
script, a first-run developer task), then ship the resulting `nn-*.nnue` files
as bundled app resources. At runtime point the engine at the bundle directory.
No network access is needed on the user's device. (The package `.gitignore`
deliberately ignores `*.nnue`, so the nets are fetched, not committed.)

### Download at runtime

Call `ensure(in:)` at app startup into a writable directory (Application
Support / Caches), show its `Progress` to the user, then create the engine.
Subsequent launches find the nets already present and valid, so `ensure` is a
fast no-op (it verifies checksums, downloads nothing).

In both models, the loader must complete before the engine is created. A missing
or invalid net makes `StockfishEngine.init?` fail; raw `CStockfish` consumers
risk the process-terminating `exit`.

## Testing

The default suite is offline and does not download NNUE networks:

```sh
swift test
```

Run the live UCI integration suite with the exact opt-in value `1`:

```sh
SWIFTSTOCKFISH_INTEGRATION=1 swift test
```

Any other value leaves the live suite disabled. The live tests run serially and
share one persistent, versioned NNUE fixture. Before either test creates an
engine, the loader verifies the full pinned SHA-256 digest of both cached
networks. The first run downloads about 107 MB; later runs reuse valid files.

CI builds the Linux source arm in a Swift 6.4 release-branch image pinned by its
immutable container digest. A trusted self-hosted Intel job verifies AVX2 and
BMI2 support, links the Apple binary target, and runs the full live suite. Fork
pull requests run only on the GitHub-hosted Linux job. The release workflow also
rebuilds and tests the exact XCFramework before publishing it.

## Upgrade workflow: Stockfish 18 to 18.1

A Stockfish upgrade is a clean, mostly-automatic swap. The daily
[`Upstream watch`](.github/workflows/upstream-watch.yml) workflow opens a
tracking issue when a new stable `sf_*` release is available (it compares
upstream against [`.upstream-version`](.upstream-version)).

1. Re-vendor the engine source and re-apply our local patches in one step:

   ```sh
   Tools/update-stockfish.sh sf_18.1
   ```

   This fetches upstream `official-stockfish/Stockfish` at the tag, syncs it into
   `Sources/CStockfish/stockfish/` (dropping `Makefile`/`main.cpp`), re-applies
   the patches under [`Tools/patches/`](Tools/patches/), and updates
   `.upstream-version`. **The source is committed, not fetched at build time** —
   the non-Apple SwiftPM arm compiles it directly and GPL-3.0 requires shipping
   it, and SwiftPM cannot fetch/compile external source during a build. If a
   patch no longer applies (upstream moved the code it touches), the script fails
   loudly — rebase that `.patch` and re-run.

   Then **rebuild `Frameworks/Stockfish.xcframework`** with
   [`Tools/build-xcframework.sh`](Tools/build-xcframework.sh) (the
   [`Release binary`](#releasing) workflow runs the same script in CI). The
   binary is what actually links on Apple platforms — the kept `.cpp` are not
   compiled there.
2. Bump `StockfishNetworks.stockfishVersion`.
3. Update `StockfishNetworks.required` with the new version's net filenames.
   The real filenames live in the engine's `evaluate.h`
   (`EvalFileDefaultNameBig` / `EvalFileDefaultNameSmall`); copy them verbatim —
   then compute each new net's full SHA-256 (`shasum -a 256 nn-*.nnue`) and pin
   it as the `sha256:` of the corresponding entry in
   `StockfishNetworks.required`. The loader verifies the full pinned digest
   after every download (the filename's 12-hex prefix is only a fallback for
   test fixtures without a pinned hash), so a net that merely matches the
   filename prefix cannot pass.

On the next `ensure(in:)`, the loader **downloads the new nets and prunes the
old ones** (it deletes any `nn-*.nnue` in the directory that isn't in the
required set), so a directory that held the 18 nets becomes a directory holding
exactly the 18.1 nets with no manual cleanup.

## Build model

How the engine is delivered depends on the build host — `Package.swift` selects
the targets with a host check (`#if os(...)`), which a cross-compile can override
with `SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1` (see
[Cross-compiling for Android](#cross-compiling-for-android)):

- **Apple — prebuilt `Stockfish.xcframework`** (a `binaryTarget`). The
  XCFramework carries **10 slices** across iOS, macOS, Mac Catalyst, tvOS,
  watchOS, and visionOS device and simulator destinations. Every slice is built
  from the same Stockfish 18 source by
  `Tools/build-xcframework.sh`. Apple ARM slices preserve the NEON+DOTPROD path
  and require FEAT_DotProd-capable hardware; x86_64 preserves the optimized
  AVX2/PEXT build and requires Haswell-class hardware. A
  prebuilt binary carries no compile flags, so SwiftPM's "can't pass C++ flags
  per-architecture" limitation never applies.
- **Non-Apple (Linux / Android) — compiled from source.** The `#else` arm compiles
  the bundled Stockfish source and the bridge in the `CStockfish` target (no
  `sources:`, so SwiftPM builds every `.cpp`). The package config selects
  **NEON+DOTPROD** on arm64 (requiring FEAT_DotProd); on x86_64 the publishable
  default is the **SSE2 baseline** (with SSSE3/SSE4.1/AVX2 as an opt-in — see
  [Platform support](#platform-support)). No `.unsafeFlags`, so the source arm is
  version-pinnable too. The bridge is plain C++ (`StockfishBridge.cpp`), so it
  compiles under non-Apple clang with no Objective-C++ runtime.

- **Version-publishable (no `.unsafeFlags`).** The `CStockfish` target compiles
  only the C++ bridge and carries **no `.unsafeFlags`**. The SIMD/NNUE
  config that previously needed a force-included prefix header now lives in the
  binary; the bridge gets it via a plain `#include "StockfishConfig.h"` (a
  source include, not a compiler flag). SwiftPM forbids `.unsafeFlags` only in
  version-pinned *remote* dependencies, so removing them is what makes the
  package publishable.

- **GPL source availability.** The Stockfish `.cpp` are kept under
  `Sources/CStockfish/stockfish/` (their headers feed the bridge's `#include`s);
  they are simply **excluded from compilation** because the binary already
  contains them.

## Platform support

| Platform | Minimum | Engine | SIMD |
|---|---|---|---|
| macOS | 10.15 | prebuilt XCFramework | arm64 NEON+DOTPROD · x86_64 AVX2+PEXT (Haswell+) |
| iOS | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| tvOS | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| watchOS | 6 | prebuilt XCFramework | arm64_32 (watchOS 6+) and arm64 (watchOS 26+), NEON+DOTPROD; no armv7k |
| visionOS | 1 | prebuilt XCFramework | arm64 NEON+DOTPROD |
| Mac Catalyst | 13 | prebuilt XCFramework | arm64 NEON+DOTPROD · x86_64 AVX2 (Haswell+) |
| Linux arm64 | — | source build | NEON+DOTPROD (FEAT_DotProd required) |
| Linux x86_64 | — | source build | SSE2/generic default; SSSE3/AVX2 opt-in |
| Android arm64 | API 28 | source build | NEON+DOTPROD (FEAT_DotProd required) |
| Android x86_64 | API 28 | source build | SSE2/generic default (emulator) |
| Android armv7 | API 28 | source build | generic |
| WASM | — | **unsupported** | — (blocked on WASI threading) |

Apple x86_64 slices intentionally require AVX2/BMI2 (Haswell-class or newer);
there is no runtime baseline fallback. ARM64/arm64_32 slices similarly emit
integer dot-product instructions directly and require FEAT_DotProd-capable
hardware; there is no ARM scalar fallback. The watch device slice starts at
arm64_32 and therefore does not cover legacy armv7k watches.

**Linux x86_64 SIMD.** AVX2/BMI2 — and even SSSE3/SSE4.1 — need code-generation flags that
are `.unsafeFlags` in SwiftPM, which would break remote version-pinning. So the
publishable default is the **SSE2 baseline** (Stockfish's generic NNUE — correct,
builds everywhere, version-pinnable, but slower). For full x86_64 speed a consumer
opts in by passing `-mssse3 -msse4.1 -mpopcnt` (and `-mavx2 -mbmi2 -DSF_ENABLE_AVX2`
for AVX2) in their own build settings, accepting **revision-pinning** on that
platform. **arm64** needs no build flag to select this package's optimized path,
but that path is intentionally compiled with DOTPROD and therefore requires
FEAT_DotProd-capable hardware. **WASM** is deferred: the source arm and the
in-memory queue bridge are already WASI-compatible, but today's Swift WASM SDK
lacks a working multithreading
runtime (and defaults to `-fno-exceptions`, while Stockfish uses exceptions).
Revisit once WASI shared-everything-threads has a shipping runtime — the
remaining work is the toolchain, not the bridge.

### Cross-compiling for Android

Android uses the **same `#else` source arm as Linux**, compiled with the
[Swift Android SDK](https://github.com/swiftlang/swift-android) (install it with
`skip android sdk install` or swiftly). Verified building
`aarch64-unknown-linux-android28` against `swift-6.3.2-RELEASE_android` on a macOS
host — the engine, the bridge, the Swift API, and the NNUE loader all compile and
archive. Three things are specific to cross-compiling from a macOS host, all
handled by [`Tools/android/build-android.sh`](Tools/android/build-android.sh):

1. **Force the source arm.** SwiftPM evaluates `Package.swift` on the *build
   host*, so on macOS `#if os(macOS)` is true and the manifest would pick the
   Apple XCFramework arm even for an Android build. Set
   **`SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1`** to select the from-source arm (and
   pull in swift-crypto for the loader's SHA-256) regardless of host.
2. **Match the toolchain to the SDK.** Swift modules are not forward-compatible —
   a 6.3.2 Android SDK must be driven by a 6.3.2 *host* compiler, or the build
   fails with `module compiled with Swift 6.3.2 cannot be imported by the Swift
   6.2.4 compiler`. Install the matching toolchain and invoke it explicitly
   (`swiftly run swift build …`); the system `/usr/bin/swift` is Xcode's and may
   not match.
3. **Archive with the NDK's `llvm-ar`.** Apple's cctools `ar` can't read the
   `@responsefile` SwiftPM passes when archiving, so the default librarian fails
   with `ar: @…/Objects.LinkFileList: No such file or directory`. Point the
   librarian at the NDK's `llvm-ar` with a `--toolset`.

```bash
# Defaults to aarch64 / API 28; override with ANDROID_ARCH / ANDROID_API_LEVEL.
Tools/android/build-android.sh                       # debug
Tools/android/build-android.sh -c release            # release
```

The minimum Android API level is **28** (the lowest the Swift Android SDK
provides). arm64 builds use the optimized NEON+DOTPROD path and therefore require
FEAT_DotProd; the x86_64 emulator slice uses the SSE2 baseline. The public C API
and Swift surface are byte-for-byte identical to every other platform.

## Releasing

Releases are produced by the manual **Release binary** GitHub Actions workflow
([`.github/workflows/release.yml`](.github/workflows/release.yml)), not by pushing
a tag. In **Actions → Release binary → Run workflow**, choose the current default
branch and enter a new stable `N.N.N` version. Existing tags and releases are
rejected; published versions are never re-cut or force-moved.

The workflow runs on `macos-26` with Xcode 26.6 and, in one pass:

1. Verifies that it is running from the current default-branch head and that the
   requested version, tag, and release are unused.
2. Rebuilds all ten XCFramework slices, asserts every slice's architecture
   inventory plus the watch per-architecture deployment metadata, and confirms
   that the x86_64 archive still contains AVX2 and BMI2 instructions.
3. Runs both the ordinary package suite and the gated live UCI suite against
   the freshly rebuilt macOS arm64 slice on the hosted runner. The x86_64 slice
   is architecture/SIMD-validated here and link-tested on Intel CI.
4. Archives the exact framework, extracts and byte-compares it, and computes its
   SwiftPM checksum.
5. On a detached HEAD, rewrites `Package.swift` to the release URL and checksum,
   removes the committed framework, validates the manifest, and commits only
   those intended release-tree changes.
6. Pushes that final commit through a temporary preparation branch, creates a
   **draft** release targeting it, uploads the asset, verifies the target,
   downloads and compares the uploaded bytes, and only then publishes. On an
   ordinary failure, cleanup deletes a draft only after confirming that run owns
   it; preparation-branch cleanup is likewise best-effort.

The semver tag is therefore created once at the final URL-based manifest commit,
and the exact attached asset was built and tested before publication. **`main`
is never pushed by the workflow**: it remains path-based with the committed
framework for ordinary development.

After each release, consumers pin a version tag and SwiftPM fetches the
XCFramework from the release using the manifest's `url:` and `checksum:`. The
release tag contains no committed XCFramework. `main` remains path-based and
links the committed XCFramework, so a plain local `swift build` continues to
work. Because every release starts from a clean, path-based `main`, the workflow
is rerunnable.

**NNUE nets** are orthogonal to all of this: keep using `StockfishNetworkLoader`
at runtime, or bundle the nets as a package resource — the loader's logic is
identical regardless of how the engine binary is hosted.

## Package layout

```
SwiftStockfish/
  Package.swift
  .upstream-version              # pinned upstream sf_* tag
  .github/
    workflows/ci.yml             # build+test both arms (push to main / PRs / manual dispatch)
    workflows/release.yml        # exact-artifact tests, draft publish, and one-time release tag
    workflows/upstream-watch.yml # daily notify-only upstream release watcher
    upstream-watch-issue.md      # body template for the watcher's tracking issue
    scripts/rewrite_binary_target.py  # changes the active binaryTarget from path: to URL and checksum
  Frameworks/
    Stockfish.xcframework        # Prebuilt multi-arch engine — path binaryTarget on `main`;
                                 #   a release tag drops it here and serves it from the release asset
  Tools/
    update-stockfish.sh          # re-vendor upstream at a tag and re-apply local patches
    patches/                     # the local patches update-stockfish.sh re-applies
    build-xcframework.sh         # builds the multi-arch Stockfish.xcframework
    android/build-android.sh     # cross-compiles the source arm for Android
  Sources/
    CStockfish/                  # bridge-only target (links the engine binary)
      include/StockfishBridge.h  # Public umbrella header (publicHeadersPath)
      StockfishConfig.h          # config header, #included by the bridge (no force-include)
      StockfishBridge.cpp        # the bridge: drives Stockfish's UCI loop over an in-process queue
      StockfishIO.h              # in-memory command queue and output callback (portable bridge I/O)
      stockfish/                 # the copied Stockfish src/ tree: HEADERS feed the
                                 #   bridge; .cpp kept for GPL but EXCLUDED from build
    SwiftStockfish/              # Swift API
      StockfishEngine.swift      # the engine wrapper (AsyncStream of UCI output)
      StockfishNetworks.swift    # the net manifest: version, required filenames, and pinned SHA-256s
      StockfishNetworkLoader.swift  # version-aware download / verify / prune
  Tests/
    SwiftStockfishTests/         # logic and filesystem suites; gated live-engine integration suite
  docs-site/                     # MkDocs documentation site
  README.md
  LICENSE                        # GPL-3.0
  .gitignore
```

## Implementation notes

- **The Swift tools version is 6.0.** The Apple deployment floor is iOS 13 and
  macOS 10.15, matching Swift concurrency's back-deployment floor and the
  minimum versions embedded in the XCFramework.
- **An extra `.headerSearchPath(".")`** is on the `CStockfish` cxx settings
  (alongside the engine-dir `.headerSearchPath`) so the bridge's
  `#include "StockfishConfig.h"` resolves from the target root. The force-include
  `.unsafeFlag` that previously also relied on this path was **removed** as part
  of the binaryTarget migration — the bridge now `#include`s the config as its
  first line, so the target carries no `.unsafeFlags` and is version-publishable.
- **The bridge's `#include "src/…"` paths were changed to bare includes** (for example,
  `#include "bitboard.h"`) to match the new `stockfish/` layout, resolved via the
  `.headerSearchPath("stockfish")`. Noted inline in `StockfishBridge.cpp`.
- **`LICENSE` contains the unmodified GPL-3.0 text.** Stockfish attribution and
  GPL §5(a) modification notices remain in the source and
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
- **Build environment note:** some SMB network mounts do not provide the atomic
  `rename()` semantics Swift's index store and module cache require. If a build
  fails there, use a local filesystem with atomic rename support.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for test, binary-reproduction, licensing,
and repository-hygiene requirements. Report security issues using the private
process in [SECURITY.md](SECURITY.md), not a public issue containing sensitive
details.

## License

Stockfish is licensed under the **GNU General Public License, version 3**. This
package ships Stockfish (as the prebuilt `Stockfish.xcframework`, built from the
Stockfish source kept under `Sources/CStockfish/stockfish/`) and links it into
its output, so the entire SwiftStockfish package is a GPL-3.0 work and is
distributed under GPL-3.0. See
[`LICENSE`](LICENSE). If you consume this package in an application, that
linkage carries GPL-3.0 obligations — treat SwiftStockfish as the separately-
distributable GPL component.
