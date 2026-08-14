//
//  StockfishNetworkLoaderTests.swift
//  SwiftStockfishTests
//
//  Tests for the loader's prune / verify logic, run entirely OFFLINE.
//
//  Two tricks keep these off the network. Most tests use a SYNTHETIC network
//  whose filename encodes the real SHA-256 prefix of a fixture we write to
//  disk — the loader sees that net as already-present-and-valid, so
//  `ensure(in:)` never reaches its download path. The one test that DOES need
//  the download path injects a failing `Transport` (the loader's hermetic
//  download seam), so no request can escape to the real network.
//

import Testing
import Foundation
// SHA-256 for the synthetic-net hashing assertion: CryptoKit on Apple,
// swift-crypto's `Crypto` (same `SHA256` API) on non-Apple. See Package.swift.
#if canImport(CryptoKit)
import CryptoKit
#else
// 18.0.16: swift-crypto was dropped; non-Apple uses the vendored SHA256
// (SHA256.swift), which needs no module import -- mirror the loader.
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
    // loader's verify step, which then drops it and tries to (re)download. The
    // injected transport fails every attempt the way an unreachable network
    // would, so the loader must try BOTH sources for the corrupt net and then
    // throw `allSourcesFailed` — without ever reaching the second, absent net.
    // (Before the loader grew its Transport seam, this test used the real
    // `URLSession` and leaned on the live sources 404-ing synthetic filenames —
    // a real-network round trip inside the "offline" suite. The seam makes the
    // failure hermetic and lets us assert the source try-count exactly.)
    @Test("a corrupt present net forces the download path; when every source fails, ensure throws")
    func corruptAndAbsentNetsThrow() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }
        let fm = FileManager.default

        // 1) A present-but-corrupt copy of the synthetic net: right filename,
        //    WRONG bytes → fails verification → loader wants to re-download it.
        let corrupt = Self.syntheticNet
        let corruptURL = dir.appendingPathComponent(corrupt.filename)
        try Data("these-are-not-the-right-bytes".utf8).write(to: corruptURL)

        // 2) An absent net whose 12-hex prefix is all zeros: a well-formed name
        //    (so it passes the shaPrefix guard) that no real file can ever hash
        //    to. The loader must throw on the corrupt net before reaching it.
        let absent = StockfishNetworks.Network(filename: "nn-000000000000.nnue")

        // A transport that fails like a host with no usable network.
        let spy = TransportSpy()
        let transport: StockfishNetworkLoader.Transport = { url, stagingURL in
            spy.record(url: url, stagingURL: stagingURL)
            throw URLError(.notConnectedToInternet)
        }

        let loader = StockfishNetworkLoader(networks: [corrupt, absent], transport: transport)
        await #expect(throws: StockfishNetworkLoader.LoaderError.self) {
            try await loader.ensure(in: dir)
        }

        // Both sources were tried for the corrupt net, and the throw happened
        // before the absent net's download could start.
        #expect(spy.requestedURLs == [
            StockfishNetworkLoader.Source.fishtest.url(for: corrupt.filename),
            StockfishNetworkLoader.Source.githubNetworks.url(for: corrupt.filename),
        ])
        // The corrupt file was dropped ahead of the re-download, not kept.
        #expect(!fm.fileExists(atPath: corruptURL.path),
                "a corrupt net must be removed before re-fetching")
    }

    // MARK: - Custom-manifest validation

    @Test("rejects a later traversal entry before pruning, path use, or transport")
    func rejectsLaterTraversalEntryBeforeAnyMutation() async throws {
        let root = makeTempDir()
        defer { remove(root) }
        let dir = root.appendingPathComponent("nets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let valid = Self.syntheticNet
        let validURL = dir.appendingPathComponent(valid.filename)
        try Self.syntheticContent.write(to: validURL)

        let stale = dir.appendingPathComponent("nn-deadbeefcafe.nnue")
        let staleBytes = Data("must survive failed manifest validation".utf8)
        try staleBytes.write(to: stale)

        let maliciousName = "nn-a/../../outside.nnue"
        let outside = root.appendingPathComponent("outside.nnue")
        let sentinel = Data("do not delete".utf8)
        try sentinel.write(to: outside)

        let spy = TransportSpy()
        let loader = StockfishNetworkLoader(
            networks: [valid, .init(filename: maliciousName)],
            transport: { url, stagingURL in
                spy.record(url: url, stagingURL: stagingURL)
                throw URLError(.notConnectedToInternet)
            }
        )

        do {
            try await loader.ensure(in: dir)
            Issue.record("a traversal filename must be rejected")
        } catch StockfishNetworkLoader.LoaderError.invalidNetworkName(let filename) {
            #expect(filename == maliciousName)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(spy.requestedURLs.isEmpty)
        #expect(try Data(contentsOf: validURL) == Self.syntheticContent)
        #expect(try Data(contentsOf: stale) == staleBytes,
                "a bad later entry must be found before the prune pass")
        #expect(try Data(contentsOf: outside) == sentinel,
                "validation must happen before any caller-derived path is removed")
    }

    @Test("rejects a malformed full digest before mutating an existing net")
    func rejectsMalformedFullDigestBeforeFilesystemUse() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }

        let filename = Self.syntheticNet.filename
        let malformedDigest = Self.syntheticPrefix + String(repeating: "0", count: 51)
        let net = StockfishNetworks.Network(filename: filename, sha256: malformedDigest)
        let existing = dir.appendingPathComponent(filename)
        try Self.syntheticContent.write(to: existing)

        let spy = TransportSpy()
        let loader = StockfishNetworkLoader(
            networks: [net],
            transport: { url, stagingURL in
                spy.record(url: url, stagingURL: stagingURL)
                throw URLError(.notConnectedToInternet)
            }
        )

        do {
            try await loader.ensure(in: dir)
            Issue.record("a malformed full digest must be rejected")
        } catch StockfishNetworkLoader.LoaderError.checksumMismatch(let filename) {
            #expect(filename == net.filename)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(spy.requestedURLs.isEmpty)
        #expect(try Data(contentsOf: existing) == Self.syntheticContent)
    }

    @Test("rejects a full digest whose prefix disagrees with its filename")
    func rejectsFullDigestWithMismatchedFilenamePrefix() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }

        let net = StockfishNetworks.Network(
            filename: Self.syntheticNet.filename,
            sha256: String(repeating: "0", count: 64)
        )
        let existing = dir.appendingPathComponent(net.filename)
        try Self.syntheticContent.write(to: existing)

        let spy = TransportSpy()
        let loader = StockfishNetworkLoader(
            networks: [net],
            transport: { url, stagingURL in
                spy.record(url: url, stagingURL: stagingURL)
                throw URLError(.notConnectedToInternet)
            }
        )

        do {
            try await loader.ensure(in: dir)
            Issue.record("a digest inconsistent with its filename must be rejected")
        } catch StockfishNetworkLoader.LoaderError.checksumMismatch(let filename) {
            #expect(filename == net.filename)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(spy.requestedURLs.isEmpty)
        #expect(try Data(contentsOf: existing) == Self.syntheticContent)
    }

    @Test("rejects duplicate filenames before mutating the directory")
    func rejectsDuplicateFilenamesBeforeAnyMutation() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }

        let existing = dir.appendingPathComponent(Self.syntheticNet.filename)
        try Self.syntheticContent.write(to: existing)
        let stale = dir.appendingPathComponent("nn-deadbeefcafe.nnue")
        let staleBytes = Data("must survive duplicate-manifest rejection".utf8)
        try staleBytes.write(to: stale)

        let spy = TransportSpy()
        let loader = StockfishNetworkLoader(
            networks: [Self.syntheticNet, Self.syntheticNet],
            transport: { url, stagingURL in
                spy.record(url: url, stagingURL: stagingURL)
                throw URLError(.notConnectedToInternet)
            }
        )

        do {
            try await loader.ensure(in: dir)
            Issue.record("a duplicate filename must be rejected")
        } catch StockfishNetworkLoader.LoaderError.checksumMismatch(let filename) {
            #expect(filename == Self.syntheticNet.filename)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(spy.requestedURLs.isEmpty)
        #expect(try Data(contentsOf: existing) == Self.syntheticContent)
        #expect(try Data(contentsOf: stale) == staleBytes)
        #expect(!loader.requiredNetworksSatisfied(in: dir))
    }

    @Test("a matching filename prefix cannot bypass a mismatched full digest")
    func fullDigestTakesPrecedenceOverFilenamePrefix() async throws {
        let dir = makeTempDir()
        defer { remove(dir) }

        let wrongFullDigest = Self.syntheticPrefix + String(repeating: "0", count: 52)
        let net = StockfishNetworks.Network(
            filename: Self.syntheticNet.filename,
            sha256: wrongFullDigest
        )
        let existing = dir.appendingPathComponent(net.filename)
        try Self.syntheticContent.write(to: existing)

        let spy = TransportSpy()
        let loader = StockfishNetworkLoader(
            networks: [net],
            transport: { url, stagingURL in
                spy.record(url: url, stagingURL: stagingURL)
                throw URLError(.notConnectedToInternet)
            }
        )

        await #expect(throws: StockfishNetworkLoader.LoaderError.self) {
            try await loader.ensure(in: dir)
        }
        #expect(spy.requestedURLs == [
            StockfishNetworkLoader.Source.fishtest.url(for: net.filename),
            StockfishNetworkLoader.Source.githubNetworks.url(for: net.filename),
        ])
        #expect(!FileManager.default.fileExists(atPath: existing.path),
                "prefix-only validity must not override a supplied full digest")
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
