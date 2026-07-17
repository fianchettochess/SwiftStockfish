import Testing
import Foundation
import SwiftStockfish

/// C1 regression: a missing/invalid net must make `StockfishEngine.init?` fail
/// cleanly, NOT create an engine that later calls `exit(EXIT_FAILURE)` inside the
/// engine's `verify_networks()` and terminates the host process uncatchably.
/// These are offline (no engine is created — init? returns before `sf_create`).
@Suite("Engine net pre-flight (C1)")
struct StockfishEnginePreflightTests {

    private func makeEmptyDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("init? returns nil when the required nets are absent")
    func initNilOnMissingNets() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StockfishEngine(networkDirectory: dir) == nil)
    }

    @Test("The loader pre-flight rejects a directory missing the required nets")
    func loaderPreflightRejectsMissing() throws {
        let dir = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!StockfishNetworkLoader().requiredNetworksSatisfied(in: dir))
    }
}
