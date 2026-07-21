# Getting Started

Add the package, prepare the NNUE networks, and start an engine.

## Overview

SwiftStockfish is a Swift Package Manager dependency. The high-level
``SwiftStockfish`` product is the recommended entry point for most applications.
A lower-level `CStockfish` product exposes the raw C bridge for callers that need
to manage the engine lifecycle directly.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/fianchettochess/SwiftStockfish", from: "18.0.9"),
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

> Note: The optimized Apple x86_64 binary requires AVX2/BMI2 (Haswell-class or
> newer), while arm64/arm64_32 builds require ARM FEAT_DotProd. Neither path has
> a runtime baseline fallback, and the watchOS archive does not include armv7k.

## Prepare the NNUE networks

The evaluation networks are large binaries that are *not* embedded in the engine.
The engine loads them from disk at startup and exits the process if they are
missing. ``StockfishNetworkLoader`` populates a directory with the exact networks
the engine requires.

There are two consumption models. Choose the one that fits your application:

**(a) Runtime — download on first launch.** Call ``StockfishNetworkLoader/ensure(in:progress:)``
into a writable directory at startup, report progress, then create the engine.
Subsequent launches find valid networks, and `ensure` becomes a fast,
checksum-only no-op.

```swift
import SwiftStockfish

let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stockfish-nets")
try await StockfishNetworkLoader().ensure(in: dir) { progress in
    if let fraction = progress.fractionCompleted {
        print(progress.file, Int(fraction * 100), "%")
    }
}
```

**(b) Build/setup time — bundle for an offline app.** Run the loader once as a
build step, then ship the resulting `nn-*.nnue` files as bundled app resources
and point the engine at the bundle directory. No network access is required on
the user's device.

```swift
// At runtime, with the nets already in your app bundle:
let dir = Bundle.main.resourceURL!.appendingPathComponent("stockfish-nets")
```

In **both** models the same requirement applies: the loader, or a known-good
bundled directory, must be ready *before* the engine is created.

## Start the engine

``StockfishEngine/init(networkDirectory:)`` is failable. It returns `nil` if the
required NNUE nets are missing or invalid in `networkDirectory` (run the loader
first) or if the bridge could not start its engine thread (resource exhaustion).

```swift
guard let engine = StockfishEngine(networkDirectory: dir) else {
    fatalError("engine failed to start")
}
```

## Communicate over UCI

Read from ``StockfishEngine/output`` (an `AsyncStream<String>` of UCI lines,
newline-stripped, in order) and write with ``StockfishEngine/send(_:)``. The
convenience wrappers are ``StockfishEngine/uci()``,
``StockfishEngine/isReady()``, and ``StockfishEngine/quit()``; every other
command (`position`, `go`, `stop`, `setoption`) is issued as a raw `send(_:)`.

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

## See Also

- <doc:DrivingTheEngine> — a complete analyze-a-position flow and option setup.
- <doc:PlatformSupport> — the platform and SIMD matrix and Android cross-compiling.
