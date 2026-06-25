# Driving the Engine

`StockfishEngine` is a thin UCI transport. Drive it with the standard UCI command
sequence and parse its replies from the `output` stream.

## The transport

```swift
public final class StockfishEngine: @unchecked Sendable {
    public init?(networkDirectory: URL)        // failable; nil on bridge/pipe failure
    public var output: AsyncStream<String>     // UCI lines, newline-stripped, in order
    public func send(_ command: String)        // any raw UCI command
    public func uci()                          // sends "uci"
    public func isReady()                      // sends "isready"
    public func quit()                         // sends "quit"
}
```

`output` is unbounded-buffered, so iterate it promptly to manage
back-pressure. It finishes when the engine is torn down.

## The UCI handshake

After creating the engine, complete the handshake before sending positions:

1. send `uci` (`uci()`); wait for `uciok`
2. optionally set options with `setoption name … value …`
3. send `isready` (`isReady()`); wait for `readyok`

```swift
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
        }
        if line.hasPrefix("bestmove ") {
            // "bestmove e2e4 ponder e7e5"
            return line.split(separator: " ").dropFirst().first.map(String.init)
        }
    }
    return nil
}
```

!!! tip "Sanitize FENs from your own board"
    Stockfish's parser asserts on inconsistent metadata and **aborts the process**.
    If you build FENs from your own state, sanitize them first — with
    [ChessCore](https://github.com/jaredbrewer/ChessCore), send
    `position.stockfishSafeFEN`.

## Search controls

All via `send(_:)`:

```swift
engine.send("go depth 20")                                    // fixed depth
engine.send("go nodes 1000000")                               // fixed nodes
engine.send("go movetime 2000")                               // 2 seconds
engine.send("go wtime 60000 btime 60000 winc 1000 binc 1000") // a real clock
engine.send("stop")                                          // interrupt; a bestmove still arrives
```

For multiple candidate lines, set MultiPV before searching:

```swift
engine.send("setoption name MultiPV value 3")
engine.send("position startpos")
engine.send("go depth 18")
// Each depth now emits three `info … multipv 1|2|3 … pv …` lines.
```

## Lifecycle

A single output loop should own the stream for the engine's entire lifetime.
Calling `quit()` asks the UCI loop to exit; teardown also happens
automatically when the last reference is released (the `deinit` sends `quit`, joins
the engine and reader threads, and finishes `output`).

```swift
engine.quit()
```

Two constraints are mandatory: **one engine per process** and
**valid nets before creation**. Violating either is process-fatal.

## The low-level C bridge

To manage the engine directly, depend on the `CStockfish` product and
call the bridge yourself. It exposes a small `extern "C"` surface:

```c
typedef const void *SFEngineRef;
typedef void (*SFOutputCallback)(const char *line, const void *context);

SFEngineRef sf_create(const char *nnueDir);
void        sf_set_output_callback(SFEngineRef engine, SFOutputCallback cb, const void *ctx);
void        sf_send_command(SFEngineRef engine, const char *command);
void        sf_destroy(SFEngineRef engine);
```

`StockfishEngine` is a thin Swift layer over exactly these four functions,
handling the callback-to-stream bridging on your behalf.
