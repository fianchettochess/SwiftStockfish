//
//  TransportSpy.swift
//  SwiftStockfishTests
//
//  Shared test-support for suites that inject a `StockfishNetworkLoader.Transport`
//  (the loader's hermetic download seam — see the seam note on the typealias).
//

import Foundation

/// Thread-safe record of every call an injected transport receives: the
/// source URL asked for and the staging URL the loader handed it.
final class TransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []
    private var _stagingURLs: [URL] = []

    func record(url: URL, stagingURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        _requestedURLs.append(url)
        _stagingURLs.append(stagingURL)
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedURLs
    }

    var stagingURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _stagingURLs
    }
}
