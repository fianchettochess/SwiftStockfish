# Driving the Engine

A complete flow covering the handshake, option configuration, single-position
analysis, and reading results from the UCI stream.

## Overview

``StockfishEngine`` is a thin UCI transport. You drive it with the standard UCI
command sequence and parse its replies from the ``StockfishEngine/output``
stream. This article covers a full single-position analysis and the lifecycle
rules that keep the process healthy.

## The UCI handshake

After creating the engine, complete the handshake before sending positions:

1. Send `uci` (``StockfishEngine/uci()``); wait for `uciok`.
2. Optionally set options with `setoption name … value …`.
3. Send `isready` (``StockfishEngine/isReady()``); wait for `readyok`.

```swift
import SwiftStockfish

func handshake(_ engine: StockfishEngine) async {
    for await line in engine.output {
        switch line {
        case "uciok":
            engine.send("setoption name Threads value 4")
            engine.send("setoption name Hash value 256")
            engine.isReady()
        case "readyok":
            return                 // ready for positions + go
        default:
            break
        }
    }
}

engine.uci()
await handshake(engine)
```

## Analyze a position to a fixed depth

Set the position (FEN or `startpos`, optionally with `moves`), then `go`. Collect
`info` lines for the live evaluation and stop at `bestmove`:

```swift
func bestMove(for fen: String, depth: Int, engine: StockfishEngine) async -> String? {
    engine.send("position fen \(fen)")
    engine.send("go depth \(depth)")

    for await line in engine.output {
        if line.hasPrefix("info ") {
            // info depth 20 score cp 31 ... pv e2e4 e7e5 g1f3 ...
            // Parse depth / score / pv here if you want a live eval bar.
        }
        if line.hasPrefix("bestmove ") {
            // "bestmove e2e4 ponder e7e5"
            return line
                .split(separator: " ")
                .dropFirst()
                .first
                .map(String.init)
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

> Tip: When the FEN comes from your own board state, sanitize it first. If you
> use [ChessCore](https://github.com/fianchettochess/ChessCore) (a private sibling
> package; the link may not resolve for external readers), send
> `position.stockfishSafeFEN` — Stockfish's parser asserts on inconsistent
> metadata and will abort the process otherwise.

## Search controls

`go` accepts the standard UCI limits, all via ``StockfishEngine/send(_:)``:

```swift
engine.send("go depth 20")                    // fixed depth
engine.send("go nodes 1000000")               // fixed node count
engine.send("go movetime 2000")               // 2 seconds
engine.send("go wtime 60000 btime 60000 winc 1000 binc 1000")  // a real clock
engine.send("stop")                           // interrupt; a bestmove still comes
```

For multiple candidate lines, set MultiPV before searching:

```swift
engine.send("setoption name MultiPV value 3")
engine.send("position startpos")
engine.send("go depth 18")
// Each depth now emits three `info … multipv 1|2|3 … pv …` lines.
```

## Lifecycle

A single output loop should own the stream for the engine's whole life. When
you're done, ``StockfishEngine/quit()`` asks the UCI loop to exit; teardown also
happens automatically in `deinit` (which sends `quit`, joins the engine and
reader threads, and finishes the `output` stream).

```swift
engine.quit()
// Releasing the last reference tears the bridge down; no further output arrives.
```

Two rules are mandatory: **one engine per process**, and **the NNUE nets must be
valid before the engine is created**. Both are process-fatal if violated, not
recoverable Swift errors.

## The low-level C bridge

To manage the engine directly, depend on the `CStockfish` product and call the
bridge yourself. It exposes a small `extern "C"` surface:

```c
SFEngineRef sf_create(const char *nnueDir);
void        sf_set_output_callback(SFEngineRef engine, SFOutputCallback cb, const void *ctx);
void        sf_send_command(SFEngineRef engine, const char *command);
void        sf_destroy(SFEngineRef engine);
```

``StockfishEngine`` is a thin Swift layer over exactly these four functions,
handling the callback and stream bridging on your behalf.
