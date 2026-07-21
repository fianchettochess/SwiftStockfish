# Usage Examples

The following examples demonstrate how to drive the engine. Every snippet uses
only the public Swift API.

## Setup: loader, engine, and handshake

```swift
import Foundation
import SwiftStockfish

func startEngine() async throws -> StockfishEngine {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("stockfish-nets")

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

## Best move for a position

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

## Stream a live evaluation

Parse `info` lines to drive an evaluation bar or depth indicator:

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

## Top-3 candidate moves (MultiPV)

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

## Play with a real clock

```swift
engine.send("position startpos moves e2e4 e7e5 g1f3")
engine.send("go wtime 120000 btime 118000 winc 2000 binc 2000")
// Read until "bestmove …" as above.
```

## Bundle the nets at build time

The following script downloads the networks so they can be shipped as application
resources, avoiding any runtime network access:

```swift
import Foundation
import SwiftStockfish

@main struct FetchNets {
    static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try await StockfishNetworkLoader().ensure(in: out) { p in
            print(p.file, p.bytesDownloaded)
        }
        print("nets ready in \(out.path)")
    }
}
```

## Tear down

Call `shutdown()` from a background context to explicitly destroy the engine — it
joins the engine and reader threads, frees the bridge, and releases the process-wide
lifecycle gate:

```swift
// From a background Task or off-main context — never from the main actor.
engine.shutdown()
// or: let all references to `engine` go out of scope (deinit calls shutdown()).
```

`quit()` only sends the UCI `quit` string to the engine's input. It does **not** join
threads, free the bridge, or release the lifecycle gate. Using `quit()` alone as
teardown keeps the gate held and causes the next `StockfishEngine(...)` to block
indefinitely.

Only **one engine per process** is supported. The bridge enforces this with a
lifecycle gate: creating a second engine **blocks the calling thread** until the first
is fully torn down. Create and tear down engines off the main thread/actor, and always
`shutdown()` or release the first engine before creating another.
