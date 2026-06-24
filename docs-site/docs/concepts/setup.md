# Setup & the NNUE Loader

The NNUE networks are large binaries the engine loads from disk at startup.
`StockfishNetworkLoader` makes a directory hold **exactly** the right nets — and
it must finish before the engine is created.

!!! danger "Order matters"
    Stockfish exits the host process (`exit(EXIT_FAILURE)`) on a missing or invalid
    net. Always `await` `ensure(in:)` (or point the engine at a known-good bundled
    directory) **before** `StockfishEngine(networkDirectory:)`.

## The manifest

`StockfishNetworks` is the single source of truth for which nets the bundled
engine needs.

```swift
public enum StockfishNetworks {
    public static let stockfishVersion: String        // "18"
    public static let required: [Network]             // the big + small nets

    public struct Network: Sendable, Equatable, Hashable {
        public let filename: String                   // "nn-c288c895ea92.nnue"
        public init(filename: String)
        public var shaPrefix: String                  // the 12-hex SHA-256 prefix
    }
}
```

Stockfish 18 uses **two** nets — a "big" net (main evaluation) and a "small" net
(faster, lower-accuracy path); both must be present. The 12-hex prefix in each
filename is the net's own SHA-256 prefix, which the loader verifies.

## The loader

```swift
public struct StockfishNetworkLoader: Sendable {
    public let networks: [StockfishNetworks.Network]
    public init(networks: [StockfishNetworks.Network] = StockfishNetworks.required)

    public func ensure(
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws
}
```

`ensure(in:)`:

1. ensures the directory exists;
2. **prunes** any `nn-*.nnue` not in the required set (so upgrading from one
   Stockfish version's nets to another's leaves no leftovers);
3. for each required net, keeps it if present and SHA-valid, otherwise downloads
   it (fishtest first, then the official GitHub networks repo), verifies the
   checksum, and atomically moves it into place.

It is **idempotent** — a present, valid net is never re-downloaded, so a warm
launch is a fast checksum-only no-op.

## Progress

The optional `progress` closure receives one `Progress` value per in-flight
download:

```swift
public struct Progress: Sendable {
    public let file: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64                 // -1 (unknownTotalBytes) if no Content-Length
    public static let unknownTotalBytes: Int64   // -1
    public var fractionCompleted: Double?         // nil when total is unknown
}
```

```swift
try await StockfishNetworkLoader().ensure(in: dir) { p in
    if let f = p.fractionCompleted {
        print(p.file, Int(f * 100), "%")
    } else {
        print(p.file, p.bytesDownloaded, "bytes")   // unknown total
    }
}
```

## Sources

The loader tries two endpoints, in order, per file:

```swift
public enum Source: Sendable, CaseIterable {
    case fishtest          // https://tests.stockfishchess.org/api/nn/<filename>
    case githubNetworks    // https://raw.githubusercontent.com/official-stockfish/networks/master/<filename>
}
```

## Errors

```swift
public enum LoaderError: Error, Sendable {
    case checksumMismatch(String)    // a download's SHA prefix didn't match its filename
    case allSourcesFailed(String)    // every source failed for a file
    case invalidNetworkName(String)  // filename isn't nn-<hex>.nnue
    case fileSystem(String)          // a filesystem operation failed
}
```

## Upgrading Stockfish (e.g. 18 → 18.1)

When the engine binary is bumped, update the manifest and the loader handles the
rest:

1. Bump `StockfishNetworks.stockfishVersion`.
2. Update `StockfishNetworks.required` with the new version's net filenames (copy
   them verbatim from the engine's `evaluate.h` — `EvalFileDefaultNameBig` /
   `EvalFileDefaultNameSmall`).

On the next `ensure(in:)`, the loader downloads the new nets and **prunes the old
ones**, so a directory that held the 18 nets becomes a directory holding exactly
the 18.1 nets with no manual cleanup.

## Cross-platform crypto

The checksum verification uses CryptoKit on Apple and swift-crypto on non-Apple
hosts — the same `SHA256` API. The dependency is pulled in only on non-Apple
builds (or a forced source build), so the Apple dependency graph is unchanged.
