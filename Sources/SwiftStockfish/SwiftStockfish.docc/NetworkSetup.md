# Network Setup

Prepare the NNUE evaluation networks with ``StockfishNetworkLoader`` so a
directory holds exactly the nets the engine needs — before the engine starts.

## Overview

The NNUE networks are large binaries the engine loads from disk at startup; they
are *not* embedded in the engine. ``StockfishNetworkLoader`` makes a directory
hold **exactly** the right nets — keeping valid ones, (re)downloading
missing/corrupt ones, and pruning leftovers from a previous Stockfish version —
and it must finish before the engine is created.

> Important: Stockfish exits the host process (`exit(EXIT_FAILURE)`) on a missing
> or invalid net. Always `await` ``StockfishNetworkLoader/ensure(in:progress:)``
> (or point the engine at a known-good bundled directory) **before**
> ``StockfishEngine/init(networkDirectory:)``. This is a process-fatal abort, not
> a catchable Swift error.

## The manifest

``StockfishNetworks`` is the single source of truth for which nets the bundled
engine needs. ``StockfishNetworks/stockfishVersion`` records the wrapped engine
version, and ``StockfishNetworks/required`` lists the exact nets.

Stockfish 18 uses **two** nets — a "big" net for the main evaluation and a
"small" net for a faster, lower-accuracy path; both must be present. Each net is
described by a ``StockfishNetworks/Network``, whose
``StockfishNetworks/Network/filename`` follows Stockfish's own scheme,
`nn-<first 12 hex of the file's SHA-256>.nnue`. That 12-hex prefix — exposed as
``StockfishNetworks/Network/shaPrefix`` — is a self-describing checksum, which is
exactly what the loader verifies after a download.

## The loader

Create a ``StockfishNetworkLoader`` (its ``StockfishNetworkLoader/init(networks:)``
defaults to ``StockfishNetworks/required``, available afterward as
``StockfishNetworkLoader/networks``) and call
``StockfishNetworkLoader/ensure(in:progress:)``:

```swift
import SwiftStockfish

let dir = URL.applicationSupportDirectory.appending(path: "stockfish-nets")
try await StockfishNetworkLoader().ensure(in: dir)
```

``StockfishNetworkLoader/ensure(in:progress:)`` does three things, in order:

1. ensures the directory exists;
2. **prunes** any `nn-*.nnue` not in the required set (so upgrading from one
   Stockfish version's nets to another's leaves no leftovers);
3. for each required net, keeps it if present and SHA-valid, otherwise downloads
   it (fishtest first, then the official GitHub networks repo), verifies the
   checksum, and atomically moves it into place.

It is **idempotent** — a present, valid net is never re-downloaded, so a warm
launch is a fast checksum-only no-op. Downloads go to a temp file that is
verified before replacing the destination, so a failed or aborted download never
leaves a corrupt net behind.

## Reporting progress

The optional `progress` closure receives one ``StockfishNetworkLoader/Progress``
value per in-flight download. Read ``StockfishNetworkLoader/Progress/file`` for
the filename, and ``StockfishNetworkLoader/Progress/fractionCompleted`` for a
`0...1` fraction — which is `nil` when the server sends no `Content-Length`. In
that case ``StockfishNetworkLoader/Progress/totalBytes`` is
``StockfishNetworkLoader/Progress/unknownTotalBytes`` (`-1`) and you can fall
back to ``StockfishNetworkLoader/Progress/bytesDownloaded``.

```swift
try await StockfishNetworkLoader().ensure(in: dir) { p in
    if let fraction = p.fractionCompleted {
        print(p.file, Int(fraction * 100), "%")
    } else {
        print(p.file, p.bytesDownloaded, "bytes")   // unknown total
    }
}
```

## Sources

The loader tries two endpoints, in order, per file — see
``StockfishNetworkLoader/Source``:

- ``StockfishNetworkLoader/Source/fishtest`` — the Stockfish fishtest API,
  `https://tests.stockfishchess.org/api/nn/<filename>`.
- ``StockfishNetworkLoader/Source/githubNetworks`` — the official networks repo
  raw files,
  `https://raw.githubusercontent.com/official-stockfish/networks/master/<filename>`.

fishtest is tried first, GitHub as a fallback.

## Errors

A failed `ensure` throws a ``StockfishNetworkLoader/LoaderError``:

- ``StockfishNetworkLoader/LoaderError/checksumMismatch(_:)`` — a download's
  SHA-256 prefix did not match its filename.
- ``StockfishNetworkLoader/LoaderError/allSourcesFailed(_:)`` — every source
  failed for a file.
- ``StockfishNetworkLoader/LoaderError/invalidNetworkName(_:)`` — a filename does
  not follow the `nn-<hex>.nnue` scheme, so it cannot be verified.
- ``StockfishNetworkLoader/LoaderError/fileSystem(_:)`` — a filesystem operation
  failed.

## Upgrading Stockfish (e.g. 18 → 18.1)

When the engine binary is bumped, update the manifest and the loader handles the
rest:

1. Bump ``StockfishNetworks/stockfishVersion``.
2. Update ``StockfishNetworks/required`` with the new version's net filenames
   (copy them verbatim from the engine's `evaluate.h` — `EvalFileDefaultNameBig`
   / `EvalFileDefaultNameSmall`).

On the next ``StockfishNetworkLoader/ensure(in:progress:)``, the loader downloads
the new nets and **prunes the old ones**, so a directory that held the 18 nets
becomes a directory holding exactly the 18.1 nets with no manual cleanup.

## Cross-platform crypto

The checksum verification uses CryptoKit on Apple and swift-crypto on non-Apple
hosts — the same `SHA256` API. The dependency is pulled in only on non-Apple
builds (or a forced source build), so the Apple dependency graph is unchanged.

## Next steps

- <doc:UsageExamples> — copy-paste recipes that wire the loader to the engine.
- <doc:GettingStarted> — add the package and start an engine.
