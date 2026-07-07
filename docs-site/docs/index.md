# SwiftStockfish

A Swift Package Manager wrapper around the [Stockfish](https://stockfishchess.org)
chess engine: a clean `StockfishEngine` UCI API plus a version-aware NNUE network
manager.

On **Apple** platforms the engine links a prebuilt, multi-arch
`Stockfish.xcframework`; on **Linux** and **Android** the same Stockfish source is
compiled from source. Either way a small C++ bridge drives Stockfish's UCI loop
over an in-process queue, and the Swift surface is identical on every platform.

- Wraps **Stockfish source version 18** (`StockfishNetworks.stockfishVersion`).
- **GPL-3.0** — this package ships and links Stockfish, so the whole package is a
  GPL-3.0 work (see [Licensing](#licensing)).

## Components

| Type | Role |
|---|---|
| `StockfishEngine` | a live engine you talk to in UCI — `send(_:)` commands, read the `output` `AsyncStream` |
| `StockfishNetworkLoader` | downloads, verifies (SHA-256), and prunes the NNUE evaluation networks |

## Requirements

!!! danger "Run the loader before creating the engine"
    Stockfish loads its NNUE network during initialization and calls
    `exit(EXIT_FAILURE)` if the net is missing or invalid — that terminates the
    **entire host process**, not a catchable Swift error. Always `await`
    `StockfishNetworkLoader.ensure(in:)` into the engine's network directory
    first.

!!! danger "One engine per process"
    The bridge enforces the single-instance rule with a lifecycle gate: creating a
    second `StockfishEngine(...)` **blocks the calling thread** until the first is
    fully torn down. Never create or tear down an engine on the main thread/actor —
    the create can block and `shutdown()` joins threads. Always `shutdown()` or
    release the first engine before creating another; a leaked engine hangs the next
    create forever.

## Quick start

```swift
import SwiftStockfish

// 1. Ensure the NNUE nets exist BEFORE the engine is created.
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

## See Also

- [Installation](installation.md)
- [Getting Started](getting-started.md)
- [Setup & NNUE loader](concepts/setup.md)
- [Driving the engine](concepts/driving-the-engine.md)
- [Platform support](concepts/platform-support.md)
- [Usage Examples](examples.md)

## Licensing

Stockfish is licensed under the **GNU General Public License, version 3**. This
package ships Stockfish and links it into its output, so the entire SwiftStockfish
package is a GPL-3.0 work and is distributed under GPL-3.0. If you consume this
package in an application, that linkage carries GPL-3.0 obligations — treat
SwiftStockfish as the separately-distributable GPL component.
