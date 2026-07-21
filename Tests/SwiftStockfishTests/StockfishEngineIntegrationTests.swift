//
//  StockfishEngineIntegrationTests.swift
//  SwiftStockfishTests
//
//  Real-engine UCI integration, GATED behind SWIFTSTOCKFISH_INTEGRATION so it
//  stays OUT of a plain `swift test` — its first live run downloads the real
//  ~107 MB nets and spins up a live engine. Later runs reuse the versioned
//  cache after the loader verifies both nets' full SHA-256 digests. Run it with:
//
//      SWIFTSTOCKFISH_INTEGRATION=1 swift test
//
//  This suite still COMPILES on every build (so it can't bit-rot), it just
//  doesn't EXECUTE unless the env var is set.
//
//  CRITICAL ordering: the shared net fixture must be prepared BEFORE
//  `StockfishEngine` is created. Stockfish loads its evaluation net during init
//  and calls `exit(EXIT_FAILURE)` on a missing/invalid net — that would kill the
//  whole test process, not fail one test. So `ensure(in:)` always runs first.
//

import Testing
import Foundation
@testable import SwiftStockfish

/// One persistent, hash-verified NNUE fixture for the entire live test process.
///
/// A manifest-derived directory keeps different Stockfish/network revisions
/// isolated. `ensure(in:)` still validates the full pinned SHA-256 of every
/// cached file before either test creates an engine.
private enum SharedNNUEFixture {
    static let directory: Task<URL, any Error> = Task {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let manifestKey = StockfishNetworks.required
            .map(\.shaPrefix)
            .joined(separator: "-")
        let directory = cacheRoot
            .appendingPathComponent(
                "SwiftStockfishIntegrationTests",
                isDirectory: true
            )
            .appendingPathComponent(
                "Stockfish-\(StockfishNetworks.stockfishVersion)-\(manifestKey)",
                isDirectory: true
            )

        try await StockfishNetworkLoader().ensure(in: directory)
        return directory
    }
}

@Suite(
    "StockfishEngine UCI integration (gated)",
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTSTOCKFISH_INTEGRATION"] == "1"),
    .serialized
)
struct StockfishEngineIntegrationTests {

    /// Read lines from the engine's `output` stream until `predicate` is met,
    /// giving up after `timeout` seconds. Returns the matching line.
    private func waitForLine(
        from engine: StockfishEngine,
        timeout: TimeInterval = 120,
        where predicate: @escaping @Sendable (String) -> Bool
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for await line in engine.output where predicate(line) {
                    return line
                }
                return nil  // stream finished without a match
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil  // timed out
            }

            defer { group.cancelAll() }
            for try await result in group {
                if let line = result { return line }
                // A nil from either task means "no match yet"; the first task to
                // finish wins. If the matcher returned nil the stream ended; if
                // the timer fired we timed out. Either way, no line.
                break
            }
            throw IntegrationError.timedOut
        }
    }

    private enum IntegrationError: Error { case timedOut, engineCreationFailed }

    @Test("drives a real engine through uci → isready → go depth 1 → bestmove")
    func drivesRealEngineOverUCI() async throws {
        // 1. Prepare/reuse the REAL nets before creating the engine.
        let dir = try await SharedNNUEFixture.directory.value

        // 2. Create the live engine.
        guard let engine = StockfishEngine(networkDirectory: dir) else {
            throw IntegrationError.engineCreationFailed
        }
        defer { engine.quit() }

        // 3. uci → uciok.
        engine.uci()
        let uciok = try await waitForLine(from: engine) { $0 == "uciok" }
        #expect(uciok == "uciok")

        // 4. isready → readyok.
        engine.isReady()
        let readyok = try await waitForLine(from: engine) { $0 == "readyok" }
        #expect(readyok == "readyok")

        // 5. position startpos + go depth 1 → a bestmove line.
        engine.send("position startpos")
        engine.send("go depth 1")
        let bestmove = try await waitForLine(from: engine) { $0.hasPrefix("bestmove") }
        #expect(bestmove.hasPrefix("bestmove"))
    }

    @Test("shutdown is idempotent; send after shutdown is a safe no-op")
    func shutdownIsIdempotentAndGuardsSend() async throws {
        let dir = try await SharedNNUEFixture.directory.value

        guard let engine = StockfishEngine(networkDirectory: dir) else {
            throw IntegrationError.engineCreationFailed
        }
        engine.uci()
        _ = try await waitForLine(from: engine) { $0 == "uciok" }

        engine.shutdown()
        engine.shutdown()           // second call must be a no-op, not a double sf_destroy
        engine.send("isready")      // must not touch the freed bridge

        // The output stream finishes on shutdown — iterating it must reach the
        // stream's END (buffered pre-shutdown lines may drain first) rather
        // than hanging or delivering lines indefinitely. Race a full drain
        // against a timeout: a shutdown regression that leaves the stream open
        // makes the timer win and the assertion fail.
        let streamEnded = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in engine.output {}
                return true   // reached the stream's end
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false  // 10 s and the stream still hadn't finished
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(streamEnded, "engine.output must finish after shutdown()")
    }
}
