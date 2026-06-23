# SwiftStockfish

A Swift Package Manager wrapper around the [Stockfish](https://stockfishchess.org)
chess engine. The engine ships as a **prebuilt, multi-arch `binaryTarget`**
(`Stockfish.xcframework`); a small Objective-C++ bridge in the `CStockfish`
target links that binary and drives Stockfish's UCI loop. The `SwiftStockfish`
target exposes a clean Swift API (`StockfishEngine`) plus a version-aware NNUE
network manager (`StockfishNetworkLoader`).

This whole package is a **GPL-3.0** artifact because it ships Stockfish — see
[Licensing](#licensing).

- Wraps Stockfish source version **18** (`StockfishNetworks.stockfishVersion`).
- Platforms: **macOS 15+, iOS 18+**.
- **binaryTarget-based, multi-arch:** the engine xcframework carries
  ios-arm64, ios-arm64_x86_64-simulator and macos-arm64_x86_64 slices. The
  bridge target carries no `.unsafeFlags`, so the package is version-publishable
  once the binaryTarget is hosted remotely. Currently the binaryTarget is
  referenced by **`path:` (local prototype)**; see the
  [binaryTarget publish path](#binarytarget-publish-path-hosting-the-xcframework).

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
   same source (Fianchetto's `Tools/StockfishKit/build-xcframework.sh`). The
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

The engine is **not** compiled from source by this package anymore. It ships as
a prebuilt `Stockfish.xcframework` referenced by a `binaryTarget`:

- **Multi-arch out of the box.** The xcframework carries three slices —
  ios-arm64, ios-arm64_x86_64-simulator and macos-arm64_x86_64 — built from the
  same Stockfish 18 source. The per-arch SIMD flags (`StockfishConfig.h`'s
  `USE_AVX2` / `USE_PEXT` need `-mavx2 -mbmi2`) are applied to the x86_64 slices
  at *build* time, inside the xcframework. A prebuilt binary carries no compile
  flags, so SwiftPM's "can't pass C++ flags per-architecture" limitation no
  longer applies — every supported arch links.

- **Version-publishable (no `.unsafeFlags`).** The `CStockfish` target compiles
  only the Obj-C++ bridge and carries **no `.unsafeFlags`**. The SIMD/NNUE
  config that previously needed a force-included prefix header now lives in the
  binary; the bridge gets it via a plain `#include "StockfishConfig.h"` (a
  source include, not a compiler flag). SwiftPM forbids `.unsafeFlags` only in
  version-pinned *remote* dependencies, so removing them is what makes the
  package publishable.

- **GPL source availability.** The Stockfish `.cpp` are kept under
  `Sources/CStockfish/stockfish/` (their headers feed the bridge's `#include`s);
  they are simply **excluded from compilation** because the binary already
  contains them.

## binaryTarget publish path (hosting the xcframework)

The package is already binaryTarget-based, but in **path mode** (the
binaryTarget references `Frameworks/Stockfish.xcframework` directly). That is
enough to consume it as a local path dependency. To publish it as a
version-pinnable *remote* package, host the xcframework and swap to a checksummed
URL:

1. **(Re)build the xcframework** if needed. Fianchetto's
   `Tools/StockfishKit/build-xcframework.sh` produces `Stockfish.xcframework`
   with the three slices above, applying `-mavx2 -mbmi2` *only* to the x86_64
   slices.
2. **Zip and host it** as a release asset (e.g. a GitHub release
   `Stockfish.xcframework.zip`) and compute its checksum:
   ```
   swift package compute-checksum Stockfish.xcframework.zip
   ```
3. **Switch the binaryTarget** from `path:` to `url:` + `checksum:`:
   ```swift
   .binaryTarget(
       name: "StockfishEngine",
       url: "https://.../Stockfish.xcframework.zip",
       checksum: "<sha256 from compute-checksum>"
   )
   ```
   The Obj-C++ bridge stays as the thin `CStockfish` source target that links it;
   the public umbrella header (`include/StockfishBridge.h`) remains the Swift
   module's C interface.
4. **NNUE nets:** keep using `StockfishNetworkLoader` at runtime, or bundle the
   nets as a package resource — the loader's logic is identical either way.

## Package layout

```
SwiftStockfish/
  Package.swift
  Frameworks/
    Stockfish.xcframework        # PREBUILT multi-arch engine (path binaryTarget)
  Sources/
    CStockfish/                  # bridge-only target (links the engine binary)
      include/StockfishBridge.h  # PUBLIC umbrella header (publicHeadersPath)
      StockfishConfig.h          # config header, #included by the bridge (no force-include)
      StockfishBridge.mm         # the bridge: drives Stockfish's UCI loop over pipes
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

- **swift-tools-version is `6.0`, not `5.9`.** `.macOS(.v15)` / `.iOS(.v18)`
  were only added to `PackageDescription` in 6.0; with 5.9 the manifest fails to
  compile. The spec explicitly allowed "5.9 or 6.0".
- **An extra `.headerSearchPath(".")`** is on the `CStockfish` cxx settings
  (alongside the engine-dir `.headerSearchPath`) so the bridge's
  `#include "StockfishConfig.h"` resolves from the target root. The force-include
  `.unsafeFlag` that previously also relied on this path was **removed** as part
  of the binaryTarget migration — the bridge now `#include`s the config as its
  first line, so the target carries no `.unsafeFlags` and is version-publishable.
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
