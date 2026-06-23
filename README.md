# SwiftStockfish

A Swift Package Manager wrapper around the [Stockfish](https://stockfishchess.org)
chess engine. It compiles Stockfish's C++ source plus a small Objective-C++
bridge into a `CStockfish` target, and exposes a clean Swift API
(`StockfishEngine`) plus a version-aware NNUE network manager
(`StockfishNetworkLoader`) in the `SwiftStockfish` target.

This whole package is a **GPL-3.0** artifact because it embeds Stockfish — see
[Licensing](#licensing).

- Wraps Stockfish source version **18** (`StockfishNetworks.stockfishVersion`).
- Platforms: **macOS 15+, iOS 18+**.
- **Prototype status:** builds from source for **Apple Silicon (arm64) only**.
  See [Prototype limitations](#prototype-limitations) and the
  [binaryTarget migration path](#binarytarget-migration-path-multi-arch--publishing).

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
   version's `src/` tree (and re-copy `StockfishConfig.h` / the bridge if they
   changed upstream).
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

## Prototype limitations

This prototype **builds Stockfish from source and targets Apple Silicon (arm64)
only.** Two reasons, both about build flags:

- **Per-arch SIMD flags.** `StockfishConfig.h` enables `USE_AVX2` / `USE_PEXT`
  for x86_64, and those intrinsics require `-mavx2 -mbmi2`. SwiftPM cannot apply
  C++ flags per-architecture, so a single source target can't satisfy both
  arm64 and x86_64. On arm64 the NEON + DOTPROD paths the config enables are
  baseline for Apple clang and need no extra arch flag, so arm64 builds cleanly
  with no special handling. (If you build for an x86_64 destination from this
  source target it will fail to compile the AVX2 intrinsics — expected.)

- **`.unsafeFlags` → not version-publishable.** The `CStockfish` target uses
  `.unsafeFlags(["-include", "StockfishConfig.h"])` to force-include the prefix
  header. SwiftPM forbids `.unsafeFlags` in a package consumed as a *version-
  pinned remote* dependency. So this package can be consumed as a **local path
  dependency** (fine for an app's first integration) but **not** via
  `.package(url:..., from:...)` as-is.

Both limitations are removed by the binaryTarget migration below.

## binaryTarget migration path (multi-arch + publishing)

To ship multi-arch and become a publishable, version-pinnable remote package,
replace the source `CStockfish` target with a prebuilt, checksummed
`binaryTarget`:

1. **Prebuild the xcframework.** Fianchetto's
   `Tools/StockfishKit/build-xcframework.sh` already does exactly this — it
   compiles the same Stockfish source into `Stockfish.xcframework` with slices
   for iphoneos (arm64), iphonesimulator (arm64 + x86_64) and macosx
   (arm64 + x86_64), applying `-mavx2 -mbmi2` *only* to the x86_64 slices. A
   prebuilt binary carries no compile flags, so it sidesteps both the per-arch
   and `.unsafeFlags` problems at once.
2. **Host it** as a release asset (e.g. a GitHub release) and compute its
   checksum with `swift package compute-checksum Stockfish.xcframework.zip`.
3. **Switch the target** to:
   ```swift
   .binaryTarget(
       name: "CStockfish",
       url: "https://.../Stockfish.xcframework.zip",
       checksum: "<sha256 from compute-checksum>"
   )
   ```
   The Obj-C++ bridge can either live inside the xcframework or stay as a thin
   companion source target that links it; the public umbrella header
   (`include/StockfishBridge.h`) stays the Swift module's C interface either way.
4. **NNUE nets:** keep using `StockfishNetworkLoader` at runtime, or bundle the
   nets as a package resource — the loader's logic is identical either way.

## Package layout

```
SwiftStockfish/
  Package.swift
  Sources/
    CStockfish/                  # C++ engine + Obj-C++ bridge (one target)
      include/StockfishBridge.h  # PUBLIC umbrella header (publicHeadersPath)
      StockfishConfig.h          # force-included prefix header (defines)
      StockfishBridge.mm         # the bridge: drives Stockfish's UCI loop over pipes
      stockfish/                 # the copied Stockfish src/ tree (~23 .cpp + headers)
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
package compiles Stockfish's source directly into its output, so the entire
SwiftStockfish package is a GPL-3.0 work and is distributed under GPL-3.0. See
[`LICENSE`](LICENSE). If you consume this package in an application, that
linkage carries GPL-3.0 obligations — treat SwiftStockfish as the separately-
distributable GPL component.

## Deviations from the original spec

- **swift-tools-version is `6.0`, not `5.9`.** `.macOS(.v15)` / `.iOS(.v18)`
  were only added to `PackageDescription` in 6.0; with 5.9 the manifest fails to
  compile. The spec explicitly allowed "5.9 or 6.0".
- **An extra `.headerSearchPath(".")`** was added to the `CStockfish` cxx
  settings (alongside the spec's `.headerSearchPath` to the engine dir) so the
  `-include StockfishConfig.h` force-include and the bridge's
  `#include "StockfishConfig.h"` resolve from the target root.
- **The bridge's `#include "src/…"` paths were changed to bare includes** (e.g.
  `#include "bitboard.h"`) to match the new `stockfish/` layout, resolved via the
  `.headerSearchPath("stockfish")`. Noted inline in `StockfishBridge.mm`.
- **No `COPYING` file was copied** — Fianchetto's Stockfish `src/` did not
  contain one. `LICENSE` is the canonical GPL-3.0 text with a header noting the
  package embeds Stockfish.
- **Build environment note:** `swift build` fails on an SMB network mount (the
  index store / module cache rely on atomic `rename()` semantics SMB does not
  provide). Build on a local disk. This package lives on the local APFS volume
  for that reason.
