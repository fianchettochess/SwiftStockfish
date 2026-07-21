# Getting Started

Prepare the NNUE networks, start an engine, and exchange UCI.

## 1. Prepare the NNUE networks

The evaluation networks are large binaries that are **not** embedded in the engine
(`StockfishConfig.h` sets `NNUE_EMBEDDING_OFF`); the engine loads them from disk at
startup and **exits the process** if they're missing. `StockfishNetworkLoader`
ensures a directory holds exactly the required networks.

Choose one of two delivery models:

=== "(a) Runtime download"

    Call `ensure(in:)` at startup into a writable directory, show progress, then
    create the engine. Subsequent launches find valid nets and `ensure` is a fast
    checksum-only no-op.

    ```swift
    import Foundation
    import SwiftStockfish

    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("stockfish-nets")
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
    let dir = Bundle.main.resourceURL!.appendingPathComponent("stockfish-nets")
    ```

In **both** models the rule is the same: a valid net directory must be ready
*before* the engine is created.

## 2. Start the engine

`StockfishEngine.init(networkDirectory:)` is failable — it returns `nil` if the
required NNUE nets are missing or invalid in `networkDirectory` (run the loader
first) or if the bridge could not start its engine thread (resource exhaustion).

```swift
guard let engine = StockfishEngine(networkDirectory: dir) else {
    fatalError("engine failed to start")
}
```

## 3. Exchange UCI

Read replies from `engine.output` (an `AsyncStream<String>` of UCI lines,
newline-stripped, in order) and write commands with `engine.send(_:)`. The
convenience wrappers are `uci()`, `isReady()`, and `quit()`; every other command
(`position`, `go`, `stop`, `setoption`) is sent as a raw `send(_:)`.

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

## API summary

```swift
public final class StockfishEngine: @unchecked Sendable {
    public init?(networkDirectory: URL)
    public var output: AsyncStream<String> { get }
    public func send(_ command: String)
    public func shutdown()          // explicit teardown — joins threads, releases the gate
    public func uci()
    public func isReady()
    public func quit()              // sends the UCI "quit" command only
}
```

## See also

- [Setup & NNUE loader](concepts/setup.md) — the loader in depth.
- [Driving the engine](concepts/driving-the-engine.md) — a complete analysis flow.
- [Platform support](concepts/platform-support.md) — the platform and SIMD matrix.
