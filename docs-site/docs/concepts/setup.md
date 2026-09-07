# Setup & the NNUE Loader

The NNUE networks are large binaries the engine loads from disk at startup.
`StockfishNetworkLoader` ensures a directory holds **exactly** the required
networks, and it must complete before the engine is created.

!!! danger "Order matters"
    Stockfish verifies its nets on the first `go`/`ucinewgame` and exits the host
    process (`exit(EXIT_FAILURE)`) on a missing or invalid net — not a catchable
    Swift error. `StockfishEngine.init?` preflights the nets and returns `nil`
    instead of letting that happen, but the preflight can only pass if the
    directory is already correct — so always `await` `ensure(in:)` (or point the
    engine at a known-good bundled directory) **before**
    `StockfishEngine(networkDirectory:)`. Raw `CStockfish` consumers get no
    preflight.

## The manifest

`StockfishNetworks` is the single source of truth for which nets the bundled
engine needs.

```swift
public enum StockfishNetworks {
    public static let stockfishVersion: String        // "19"
    public static let required: [Network]             // every net sf_19 requires

    public struct Network: Sendable, Equatable, Hashable {
        public let filename: String                   // "nn-1a298aa575a0.nnue"
        public let sha256: String                     // the pinned full 64-hex SHA-256
        public init(filename: String, sha256: String = "")
        public var shaPrefix: String                  // the 12-hex SHA-256 prefix
    }
}
```

Stockfish 19 evaluates with a **single** network. (Through sf_18 there were
two: a "big" network for the main evaluation and a "small" one for a faster,
lower-accuracy path.) Every net in `required` must be present. Each net's FULL
SHA-256 is pinned alongside its filename, and the loader verifies the whole
digest after a download — the filename's 12-hex prefix is only a fallback for
fixtures without a pinned hash.

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
2. **prunes** any `nn-*.nnue` not in the required set, so upgrading from one
   Stockfish version's networks to another's leaves no stale files behind;
3. for each required network, keeps it if present and checksum-valid, otherwise
   downloads it (fishtest first, then the official GitHub networks repository),
   verifies the checksum, and atomically moves it into place.

The operation is **idempotent**: a present, valid network is never
re-downloaded, so a warm launch performs only a checksum verification.

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
    case githubNetworks    // https://media.githubusercontent.com/media/official-stockfish/networks/master/<filename>
}
```

## Errors

```swift
public enum LoaderError: Error, Sendable {
    case checksumMismatch(String)    // manifest metadata or bytes didn't match the pinned digest
    case allSourcesFailed(String)    // every source failed for a file
    case invalidNetworkName(String)  // filename isn't nn-<12 lowercase hex>.nnue
    case fileSystem(String)          // a filesystem operation failed
}
```

## Upgrading Stockfish (e.g. 19 → 19.1)

When the engine binary is updated, update the manifest and the loader handles the
rest:

1. Update `StockfishNetworks.stockfishVersion`.
2. Update `StockfishNetworks.required` with the new version's network filenames,
   copied verbatim from the engine's `evaluate.h` — `EvalFileDefaultName` as of
   sf_19, which replaced sf_18's `EvalFileDefaultNameBig` and
   `EvalFileDefaultNameSmall`.
3. Pin each new net's full SHA-256 in `StockfishNetworks.required`.

On the next `ensure(in:)`, the loader downloads the new networks and **prunes the
old ones**, so a directory that held the 19 networks becomes a directory holding
exactly the 19.1 networks with no manual cleanup. That is what carried existing
installs across 18 → 19: two nets pruned, one downloaded, no migration step.

## Cross-platform crypto

The checksum verification uses CryptoKit on Apple platforms and swift-crypto on
non-Apple hosts, through the same `SHA256` API. The swift-crypto dependency is
pulled in only on non-Apple builds (or a forced source build), so the Apple
dependency graph is unchanged.
