//
//  StockfishNetworkLoaderTests.swift
//  SwiftStockfishTests
//
//  Tests for the loader's prune / verify logic, run entirely OFFLINE.
//
//  The trick that keeps these off the network: a SYNTHETIC network whose
//  filename encodes the real SHA-256 prefix of a fixture we write to disk. The
//  loader then sees that net as already-present-and-valid, so `ensure(in:)`
//  never reaches its download path. If it DID try to download, the test would
//  hit the network (the whole thing we're avoiding) — so each test asserts an
//  outcome that's only reachable on the no-download path.
//

import Testing
import Foundation
// SHA-256 for the synthetic-net hashing assertion: CryptoKit on Apple,
// swift-crypto's `Crypto` (same `SHA256` API) on non-Apple. See Package.swift.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SwiftStockfish

@Suite("StockfishNetworkLoader (offline)")
struct StockfishNetworkLoaderTests {

    // MARK: - Synthetic-net fixture

    /// Bytes whose SHA-256 prefix we encode into a `nn-<prefix>.nnue` filename
    /// so the loader treats the file as valid without any download.
    private static let syntheticContent = Data("swiftstockfish-synthetic-net".utf8)

    /// The 12-hex SHA-256 prefix of `syntheticContent`.
    private static var syntheticPrefix: String {
        let hex = SHA256.hash(data: syntheticContent)
            .map { String(format: "%02x", $0) }
            .joined()
        return String(hex.prefix(12))
    }

    /// A network whose filename matches `syntheticContent`'s real SHA prefix.
    private static var syntheticNet: StockfishNetworks.Network {
        StockfishNetworks.Network(filename: "nn-\(syntheticPrefix).nnue")
    }

    // MARK: - Temp-dir helper

    /// A fresh, unique temp directory per call. Caller cleans it up.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Keep present+valid, prune stale, leave non-nets alone

    @Test("keeps a present+valid net, prunes stale nn-*.nnue, leaves non-nets")
    func keepsValidPrunesStaleLeavesOthers() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }
        let fm = FileManager.default

        let net = Self.syntheticNet
        let validURL = dir.appendingPathComponent(net.filename)
        let staleURL = dir.appendingPathComponent("nn-deadbeefcafe.nnue")
        let notesURL = dir.appendingPathComponent("notes.txt")

        // The valid net (its bytes hash to the prefix in its filename).
        try Self.syntheticContent.write(to: validURL)
        // A stale net from a "previous version" — any bytes; the loader prunes
        // by name, not content.
        try Data("stale".utf8).write(to: staleURL)
        // A non-net file that pruning must never touch.
        try Data("keep me".utf8).write(to: notesURL)

        // Only one required net, and it's present+valid → no download attempted.
        try await StockfishNetworkLoader(networks: [net]).ensure(in: dir)

        #expect(fm.fileExists(atPath: validURL.path), "the valid net should be kept")
        #expect(!fm.fileExists(atPath: staleURL.path), "the stale nn-*.nnue should be pruned")
        #expect(fm.fileExists(atPath: notesURL.path), "the non-net file should be untouched")

        // The kept net's bytes are undisturbed.
        let kept = try Data(contentsOf: validURL)
        #expect(kept == Self.syntheticContent)
    }

    // MARK: - Orphaned staging files

    // downloadToTemp stages in-flight bytes at `.<net>.<UUID>.part` inside the
    // nets directory; the only in-process cleanup is the caller's `defer`. A
    // crash/kill during the verify/install window (which includes SHA-256
    // hashing the ~100 MB big net) orphans that hidden file. The prune pass
    // must reclaim such orphans — they are ~100 MB each and nothing else ever
    // deletes them. Any `.part` present when `ensure` starts is from a dead
    // run: live staging files only exist during a download, and downloads
    // start strictly after pruning within the same `ensure` call.
    @Test("prunes orphaned .part staging files left by a crashed download")
    func prunesOrphanedStagingFiles() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }
        let fm = FileManager.default

        let net = Self.syntheticNet
        let validURL = dir.appendingPathComponent(net.filename)
        try Self.syntheticContent.write(to: validURL)

        // An orphan staged exactly the way downloadToTemp names its staging
        // file — for the required net AND for a previous version's net (both
        // shapes must be reclaimed; neither can be a live download here).
        let orphanRequired = dir.appendingPathComponent(
            ".\(net.filename).\(UUID().uuidString).part"
        )
        let orphanStale = dir.appendingPathComponent(
            ".nn-deadbeefcafe.nnue.\(UUID().uuidString).part"
        )
        try Data("half-downloaded".utf8).write(to: orphanRequired)
        try Data("half-downloaded".utf8).write(to: orphanStale)

        // An unrelated hidden file that pruning must never touch.
        let hiddenBystander = dir.appendingPathComponent(".unrelated-hidden")
        try Data("keep me".utf8).write(to: hiddenBystander)

        // The required net is present+valid → no download attempted.
        try await StockfishNetworkLoader(networks: [net]).ensure(in: dir)

        #expect(!fm.fileExists(atPath: orphanRequired.path),
                "orphaned .part staging file for the required net should be pruned")
        #expect(!fm.fileExists(atPath: orphanStale.path),
                "orphaned .part staging file for a stale net should be pruned")
        #expect(fm.fileExists(atPath: hiddenBystander.path),
                "unrelated hidden files must be untouched")
        #expect(fm.fileExists(atPath: validURL.path), "the valid net should be kept")
    }

    // MARK: - Idempotency

    @Test("ensure is idempotent: a second call leaves the valid net in place")
    func ensureIsIdempotent() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }
        let fm = FileManager.default

        let net = Self.syntheticNet
        let validURL = dir.appendingPathComponent(net.filename)
        try Self.syntheticContent.write(to: validURL)

        let loader = StockfishNetworkLoader(networks: [net])
        try await loader.ensure(in: dir)
        try await loader.ensure(in: dir)  // second call must not disturb it

        #expect(fm.fileExists(atPath: validURL.path))
        let kept = try Data(contentsOf: validURL)
        #expect(kept == Self.syntheticContent)
    }

    // MARK: - Corrupt / missing nets force the (failing) download path

    // Why this test EXPECTS an error: a required net that's present-but-corrupt
    // (its bytes don't match its filename's SHA prefix) is rejected by the
    // loader's verify step, which then drops it and tries to (re)download. With
    // no usable network — a CI/sandbox has none — every Source fails, so
    // `ensure` throws. We deliberately include a SECOND required net that is
    // simply ABSENT, which independently guarantees the download path is taken:
    // even if the host running this test happens to have a network, the absent
    // net's filename (`nn-000…000.nnue`) hashes to nothing real, so its
    // download/verify can never succeed and `ensure` still throws. Either way
    // the assertion — "a net that can't be made valid offline makes ensure
    // throw" — holds without depending on network reachability.
    @Test("a corrupt present net plus an unfetchable absent net make ensure throw")
    func corruptAndAbsentNetsThrow() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }

        // 1) A present-but-corrupt copy of the synthetic net: right filename,
        //    WRONG bytes → fails verification → loader wants to re-download it.
        let corrupt = Self.syntheticNet
        let corruptURL = dir.appendingPathComponent(corrupt.filename)
        try Data("these-are-not-the-right-bytes".utf8).write(to: corruptURL)

        // 2) An absent net whose 12-hex prefix is all zeros: a well-formed name
        //    (so it passes the shaPrefix guard) that no real file can ever hash
        //    to. Its download/verify can never succeed, so `ensure` must throw
        //    regardless of whether the host has a network at all.
        let absent = StockfishNetworks.Network(filename: "nn-000000000000.nnue")

        let loader = StockfishNetworkLoader(networks: [corrupt, absent])
        await #expect(throws: (any Error).self) {
            try await loader.ensure(in: dir)
        }
    }

    // MARK: - Progress.fractionCompleted (pure struct logic, no IO)

    @Test("fractionCompleted is nil when the total is unknown")
    func fractionIsNilForUnknownTotal() {
        let p = StockfishNetworkLoader.Progress(
            file: "nn-x.nnue",
            bytesDownloaded: 0,
            totalBytes: StockfishNetworkLoader.Progress.unknownTotalBytes
        )
        #expect(p.fractionCompleted == nil)
    }

    @Test("fractionCompleted is a sane fraction when the total is known")
    func fractionIsSaneForKnownTotal() {
        let half = StockfishNetworkLoader.Progress(
            file: "nn-x.nnue", bytesDownloaded: 50, totalBytes: 100
        )
        #expect(half.fractionCompleted == 0.5)

        // Clamped to 1.0 even if the byte count overshoots the reported total.
        let over = StockfishNetworkLoader.Progress(
            file: "nn-x.nnue", bytesDownloaded: 150, totalBytes: 100
        )
        #expect(over.fractionCompleted == 1.0)

        // A zero total is treated as unknown (guard `totalBytes > 0`).
        let zero = StockfishNetworkLoader.Progress(
            file: "nn-x.nnue", bytesDownloaded: 0, totalBytes: 0
        )
        #expect(zero.fractionCompleted == nil)
    }
}
