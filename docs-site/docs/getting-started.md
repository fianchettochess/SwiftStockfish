# Getting Started

Prepare the NNUE networks, start an engine, and exchange UCI.

## 1. Prepare the NNUE networks

The evaluation networks are large binaries that are **not** embedded in the engine
(`StockfishConfig.h` sets `NNUE_EMBEDDING_OFF`); the engine loads them from disk at
startup and **exits the process** if they're missing. `StockfishNetworkLoader`
makes a directory hold exactly the right nets.

Pick one of two consumption models:

=== "(a) Runtime download"

    Call `ensure(in:)` at startup into a writable directory, show progress, then
    create the engine. Subsequent launches find valid nets and `ensure` is a fast
    checksum-only no-op.

    ```swift
    import SwiftStockfish

    let dir = URL.applicationSupportDirectory.appending(path: "stockfish-nets")
    try await StockfishNetworkLoader().ensure(in: dir) { progress in
        if let fraction = progress.fractionCompleted {
            print(progress.file, Int(fraction * 100), "%")
        }
    }
    ```

=== "(b) Bundle at build time"

    Run the loader once on your machine (a build step), then ship the resulting
    `nn-*.nnue` files as bundled app resources and point the engine at the bundle.
    No network access on the user's device.

    ```swift
    let dir = Bundle.main.resourceURL!.appending(path: "stockfish-nets")
    ```

In **both** models the rule is the same: a valid net directory must be ready
*before* the engine is created.

## 2. Start the engine

`StockfishEngine.init(networkDirectory:)` is failable — it returns `nil` if the
bridge couldn't start (e.g. it failed to create its pipes).

```swift
guard let engine = StockfishEngine(networkDirectory: dir) else {
    fatalError("engine failed to start")
}
```

## 3. Talk UCI

You read replies from `engine.output` (an `AsyncStream<String>` of UCI lines,
newline-stripped, in order) and write commands with `engine.send(_:)`. The only
convenience wrappers are `uci()`, `isReady()`, and `quit()`; everything else
(`position`, `go`, `stop`, `setoption`) is a raw `send(_:)`.

```swift
Task {
    for await line in engine.output {
        if line == "uciok"   { engine.isReady() }
        if line == "readyok" { engine.send("go depth 18") }
        if line.hasPrefix("bestmove ") {
            print("best:", line.dropFirst("bestmove ".count))
        }
    }
}
engine.uci()
engine.send("position startpos moves e2e4 e7e5")
```

## The API at a glance

```swift
public final class StockfishEngine: @unchecked Sendable {
    public init?(networkDirectory: URL)
    public var output: AsyncStream<String> { get }
    public func send(_ command: String)
    public func uci()
    public func isReady()
    public func quit()
}
```

## Next steps

- [Setup & NNUE loader](concepts/setup.md) — the loader in depth.
- [Driving the engine](concepts/driving-the-engine.md) — a full analysis flow.
- [Platform support](concepts/platform-support.md) — the platform/SIMD matrix.
