import Foundation
import Testing
@testable import SwiftStockfish

@Suite("VerifiedNetwork cache")
struct VerifiedNetworkCacheTests {
    /// GATES: a match is not memoized when the file changes during hashing.
    /// HOW IT COULD BREAK: the post-hash identity check is removed.
    /// WHAT THE USER LOSES: later preflight could accept a corrupt network.
    @Test("a changed file is not remembered under its previous identity")
    func changedDuringHashIsNotMemoized() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("network")
        let original = Data("verified network".utf8)
        var damaged = original
        damaged[0] ^= 1
        try original.write(to: url)
        let stamp = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let digest = sha256Hex(original)
        let cache = StockfishNetworkLoader.VerifiedNetworkCache(hash: { file, full, prefix in
            let matched = StockfishNetworkLoader.VerifiedNetworkCache.fileMatches(file, full, prefix)
            if matched { try? (original + Data([0])).write(to: file) }
            return matched
        })

        let identity = try #require(StockfishNetworkLoader.VerifiedNetworkCache.identity(for: url, expecting: digest))
        #expect(cache.fileMatches(url, expectedFull: digest, expectedPrefix: ""))
        #expect(try Data(contentsOf: url) == original + Data([0]))
        #expect(!cache.isVerified(identity))
        // Restore the old size and timestamp with different bytes. A stale entry
        // would accept this file without checking its digest.
        try damaged.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        #expect(StockfishNetworkLoader.VerifiedNetworkCache.identity(for: url, expecting: digest) == identity)
        #expect(!cache.fileMatches(url, expectedFull: digest, expectedPrefix: ""))
    }
}
