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

### Requirements

> Warning: **Run the loader before creating the engine.** Stockfish verifies its
> NNUE nets on the first `go`/`ucinewgame` and calls `exit(EXIT_FAILURE)` if one
> is missing or invalid — terminating the *entire host process*, not a catchable
> Swift error. ``StockfishEngine/init(networkDirectory:)`` pre-flights the nets
> and returns `nil` instead of letting that happen, but the pre-flight can only
> pass if the directory is already correct — so always `await`
> ``StockfishNetworkLoader/ensure(in:progress:)`` into the engine's network
> directory first. Raw `CStockfish` consumers get no pre-flight.

> Warning: **One engine per process.** The bridge enforces the single-instance
> rule with a lifecycle gate: creating a second ``StockfishEngine`` blocks the
> calling thread until the first is fully torn down. Create and tear down engines
> off the main thread/actor, and always shut one engine down before creating
> another — a leaked engine hangs the next create forever.

### Example

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
