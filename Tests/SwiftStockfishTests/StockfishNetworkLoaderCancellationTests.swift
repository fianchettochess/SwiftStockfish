//
//  StockfishNetworkLoaderCancellationTests.swift
//  SwiftStockfishTests
//
//  Hermetic tests for the download-cancellation machinery
//  (StockfishDownloadTaskBox + withTaskCancellationHandler wiring in
//  StockfishNetworkLoader). NOTHING here touches the real network: the loader
//  is built over a URLSession whose configuration routes every request through
//  `StubbedNetProtocol`, an in-process URLProtocol that either hangs (so a
//  cancel can land mid-flight) or serves canned bytes.
//
//  Contracts under test (the "Harden Stockfish network loading" semantics):
//    - Cancellation before the download path is reached: no request is ever
//      issued and no staging file appears.
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
import Crypto
#endif
@testable import SwiftStockfish

/// In-process URLProtocol stub. Static state is process-global, so the suite
/// below is `.serialized`; the protocol is registered per-session (via
/// `protocolClasses`), never globally, so other suites are unaffected.
final class StubbedNetProtocol: URLProtocol {
    enum Behavior {
        /// Never respond. A task cancel surfaces as NSURLErrorCancelled.
        case hang
        /// Respond with the given body and status code, then finish.
        case respond(Data, statusCode: Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _behavior: Behavior = .hang
    nonisolated(unsafe) private static var _requestedURLs: [URL] = []

    static func reset(behavior: Behavior) {
        lock.lock()
        defer { lock.unlock() }
        _behavior = behavior
        _requestedURLs = []
    }

    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedURLs
    }

    private static func recordAndGetBehavior(_ url: URL?) -> Behavior {
        lock.lock()
        defer { lock.unlock() }
        if let url { _requestedURLs.append(url) }
        return _behavior
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.recordAndGetBehavior(request.url) {
        case .hang:
            break
        case .respond(let data, let statusCode):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url, statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Length": "\(data.count)"]
                  )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite("StockfishNetworkLoader cancellation (hermetic)", .serialized)
struct StockfishNetworkLoaderCancellationTests {

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedNetProtocol.self]
        return URLSession(configuration: config)
    }

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

    @Test("a pre-cancelled ensure throws CancellationError before any request or staging file")
    func preCancelledEnsureNeverTouchesNetworkOrDisk() async throws {
        StubbedNetProtocol.reset(behavior: .hang)
        let dir = makeTempDir()
        defer { remove(dir) }
        let loader = StockfishNetworkLoader(networks: [absentNet], session: makeStubbedSession())

        let task = Task {
            // Deterministic ordering: enter `ensure` only after cancellation
            // has landed, so the first Task.checkCancellation() must throw.
            while !Task.isCancelled { await Task.yield() }
            try await loader.ensure(in: dir)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubbedNetProtocol.requestedURLs.isEmpty,
                "no download may be issued after cancellation")
        #expect(partFiles(in: dir).isEmpty, "no staging file may be left behind")
    }

    @Test("cancelling mid-download throws CancellationError, leaves no staging file, and never advances to the fallback source")
    func cancelDuringDownloadCleansUpAndSkipsFallback() async throws {
        StubbedNetProtocol.reset(behavior: .hang)
        let dir = makeTempDir()
        defer { remove(dir) }
        let net = absentNet
        let loader = StockfishNetworkLoader(networks: [net], session: makeStubbedSession())

        let task = Task { try await loader.ensure(in: dir) }

        // Wait until the first (fishtest) request is genuinely in flight.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while StubbedNetProtocol.requestedURLs.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(StubbedNetProtocol.requestedURLs.count == 1, "the download should be in flight")

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubbedNetProtocol.requestedURLs.count == 1,
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

        StubbedNetProtocol.reset(behavior: .respond(content, statusCode: 200))
        let dir = makeTempDir()
        defer { remove(dir) }
        let loader = StockfishNetworkLoader(networks: [net], session: makeStubbedSession())

        try await loader.ensure(in: dir)

        let installed = dir.appendingPathComponent(net.filename)
        #expect(try Data(contentsOf: installed) == content, "the verified bytes must be installed")
        #expect(partFiles(in: dir).isEmpty, "the .part staging file must be removed after install")
        #expect(StubbedNetProtocol.requestedURLs.count == 1,
                "a first-source success must not touch the fallback")
    }
}
