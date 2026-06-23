//
//  StockfishEngine.swift
//  SwiftStockfish
//
//  A clean Swift wrapper over the C bridge in CStockfish. The bridge drives
//  Stockfish's UCI loop on a background thread and delivers each output line
//  via a C callback; this class turns that into an `AsyncStream<String>` and
//  exposes a `send(_:)` for UCI commands.
//

import Foundation
import CStockfish

/// A live Stockfish engine instance.
///
/// You talk to it in UCI: send commands with ``send(_:)`` and read replies from
/// the ``output`` stream. The convenience methods ``uci()``, ``isReady()`` and
/// ``quit()`` send the obvious commands.
///
/// - Important: The caller MUST ensure the required NNUE networks already exist
///   in `networkDirectory` BEFORE creating the engine. Stockfish loads its
///   evaluation net during initialization and calls `exit(EXIT_FAILURE)` if the
///   net is missing or invalid — which would terminate the entire host process,
///   not just throw. Run ``StockfishNetworkLoader/ensure(in:progress:)`` first.
///
/// - Important: Only ONE `StockfishEngine` may be alive in a process at a time.
///   The bridge swaps the process-global `std::cin`/`std::cout` stream buffers
///   so Stockfish talks to in-process pipes; a second instance's swap clobbers
///   the first's. Create, use, and destroy one engine before making another.
public final class StockfishEngine: @unchecked Sendable {

    // `SFEngineRef` is `const void *`; in Swift it surfaces as an opaque
    // pointer. Treated as immutable after init, so the class is safe to share.
    private let engine: SFEngineRef

    // The output stream and its continuation. The continuation is fed from the
    // C callback (which may fire on the bridge's reader thread), so all access
    // goes through `AsyncStream.Continuation`, which is itself Sendable / thread
    // safe.
    private let _output: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    /// An async stream of UCI output lines from the engine, in order.
    ///
    /// Lines are delivered without their trailing newline. The stream is
    /// unbounded-buffered; iterate it promptly if you care about back-pressure.
    /// It finishes when the engine is destroyed (``deinit`` / ``quit()`` →
    /// teardown).
    public var output: AsyncStream<String> { _output }

    /// Create and start an engine.
    ///
    /// - Parameter networkDirectory: A directory that already contains the
    ///   required `nn-*.nnue` networks (see ``StockfishNetworks/required``).
    ///   The bridge passes this to Stockfish as its binary directory so the
    ///   engine resolves the nets from here.
    ///
    /// - Returns: `nil` if the bridge could not start the engine (e.g. it
    ///   failed to create its pipes).
    public init?(networkDirectory: URL) {
        var continuation: AsyncStream<String>.Continuation!
        self._output = AsyncStream(bufferingPolicy: .unbounded) { cont in
            continuation = cont
        }
        self.continuation = continuation

        guard let ref = networkDirectory.path.withCString({ sf_create($0) }) else {
            // No engine was created, so finish the (empty) stream.
            continuation.finish()
            return nil
        }
        self.engine = ref

        // Bridge `self` into the C callback's `void *context` via an unretained
        // pointer. `self` outlives the bridge: `deinit` stops the bridge's
        // threads (sf_destroy joins them) before `self` is deallocated, so the
        // callback never fires against a freed object.
        let context = Unmanaged.passUnretained(self).toOpaque()
        sf_set_output_callback(engine, { linePtr, ctx in
            guard let linePtr, let ctx else { return }
            let line = String(cString: linePtr)
            let me = Unmanaged<StockfishEngine>.fromOpaque(ctx).takeUnretainedValue()
            me.continuation.yield(line)
        }, context)
    }

    deinit {
        // sf_destroy sends "quit", joins the engine + reader threads, and frees
        // the bridge. After it returns no further callbacks can fire.
        sf_destroy(engine)
        continuation.finish()
    }

    /// Send a raw UCI command (no trailing newline needed).
    public func send(_ command: String) {
        command.withCString { sf_send_command(engine, $0) }
    }

    // MARK: - Convenience

    /// Send `uci`. The engine replies with its `id`/`option` lines and `uciok`.
    public func uci() { send("uci") }

    /// Send `isready`. The engine replies `readyok` once it has finished any
    /// pending initialization.
    public func isReady() { send("isready") }

    /// Send `quit`, asking the engine's UCI loop to exit. Teardown also happens
    /// automatically in ``deinit``; call this if you want to wind the engine
    /// down before the object is released.
    public func quit() { send("quit") }
}
