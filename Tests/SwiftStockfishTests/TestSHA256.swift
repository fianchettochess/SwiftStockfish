//===----------------------------------------------------------------------===//
// TestSHA256.swift — the test target's half of the loader's hashing seam.
//
// `StockfishNetworkLoader` already resolves this correctly: it imports CryptoKit
// only `#if canImport(CryptoKit)` and aliases `NetworkHasher` to either
// `CryptoKit.SHA256` or the vendored FIPS 180-4 `VendoredSHA256`. Its own
// comment explains why the vendored type is NOT named `SHA256` — doing so would
// shadow `CryptoKit.SHA256` with no diagnostic.
//
// The tests were updated to match at 18.0.16, but only their IMPORTS were. Both
// files carry the comment "non-Apple uses the vendored SHA256 (SHA256.swift),
// which needs no module import -- mirror the loader", and then went on calling a
// bare `SHA256.hash(data:)` that only exists when CryptoKit is present. On Apple
// that resolves and the drift is invisible. On Windows it is:
//
//     StockfishNetworkLoaderTests.swift:38:19: error: cannot find 'SHA256' in scope
//     StockfishNetworkLoaderCancellationTests.swift:141:13: error: cannot find 'SHA256' in scope
//
// measured on the first Windows CI run, 2026-09-01. The library was portable;
// its tests were not, and nothing said so until a non-Apple host compiled them.
//
// A FUNCTION RATHER THAN A TYPEALIAS, deliberately. `VendoredSHA256` offers the
// streaming shape — `update(data:)` then `finalize()` — and no static
// `hash(data:)`, so aliasing the type would not make the existing call sites
// compile. All three of them wanted the same thing anyway: the hex digest.
//===----------------------------------------------------------------------===//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SwiftStockfish

/// Lowercase hex SHA-256 of `data`, on every platform the package supports.
func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return CryptoKit.SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    #else
    var hasher = VendoredSHA256()
    hasher.update(data: data)
    return hasher.finalize()
        .map { String(format: "%02x", $0) }
        .joined()
    #endif
}
