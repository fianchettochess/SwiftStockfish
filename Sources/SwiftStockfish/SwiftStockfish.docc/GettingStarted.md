# Getting Started

Add the package, prepare the NNUE networks, and start an engine.

## Overview

SwiftStockfish is a Swift Package Manager dependency. The high-level
``SwiftStockfish`` product is the one most consumers want; a lower-level
`CStockfish` product exposes the raw C bridge if you'd rather manage the engine
lifecycle yourself.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/jaredbrewer/SwiftStockfish", from: "18.0.0"),
],
targets: [
    .target(
        name: "MyChessApp",
        dependencies: [
            .product(name: "SwiftStockfish", package: "SwiftStockfish"),
        ]
    ),
]
```

> Important: This package links Stockfish and is therefore a **GPL-3.0** work.
> Consuming it carries GPL-3.0 obligations on your application. Treat
> SwiftStockfish as the separately-distributable GPL component.

## Prepare the NNUE networks

The evaluation networks are large binaries that are *not* embedded in the engine
— it loads them from disk at startup, and exits the process if they're missing.
``StockfishNetworkLoader`` makes a directory hold exactly the right nets.

There are two consumption models; pick one:

**(a) Runtime — download on first launch.** Call ``StockfishNetworkLoader/ensure(in:progress:)``
into a writable directory at startup, show progress, then create the engine.
Subsequent launches find valid nets and `ensure` is a fast checksum-only no-op.

```swift
import SwiftStockfish

let dir = URL.applicationSupportDirectory.appending(path: "stockfish-nets")
try await StockfishNetworkLoader().ensure(in: dir) { progress in
    if let fraction = progress.fractionCompleted {
        print(progress.file, Int(fraction * 100), "%")
    }
}
```

**(b) Build/setup time — bundle for an offline app.** Run the loader once on your
machine (a build step), then ship the resulting `nn-*.nnue` files as bundled app
resources and point the engine at the bundle directory. No network access is
needed on the user's device.

```swift
// At runtime, with the nets already in your app bundle:
let dir = Bundle.main.resourceURL!.appending(path: "stockfish-nets")
```

In **both** models the rule is the same: the loader (or a known-good bundled
directory) must be ready *before* the engine is created.

## Start the engine

``StockfishEngine/init(networkDirectory:)`` is failable — it returns `nil` if the
bridge couldn't start (for example, it failed to create its pipes).

```swift
guard let engine = StockfishEngine(networkDirectory: dir) else {
    fatalError("engine failed to start")
}
```

## Talk UCI

You read from ``StockfishEngine/output`` (an `AsyncStream<String>` of UCI lines,
newline-stripped, in order) and write with ``StockfishEngine/send(_:)``. The only
convenience wrappers are ``StockfishEngine/uci()``,
``StockfishEngine/isReady()``, and ``StockfishEngine/quit()``; everything else
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

## Next steps

- <doc:DrivingTheEngine> — a complete analyze-a-position flow and option setup.
- <doc:PlatformSupport> — the platform/SIMD matrix and Android cross-compiling.
