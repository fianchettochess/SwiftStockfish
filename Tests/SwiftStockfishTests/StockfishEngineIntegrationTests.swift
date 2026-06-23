//
//  StockfishEngineIntegrationTests.swift
//  SwiftStockfishTests
//
//  Real-engine UCI integration, GATED behind SWIFTSTOCKFISH_INTEGRATION so it
//  stays OUT of a plain `swift test` — it downloads the real ~107 MB nets and
//  spins up a live engine. Run it explicitly with:
//
//      SWIFTSTOCKFISH_INTEGRATION=1 swift test
//
//  This suite still COMPILES on every build (so it can't bit-rot), it just
//  doesn't EXECUTE unless the env var is set.
//
//  CRITICAL ordering: the nets must be downloaded BEFORE `StockfishEngine` is
//  created. Stockfish loads its evaluation net during init and calls
//  `exit(EXIT_FAILURE)` on a missing/invalid net — that would kill the whole
//  test process, not fail one test. So `ensure(in:)` always runs first.
//

import Testing
import Foundation
@testable import SwiftStockfish

@Suite(
    "StockfishEngine UCI integration (gated)",
    .enabled(if: ProcessInfo.processInfo.environment["SWIFTSTOCKFISH_INTEGRATION"] != nil)
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Download the REAL nets first — before creating the engine.
        try await StockfishNetworkLoader().ensure(in: dir)

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
}
