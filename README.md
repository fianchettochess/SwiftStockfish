# SwiftStockfish

[![Swift Package Index — Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fjaredbrewer%2FSwiftStockfish%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/jaredbrewer/SwiftStockfish)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fjaredbrewer%2FSwiftStockfish%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/jaredbrewer/SwiftStockfish)
[![Release](https://img.shields.io/github/v/release/jaredbrewer/SwiftStockfish?sort=semver&label=release&color=blue)](https://github.com/jaredbrewer/SwiftStockfish/releases)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A Swift Package Manager wrapper around the [Stockfish](https://stockfishchess.org)
chess engine. On **Apple** platforms the engine links a **prebuilt, multi-arch
`Stockfish.xcframework`**; on **Linux** the same Stockfish source is **compiled
from source**. Either way a small C++ bridge in the `CStockfish` target drives
Stockfish's UCI loop over an in-process queue. The `SwiftStockfish`
target exposes a clean Swift API (`StockfishEngine`) plus a version-aware NNUE
network manager (`StockfishNetworkLoader`).

This whole package is a **GPL-3.0** artifact because it ships Stockfish — see
[Licensing](#licensing).

- Wraps Stockfish source version **18** (`StockfishNetworks.stockfishVersion`).
- Platforms — **Apple:** macOS 10.15+, iOS 13+, tvOS 13+, watchOS 6+, visionOS 1+,
  Mac Catalyst 13+. **Non-Apple:** Linux (x86_64 + arm64) and **Android** (API 28+;
  arm64 · x86_64 · armv7). WASM is not yet supported. Full matrix + per-platform
  SIMD: [Platform support](#platform-support); cross-compiling the Android arm
  from macOS: [Cross-compiling for Android](#cross-compiling-for-android).
- **Conditional engine delivery (selected by the build host in `Package.swift`).**
  On **Apple** the engine links a **prebuilt, multi-arch `Stockfish.xcframework`**
  (10 slices — ios/macos/tvos/watchos/xros/maccatalyst, device + simulator). On
  **non-Apple** the same Stockfish source is **compiled from source** in the
  `CStockfish` target. The public API and the `CStockfish` product are identical
  either way, and the bridge carries **no `.unsafeFlags`**, so the package stays
  version-publishable. On `main` the binaryTarget is `path:`-referenced; each
  release **tag** flips it to a checksummed **`url:`** — see [Releasing](#releasing).

## Quick start

```swift
import SwiftStockfish

// 1. Make a directory hold exactly the NNUE nets the engine needs. This MUST
//    happen before the engine is created (see the warning below).
let dir = URL.applicationSupportDirectory.appending(path: "stockfish-nets")
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

> ⚠️ **Run the loader before creating the engine.** Stockfish loads its NNUE
> evaluation network during initialization and calls `exit(EXIT_FAILURE)` if the
> net is missing or invalid. That terminates the **entire host process** — it is
> not a Swift error you can catch. `StockfishNetworkLoader.ensure(in:)`
> guarantees the directory holds exactly the valid required nets, so always run
> it (and `await` it) before `StockfishEngine(networkDirectory:)`.

> ⚠️ **One engine per process.** The bridge swaps the process-global
> `std::cin`/`std::cout` stream buffers so Stockfish talks to in-process pipes. A
> second live `StockfishEngine` clobbers the first's redirection. Create, use,
> and destroy one engine before making another.

## The two NNUE consumption models

The NNUE networks are large binaries that are **not** embedded in the compiled
engine (`StockfishConfig.h` sets `NNUE_EMBEDDING_OFF`); the engine loads them
from disk at startup. You choose when the loader runs:

**(a) Build/setup time — bundle for an offline app.**
Run `StockfishNetworkLoader().ensure(in:)` once on your machine (a build step, a
script, a first-run developer task), then ship the resulting `nn-*.nnue` files
as bundled app resources. At runtime point the engine at the bundle directory.
No network access is needed on the user's device. (The package `.gitignore`
deliberately ignores `*.nnue`, so the nets are fetched, not committed.)

**(b) Runtime — download on first launch.**
Call `ensure(in:)` at app startup into a writable directory (Application
Support / Caches), show its `Progress` to the user, then create the engine.
Subsequent launches find the nets already present and valid, so `ensure` is a
fast no-op (it verifies checksums, downloads nothing).

In **both** models the rule is the same: the loader MUST complete before the
engine is created, because Stockfish exits the process on a missing net.

## Upgrade workflow (e.g. 18 → 18.1)

A Stockfish upgrade is a clean, mostly-automatic swap:

1. Replace the engine source in `Sources/CStockfish/stockfish/` with the new
   version's `src/` tree (these headers feed the bridge and the `.cpp` remain for
   GPL source availability; re-copy `StockfishConfig.h` / the bridge if they
   changed upstream), then **rebuild `Frameworks/Stockfish.xcframework`** from the
   same source with [`Tools/build-xcframework.sh`](Tools/build-xcframework.sh)
   (the [`Release binary`](#releasing) workflow runs this same script in CI). The
   binary is what actually links — the kept `.cpp` are not compiled here.
2. Bump `StockfishNetworks.stockfishVersion`.
3. Update `StockfishNetworks.required` with the new version's net filenames.
   The real filenames live in the engine's `evaluate.h`
   (`EvalFileDefaultNameBig` / `EvalFileDefaultNameSmall`); copy them verbatim —
   the 12-hex prefix in each filename is the net's own SHA-256 checksum, which
   the loader verifies.

On the next `ensure(in:)`, the loader **downloads the new nets and prunes the
old ones** (it deletes any `nn-*.nnue` in the directory that isn't in the
required set), so a directory that held the 18 nets becomes a directory holding
exactly the 18.1 nets with no manual cleanup.

## How the engine is built and linked

How the engine is delivered depends on the build host — `Package.swift` selects
the targets with a host check (`#if os(...)`), which a cross-compile can override
with `SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1` (see
[Cross-compiling for Android](#cross-compiling-for-android)):

- **Apple — prebuilt `Stockfish.xcframework`** (a `binaryTarget`). The
  xcframework carries **10 slices** — ios/macos/tvos/watchos/xros/maccatalyst,
  device + simulator — all built from the same Stockfish 18 source by
  `Tools/build-xcframework.sh`. The per-arch SIMD flags (`USE_AVX2` / `USE_PEXT`
  need `-mavx2 -mbmi2`) are baked into the x86_64 slices at *build* time. A
  prebuilt binary carries no compile flags, so SwiftPM's "can't pass C++ flags
  per-architecture" limitation never applies — every Apple arch links with full
  SIMD.
- **Non-Apple (Linux / Android) — compiled from source.** The `#else` arm compiles
  the bundled Stockfish source + the bridge in the `CStockfish` target (no
  `sources:`, so SwiftPM builds every `.cpp`). SIMD follows the compiler's own
  feature predefines: full **NEON** on arm64; on x86_64 the publishable default
  is the **SSE2 baseline** (with SSSE3/SSE4.1/AVX2 as an opt-in — see
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
| macOS | 10.15 | prebuilt xcframework | arm64 NEON+DOTPROD · x86_64 AVX2+PEXT |
| iOS | 13 | prebuilt xcframework | arm64 NEON+DOTPROD |
| tvOS | 13 | prebuilt xcframework | arm64 NEON |
| watchOS | 6 | prebuilt xcframework | arm64 NEON (use a small `Hash`) |
| visionOS | 1 | prebuilt xcframework | arm64 NEON |
| Mac Catalyst | 13 | prebuilt xcframework | arm64 NEON · x86_64 AVX2 |
| Linux arm64 | — | source build | NEON+DOTPROD (baseline, full speed) |
| Linux x86_64 | — | source build | SSE2/generic default; SSSE3/AVX2 opt-in |
| Android arm64 | API 28 | source build | NEON+DOTPROD (baseline, full speed) |
| Android x86_64 | API 28 | source build | SSE2/generic default (emulator) |
| Android armv7 | API 28 | source build | generic |
| WASM | — | **unsupported** | — (blocked on WASI threading) |

Apple **simulator** x86_64 slices carry AVX2; device slices are arm64/NEON. **CI**
(`.github/workflows/ci.yml`) builds the Linux x86_64 source arm and the macOS
binaryTarget arm on every push.

**Linux x86_64 SIMD.** AVX2/BMI2 — and even SSSE3/SSE4.1 — need codegen flags that
are `.unsafeFlags` in SwiftPM, which would break remote version-pinning. So the
publishable default is the **SSE2 baseline** (Stockfish's generic NNUE — correct,
builds everywhere, version-pinnable, but slower). For full x86_64 speed a consumer
opts in by passing `-mssse3 -msse4.1 -mpopcnt` (and `-mavx2 -mbmi2 -DSF_ENABLE_AVX2`
for AVX2) in their own build settings, accepting **revision-pinning** on that
platform. **arm64** — Linux and Apple — pays nothing: NEON is the architecture
baseline. **WASM** is deferred: the source arm and the in-memory-queue bridge are already
WASI-compatible, but today's Swift WASM SDK lacks a working multi-threading
runtime (and defaults to `-fno-exceptions`, while Stockfish uses exceptions).
Revisit once WASI shared-everything-threads has a shipping runtime — the
remaining work is the toolchain, not the bridge.

### Cross-compiling for Android

Android uses the **same `#else` source arm as Linux**, compiled with the
[Swift Android SDK](https://github.com/swiftlang/swift-android) (install it with
`skip android sdk install` or swiftly). Verified building
`aarch64-unknown-linux-android28` against `swift-6.3.2-RELEASE_android` on a macOS
host — the engine, the bridge, and the Swift API + NNUE loader all compile and
archive. Three things are specific to cross-compiling from a macOS host, all
handled by [`Tools/android/build-android.sh`](Tools/android/build-android.sh):

1. **Force the source arm.** SwiftPM evaluates `Package.swift` on the *build
   host*, so on macOS `#if os(macOS)` is true and the manifest would pick the
   Apple xcframework arm even for an Android build. Set
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
provides). arm64 builds at full NEON speed; the x86_64 emulator slice uses the
SSE2 baseline. The public C API and Swift surface are byte-for-byte identical to
every other platform.

## Releasing

Releases are produced by the **`Release binary`** GitHub Actions workflow
([`.github/workflows/release.yml`](.github/workflows/release.yml)), not by hand.
It turns the package into a proper **url-based binary-release package**: the
xcframework is published as a release asset and the binary is no longer carried
in git.

**To cut a release:** push a semver **tag** (e.g. `git tag 18.0.1 && git push
origin 18.0.1`) — the push triggers the workflow. *Or*, as a fallback for
re-cutting a version whose tag already exists, run it manually: **Actions** →
**Release binary** → **Run workflow** → enter the `version`. Either way the
workflow runs on `macos-14` and, in one pass:

1. **Validates the version and checks for collisions** *first* — the version (the
   pushed tag name, or the dispatch input) must match `N.N.N` (with an optional
   `.`/`-` suffix) and be a valid git tag name, and the **release** must not
   already exist. (On manual dispatch the *tag* must not exist either, since the
   run creates it; on a tag push the tag *is* the trigger and gets force-moved.)
   A bad or already-released version aborts the run **before** anything is built,
   so a re-run can't leave half-published state.
2. Builds `Frameworks/Stockfish.xcframework` by running
   [`Tools/build-xcframework.sh`](Tools/build-xcframework.sh) in CI (the same
   multi-arch slices and SIMD flags as a local build; the NNUE nets are **not**
   needed to build the binary).
3. Zips it for SwiftPM:
   `ditto -c -k --sequesterRsrc --keepParent Frameworks/Stockfish.xcframework Stockfish.xcframework.zip`.
4. Computes the checksum of **that exact zip** with
   `swift package compute-checksum`.
5. **Creates the GitHub release** for `<version>` and uploads
   `Stockfish.xcframework.zip` as its asset, then verifies the asset attached —
   so the asset the `url:` will point at exists *before* any tag resolves to the
   url-based manifest.
6. **Rewrites the active binaryTarget** in `Package.swift` from `path:` to
   `url:` + `checksum:`, pointing the url at the release asset
   (`…/releases/download/<version>/Stockfish.xcframework.zip`) with the checksum
   from step 4, and `swift package dump-package`-validates the result. (Only the
   active target is touched; the commented example above it is left alone, and
   the rewrite is idempotent across `path:` and an already-`url:` form — see the
   rewriter at
   [`.github/scripts/rewrite_binary_target.py`](.github/scripts/rewrite_binary_target.py).)
7. **Removes the committed binary**
   (`git rm -r --ignore-unmatch Frameworks/Stockfish.xcframework`) and adds
   `Frameworks/*.xcframework` to `.gitignore` — the binary now lives in the
   release, not the repo.
8. Commits that url-rewritten / binary-removed tree **on a detached HEAD**, then
   force-points the `<version>` tag at *that* commit and pushes **only the tag**.
   **`main` is never pushed** — it keeps its committed binary and stays
   path-based; the url form lives solely on the tag. (The tag is force-pushed
   with `GITHUB_TOKEN`, which by GitHub's design doesn't start another workflow
   run, so a tag-push release can't loop.)

Because the checksum and the attached asset are computed from the **same zip in
the same run**, they always match — there is no build-reproducibility concern,
and the url exactly matches the asset URL pattern
`/releases/download/<tag>/Stockfish.xcframework.zip`.

**After the first release**, consumers pin a version tag and SwiftPM fetches the
xcframework from the release by `url:` + `checksum:` — the package is a clean
url-based binary package, with the binary out of git. `main` itself stays
**path-based** (it links the committed xcframework, which the workflow never
removes from `main`) so a plain local `swift build` keeps working; only the
release tags carry the url form. Because every release starts from a clean
path-based `main`, the workflow is fully re-runnable.

> The existing **`18.0.0`** tag is the original **path-based** form (binary
> committed to the repo). The first CI release supersedes it with the url-based
> form described above.

**NNUE nets** are orthogonal to all of this: keep using `StockfishNetworkLoader`
at runtime, or bundle the nets as a package resource — the loader's logic is
identical regardless of how the engine binary is hosted.

## Package layout

```
SwiftStockfish/
  Package.swift
  .github/
    workflows/release.yml        # "Release binary" workflow (builds + publishes + url-rewrites)
    scripts/rewrite_binary_target.py  # flips the active binaryTarget path: -> url:+checksum: in CI
  Frameworks/
    Stockfish.xcframework        # PREBUILT multi-arch engine — path binaryTarget on `main`;
                                 #   a release tag drops it here and serves it from the release asset
  Sources/
    CStockfish/                  # bridge-only target (links the engine binary)
      include/StockfishBridge.h  # PUBLIC umbrella header (publicHeadersPath)
      StockfishConfig.h          # config header, #included by the bridge (no force-include)
      StockfishBridge.cpp        # the bridge: drives Stockfish's UCI loop over an in-process queue
      StockfishIO.h              # in-memory command queue + output callback (portable bridge I/O)
      stockfish/                 # the copied Stockfish src/ tree: HEADERS feed the
                                 #   bridge; .cpp kept for GPL but EXCLUDED from build
    SwiftStockfish/              # Swift API
      StockfishEngine.swift      # the engine wrapper (AsyncStream of UCI output)
      StockfishNetworks.swift    # the net manifest (version + required filenames)
      StockfishNetworkLoader.swift  # version-aware download / verify / prune
  README.md
  LICENSE                        # GPL-3.0
  .gitignore
```

## Licensing

Stockfish is licensed under the **GNU General Public License, version 3**. This
package ships Stockfish (as the prebuilt `Stockfish.xcframework`, built from the
Stockfish source kept under `Sources/CStockfish/stockfish/`) and links it into
its output, so the entire SwiftStockfish package is a GPL-3.0 work and is
distributed under GPL-3.0. See
[`LICENSE`](LICENSE). If you consume this package in an application, that
linkage carries GPL-3.0 obligations — treat SwiftStockfish as the separately-
distributable GPL component.

## Deviations from the original spec

- **swift-tools-version is `6.0`.** Originally chosen because `.macOS(.v15)` /
  `.iOS(.v18)` require 6.0; the deployment floor was since **lowered to iOS 13 /
  macOS 10.15** (`.iOS(.v13)` / `.macOS(.v10_15)`, which older tools versions
  support too — see the manifest header on the Swift-concurrency back-deployment
  floor), so 6.0 is no longer required by the platform declarations and is simply
  retained. The spec allowed "5.9 or 6.0".
- **An extra `.headerSearchPath(".")`** is on the `CStockfish` cxx settings
  (alongside the engine-dir `.headerSearchPath`) so the bridge's
  `#include "StockfishConfig.h"` resolves from the target root. The force-include
  `.unsafeFlag` that previously also relied on this path was **removed** as part
  of the binaryTarget migration — the bridge now `#include`s the config as its
  first line, so the target carries no `.unsafeFlags` and is version-publishable.
- **The bridge's `#include "src/…"` paths were changed to bare includes** (e.g.
  `#include "bitboard.h"`) to match the new `stockfish/` layout, resolved via the
  `.headerSearchPath("stockfish")`. Noted inline in `StockfishBridge.cpp`.
- **No `COPYING` file was copied** — Fianchetto's Stockfish `src/` did not
  contain one. `LICENSE` is the canonical GPL-3.0 text with a header noting the
  package embeds Stockfish.
- **Build environment note:** `swift build` fails on an SMB network mount (the
  index store / module cache rely on atomic `rename()` semantics SMB does not
  provide). Build on a local disk. This package lives on the local APFS volume
  for that reason.
