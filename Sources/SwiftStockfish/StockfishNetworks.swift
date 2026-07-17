//
//  StockfishNetworks.swift
//  SwiftStockfish
//
//  The manifest of NNUE networks the bundled engine requires. This is the
//  single source of truth for "what nets does this version of Stockfish need":
//  the loader reads `required` to decide what to download / keep / prune, and
//  the README's upgrade workflow is "bump these together with the engine".
//

import Foundation

/// The set of NNUE networks the bundled Stockfish build evaluates with.
///
/// Stockfish 18 uses two nets — a "big" net for the main evaluation and a
/// "small" net for a faster, lower-accuracy path. Both must be present in the
/// engine's network directory before the engine is created; a missing or
/// invalid net makes Stockfish call `exit(EXIT_FAILURE)`. See
/// ``StockfishNetworkLoader`` and ``StockfishEngine``.
public enum StockfishNetworks {

    /// The Stockfish source version this package wraps. Bump on upgrade.
    public static let stockfishVersion = "18"

    /// The exact NNUE networks the bundled engine requires.
    ///
    /// Filenames follow Stockfish's own scheme: `nn-<first 12 hex of the file's
    /// SHA-256>.nnue`. We additionally pin each net's FULL SHA-256 below, and the
    /// loader verifies the whole digest after a download — not just the 12-hex
    /// filename prefix — so a file forged to share the prefix (a 2^48
    /// second-preimage) cannot pass.
    ///
    /// The filenames were read from the bundled engine's `evaluate.h`
    /// (`EvalFileDefaultNameBig` / `EvalFileDefaultNameSmall`); the hashes are the
    /// SHA-256 of those exact nets. Bump both together with the engine source on
    /// a version upgrade.
    public static let required: [Network] = [
        // big (EvalFileDefaultNameBig)
        Network(filename: "nn-c288c895ea92.nnue",
                sha256: "c288c895ea924429ea9092e3f36b2b3c1f00f2a3a4c759ff7e57e79e3b43e4a7"),
        // small (EvalFileDefaultNameSmall)
        Network(filename: "nn-37f18f62d772.nnue",
                sha256: "37f18f62d772f3107e1d6aaca3898c130c3c86f2ab63e6555fbbca20635a899d"),
    ]

    /// A single NNUE network, identified by its Stockfish filename.
    public struct Network: Sendable, Equatable, Hashable {
        /// e.g. `"nn-c288c895ea92.nnue"`.
        public let filename: String

        /// The full 64-hex SHA-256 of the net, pinned in-source. The loader
        /// verifies the WHOLE digest, so a forged file that only matches the
        /// filename's 12-hex prefix cannot pass. An empty string falls back to
        /// prefix-only verification (used by synthetic test fixtures).
        public let sha256: String

        public init(filename: String, sha256: String = "") {
            self.filename = filename
            self.sha256 = sha256.lowercased()
        }

        /// The 12-hex SHA-256 prefix encoded in the filename — i.e. the text
        /// between the `nn-` prefix and the `.nnue` suffix.
        ///
        /// Returns the empty string if the filename does not follow the
        /// `nn-<hex>.nnue` scheme; the loader treats an empty/mismatched
        /// prefix as a verification failure.
        public var shaPrefix: String {
            guard filename.hasPrefix("nn-"), filename.hasSuffix(".nnue") else {
                return ""
            }
            let start = filename.index(filename.startIndex, offsetBy: 3)
            let end = filename.index(filename.endIndex, offsetBy: -".nnue".count)
            guard start < end else { return "" }
            return String(filename[start..<end])
        }
    }
}
