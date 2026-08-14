//
//  StockfishNetworkLoaderCancellationTests.swift
//  SwiftStockfishTests
//
//  Hermetic tests for the download-cancellation machinery and the staged-copy
//  happy path in StockfishNetworkLoader. NOTHING here touches the real
//  network: the loader is built over an injected `Transport` closure (the
//  loader's internal test seam) that either parks until cancelled or writes
//  canned bytes to the staging file.
//
//  Why a transport seam and not a stub URLProtocol: these tests originally
//  injected a URLSession whose configuration routed through a custom
//  `URLProtocol`. That is hermetic on Darwin, but swift-corelibs-foundation
//  does not reliably honor custom URLProtocol subclasses for download tasks —
//  on Linux the stub's served bytes never materialize as a downloaded file, so
//  the request escapes to the REAL network and fails (-1011 badServerResponse
//  from the sources' 404s). The transport seam is in-process on every platform.
//
//  Contracts under test (the "Harden Stockfish network loading" semantics):
//    - Cancellation before the download path is reached: the transport is
//      never invoked and no staging file appears.
//    - Cancellation mid-download: `ensure` throws CancellationError, never
//      advances to the fallback source, and leaves no `.part` staging file.
//    - The staged-copy happy path: a (stubbed) successful download is staged,
//      verified, installed, and its `.part` staging file removed.
//

import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
// 18.0.16: swift-crypto was dropped; non-Apple uses the vendored SHA256
// (SHA256.swift), which needs no module import -- mirror the loader.
#endif
@testable import SwiftStockfish

@Suite("StockfishNetworkLoader cancellation (hermetic)")
struct StockfishNetworkLoaderCancellationTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Every `.part` staging file in `dir` (hidden files included).
    private func partFiles(in dir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasSuffix(".part") }
    }

    /// A well-formed net name (passes the shaPrefix guard) that no bytes can
    /// hash to, forcing `ensure` down the download path.
    private var absentNet: StockfishNetworks.Network {
        StockfishNetworks.Network(filename: "nn-000000000000.nnue")
    }

    /// A transport that records the call, then parks until the surrounding
    /// task is cancelled — `Task.sleep` then throws CancellationError, exactly
    /// as the production URLSession transport reports a cancelled transfer.
    /// It never writes to the staging URL, like a transfer whose bytes never
    /// finished arriving.
    private func parkingTransport(spy: TransportSpy) -> StockfishNetworkLoader.Transport {
        { url, stagingURL in
            spy.record(url: url, stagingURL: stagingURL)
            // Park (~1 hour). Reaching the sleep's end means a test hung for
            // an hour without cancelling — fail loudly rather than pretend.
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            Issue.record("parking transport was never cancelled")
            throw URLError(.badServerResponse)
        }
    }

    @Test("a pre-cancelled ensure throws CancellationError before any transport call or staging file")
    func preCancelledEnsureNeverTouchesTransportOrDisk() async throws {
        let spy = TransportSpy()
        let dir = makeTempDir()
        defer { remove(dir) }
        let loader = StockfishNetworkLoader(
            networks: [absentNet], transport: parkingTransport(spy: spy)
        )

        let task = Task {
            // Deterministic ordering: enter `ensure` only after cancellation
            // has landed, so the first Task.checkCancellation() must throw.
            while !Task.isCancelled { await Task.yield() }
            try await loader.ensure(in: dir)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(spy.requestedURLs.isEmpty,
                "no download may be started after cancellation")
        #expect(partFiles(in: dir).isEmpty, "no staging file may be left behind")
    }

    @Test("cancelling mid-download throws CancellationError, leaves no staging file, and never advances to the fallback source")
    func cancelDuringDownloadCleansUpAndSkipsFallback() async throws {
        let spy = TransportSpy()
        let dir = makeTempDir()
        defer { remove(dir) }
        let net = absentNet
        let loader = StockfishNetworkLoader(
            networks: [net], transport: parkingTransport(spy: spy)
        )

        let task = Task { try await loader.ensure(in: dir) }

        // Wait until the first (fishtest) download is genuinely in flight.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while spy.requestedURLs.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(spy.requestedURLs.count == 1, "the download should be in flight")

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(spy.requestedURLs == [StockfishNetworkLoader.Source.fishtest.url(for: net.filename)],
                "cancellation must not advance to the fallback source")
        #expect(partFiles(in: dir).isEmpty, "no staging file may be left behind")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(net.filename).path),
                "a cancelled download must not install a net")
    }

    @Test("a stubbed successful download stages, verifies, installs, and removes the .part staging file")
    func successfulDownloadInstallsAndCleansStaging() async throws {
        let content = Data("swiftstockfish-hermetic-download-fixture".utf8)
        let prefix12 = String(
            SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined().prefix(12)
        )
        let net = StockfishNetworks.Network(filename: "nn-\(prefix12).nnue")

        let spy = TransportSpy()
        let dir = makeTempDir()
        defer { remove(dir) }
        // A transport that "downloads" by writing the fixture bytes to the
        // loader's staging URL and reporting a 200 — the success contract of
        // the production URLSession transport, minus the network.
        let transport: StockfishNetworkLoader.Transport = { url, stagingURL in
            spy.record(url: url, stagingURL: stagingURL)
            try content.write(to: stagingURL)
            guard let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(content.count)"]
            ) else { throw URLError(.badServerResponse) }
            return response
        }
        let loader = StockfishNetworkLoader(networks: [net], transport: transport)

        try await loader.ensure(in: dir)

        // Staged: the loader handed the transport a hidden `.part` staging
        // path inside the nets directory, named for this net.
        #expect(spy.stagingURLs.count == 1)
        if let staging = spy.stagingURLs.first {
            #expect(staging.deletingLastPathComponent().path == dir.path,
                    "staging must happen alongside the destination (same volume)")
            #expect(staging.lastPathComponent.hasPrefix(".\(net.filename)."),
                    "staging file must be the hidden .<net>.<UUID>.part scheme")
            #expect(staging.lastPathComponent.hasSuffix(".part"))
        }

        // Verified + installed: the exact fixture bytes (whose SHA-256 prefix
        // is the filename's) now live at the destination.
        let installed = dir.appendingPathComponent(net.filename)
        #expect(try Data(contentsOf: installed) == content, "the verified bytes must be installed")

        // Staging cleaned + no fallback: the `.part` is gone and only the
        // first source was ever asked.
        #expect(partFiles(in: dir).isEmpty, "the .part staging file must be removed after install")
        #expect(spy.requestedURLs == [StockfishNetworkLoader.Source.fishtest.url(for: net.filename)],
                "a first-source success must not touch the fallback")
    }
}
