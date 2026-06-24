# ``SwiftStockfish``

A Swift Package Manager wrapper around the Stockfish chess engine: a clean
`StockfishEngine` UCI API plus a version-aware NNUE network manager.

## Overview

`SwiftStockfish` drives the [Stockfish](https://stockfishchess.org) engine from
Swift. On **Apple** platforms the engine links a prebuilt, multi-arch
`Stockfish.xcframework`; on **Linux** and **Android** the same Stockfish source is
compiled from source. Either way a small C++ bridge runs Stockfish's UCI loop
over an in-process queue, and the Swift surface is identical on every platform.

This package wraps **Stockfish source version 18** and ships under **GPL-3.0**
(because it links Stockfish). It exposes two pieces:

- ``StockfishEngine`` — a live engine you talk to in UCI: send commands with
  ``StockfishEngine/send(_:)`` and read replies from the
  ``StockfishEngine/output`` `AsyncStream`.
- ``StockfishNetworkLoader`` — downloads, verifies (SHA-256), and prunes the NNUE
  evaluation networks listed in ``StockfishNetworks/required``.

### Two rules you must follow

> Warning: **Run the loader before creating the engine.** Stockfish loads its
> NNUE network during initialization and calls `exit(EXIT_FAILURE)` if the net is
> missing or invalid — that terminates the *entire host process*, not a catchable
> Swift error. Always `await` ``StockfishNetworkLoader/ensure(in:progress:)`` into
> the engine's network directory first.

> Warning: **One engine per process.** The bridge swaps the process-global
> `std::cin` / `std::cout` stream buffers so Stockfish talks to in-process pipes.
> A second live ``StockfishEngine`` clobbers the first's redirection. Create, use,
> and destroy one engine before making another.

### Quick start

```swift
import SwiftStockfish

// 1. Ensure the NNUE nets exist BEFORE the engine is created.
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

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:DrivingTheEngine>
- <doc:NetworkSetup>
- <doc:UsageExamples>
- <doc:PlatformSupport>

### The engine

- ``StockfishEngine``

### NNUE networks

- ``StockfishNetworkLoader``
- ``StockfishNetworks``
