# Usage Examples

Worked examples for driving the engine. Every snippet uses only the public
SwiftStockfish API.

## Overview

These examples rely on two requirements: the NNUE nets must be valid *before* the
engine is created, and only one ``StockfishEngine`` may be alive per process.
Each example reads from ``StockfishEngine/output`` and writes with
``StockfishEngine/send(_:)``.

## Full Setup: Loader to Engine to Handshake

Run ``StockfishNetworkLoader/ensure(in:progress:)`` first, create the engine with
``StockfishEngine/init(networkDirectory:)``, then complete the UCI handshake with
``StockfishEngine/uci()`` and ``StockfishEngine/isReady()``.

```swift
import SwiftStockfish

func startEngine() async throws -> StockfishEngine {
    let dir = URL.applicationSupportDirectory.appending(path: "stockfish-nets")

    // Nets first — Stockfish exits the process without them.
    try await StockfishNetworkLoader().ensure(in: dir) { p in
        print("\(p.file): \(p.fractionCompleted.map { "\(Int($0 * 100))%" } ?? "...")")
    }

    guard let engine = StockfishEngine(networkDirectory: dir) else {
        throw NSError(domain: "engine", code: 1)
    }

    // Handshake.
    engine.uci()
    for await line in engine.output {
        if line == "uciok" { engine.isReady() }
        if line == "readyok" { break }
    }
    return engine
}
```

> Important: ``StockfishEngine/init(networkDirectory:)`` is failable and the nets
> must already be valid in `dir`. If the directory is missing or holds an invalid
> net, Stockfish aborts the whole process — that is not a recoverable error.

## Best Move for a Position

Send the position, send `go`, and read until `bestmove`:

```swift
func bestMove(for fen: String, depth: Int, engine: StockfishEngine) async -> String? {
    engine.send("position fen \(fen)")
    engine.send("go depth \(depth)")
    for await line in engine.output {
        if line.hasPrefix("bestmove ") {
            return line.split(separator: " ").dropFirst().first.map(String.init)
        }
    }
    return nil
}

let move = await bestMove(
    for: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    depth: 20,
    engine: engine
)
```

## Stream a Live Evaluation

Parse `info` lines for an evaluation bar or depth indicator:

```swift
struct Eval { var depth = 0; var scoreCp: Int?; var mateIn: Int?; var pv: [String] = [] }

func parseInfo(_ line: String) -> Eval? {
    guard line.hasPrefix("info "), line.contains(" pv ") else { return nil }
    var eval = Eval()
    let tokens = line.split(separator: " ").map(String.init)
    var i = 0
    while i < tokens.count {
        switch tokens[i] {
        case "depth": eval.depth = Int(tokens[i + 1]) ?? 0; i += 2
        case "score":
            if tokens[i + 1] == "cp"   { eval.scoreCp = Int(tokens[i + 2]) }
            if tokens[i + 1] == "mate" { eval.mateIn  = Int(tokens[i + 2]) }
            i += 3
        case "pv":
            eval.pv = Array(tokens[(i + 1)...]); i = tokens.count
        default: i += 1
        }
    }
    return eval
}

engine.send("position startpos")
engine.send("go depth 22")
for await line in engine.output {
    if let eval = parseInfo(line) {
        print("d\(eval.depth)", eval.scoreCp.map { "\($0)cp" } ?? "mate \(eval.mateIn ?? 0)")
    }
    if line.hasPrefix("bestmove ") { break }
}
```

## Top Candidate Moves (MultiPV)

Set `MultiPV` before searching. Each depth then emits one `info … multipv N …`
line per candidate:

```swift
engine.send("setoption name MultiPV value 3")
engine.send("position fen \(fen)")
engine.send("go depth 18")

var lines: [Int: String] = [:]      // multipv index -> first pv move
for await line in engine.output {
    if line.hasPrefix("info "), let idxRange = line.range(of: "multipv ") {
        let after = line[idxRange.upperBound...]
        let idx = Int(after.prefix { $0.isNumber }) ?? 0
        if let pvRange = line.range(of: " pv ") {
            let first = line[pvRange.upperBound...].split(separator: " ").first.map(String.init)
            lines[idx] = first
        }
    }
    if line.hasPrefix("bestmove ") { break }
}
print(lines)   // [1: "e2e4", 2: "d2d4", 3: "g1f3"]
```

## Play with a Clock

`go` accepts the standard UCI time controls, all via ``StockfishEngine/send(_:)``:

```swift
engine.send("position startpos moves e2e4 e7e5 g1f3")
engine.send("go wtime 120000 btime 118000 winc 2000 binc 2000")
// Read until "bestmove …" as above.
```

## Bundle the Nets at Build Time

There are two consumption models. The runtime model downloads on first launch
with ``StockfishNetworkLoader/ensure(in:progress:)`` (shown above). The
build-time model runs the loader once during development and ships the resulting
`nn-*.nnue` files as app resources, so the device needs no network access.

### Option A: Runtime Download

Call ``StockfishNetworkLoader/ensure(in:progress:)`` into a writable directory at
startup, as in the full-setup example. Subsequent launches find valid nets, and
`ensure` is a fast checksum-only no-op.

### Option B: Bundle at Build Time

A one-off command-line tool downloads the nets so they can be shipped as app
resources:

```swift
import SwiftStockfish

@main struct FetchNets {
    static func main() async throws {
        let out = URL(filePath: CommandLine.arguments[1])
        try await StockfishNetworkLoader().ensure(in: out) { p in
            print(p.file, p.bytesDownloaded)
        }
        print("nets ready in \(out.path)")
    }
}
```

At runtime, point the engine at the bundled directory instead of a downloaded
one:

```swift
let dir = Bundle.main.resourceURL!.appending(path: "stockfish-nets")
guard let engine = StockfishEngine(networkDirectory: dir) else { return }
```

## Tear Down

``StockfishEngine/quit()`` asks the UCI loop to exit. Teardown also happens
automatically when the last reference is released.

```swift
engine.quit()      // ask the UCI loop to exit; teardown also happens on release
```

> Warning: **One engine per process.** Fully tear one ``StockfishEngine`` down
> before creating another — the bridge swaps the process-global stream buffers,
> so a second live engine clobbers the first's redirection.

## See Also

- <doc:DrivingTheEngine> — the handshake and search controls in detail.
- <doc:NetworkSetup> — how the loader prepares the nets.
