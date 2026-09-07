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
/// Stockfish 19 evaluates with a single net. (Through sf_18 there were two — a
/// "big" net for the main evaluation and a "small" net for a faster,
/// lower-accuracy path.) Every net in ``required`` must be present in the
/// engine's network directory before the engine is created; a missing or
/// invalid net makes Stockfish call `exit(EXIT_FAILURE)`. See
/// ``StockfishNetworkLoader`` and ``StockfishEngine``.
public enum StockfishNetworks {

    /// The Stockfish source version this package wraps. Bump on upgrade.
    public static let stockfishVersion = "19"

    /// The exact NNUE networks the bundled engine requires.
    ///
    /// Filenames follow Stockfish's own scheme: `nn-<first 12 hex of the file's
    /// SHA-256>.nnue`. We additionally pin each net's FULL SHA-256 below, and the
    /// loader verifies the whole digest after a download — not just the 12-hex
    /// filename prefix — so a file forged to share the prefix (a 2^48
    /// second-preimage) cannot pass.
    ///
    /// The filename is read from the bundled engine's `evaluate.h`; the hash is
    /// the SHA-256 of that exact net. Bump both together with the engine source
    /// on a version upgrade.
    ///
    /// ONE NET FROM sf_19, NOT TWO. Through sf_18 the engine carried a big and a
    /// small network, named by `EvalFileDefaultNameBig` and
    /// `EvalFileDefaultNameSmall`; sf_19 collapsed them into a single
    /// `EvalFileDefaultName`, so those two symbols no longer exist to read. The
    /// loader prunes any `nn-*.nnue` that is not in this list, so an install
    /// holding the two sf_18 nets converges to the one below without manual
    /// cleanup — and the pruning is why this list must be exactly the required
    /// set rather than a superset kept "just in case".
    public static let required: [Network] = [
        // EvalFileDefaultName
        Network(filename: "nn-1a298aa575a0.nnue",
                sha256: "1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2"),
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

        /// Creates a network descriptor. Hexadecimal digest input is normalized
        /// to lowercase before validation by ``StockfishNetworkLoader``.
        public init(filename: String, sha256: String = "") {
            self.filename = filename
            self.sha256 = sha256.lowercased()
        }

        /// The 12-hex SHA-256 prefix encoded in the filename — i.e. the text
        /// between the `nn-` prefix and the `.nnue` suffix.
        ///
        /// Returns the empty string unless the filename is exactly
        /// `nn-<12 lowercase hex>.nnue`. The strict shape check also rejects
        /// path separators, so a custom manifest cannot escape the directory
        /// managed by ``StockfishNetworkLoader``.
        public var shaPrefix: String {
            guard filename.hasPrefix("nn-"), filename.hasSuffix(".nnue") else {
                return ""
            }
            let start = filename.index(filename.startIndex, offsetBy: 3)
            let end = filename.index(filename.endIndex, offsetBy: -".nnue".count)
            guard start < end else { return "" }
            let prefix = String(filename[start..<end])
            guard prefix.count == 12,
                  prefix.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else {
                return ""
            }
            return prefix
        }

        /// Whether a supplied full digest is a canonical SHA-256 that agrees
        /// with the 12-hex prefix encoded in ``filename``. An empty digest
        /// retains the documented prefix-only mode for existing custom
        /// manifests and synthetic tests.
        var hasValidSHA256: Bool {
            guard !sha256.isEmpty else { return true }
            guard sha256.count == 64,
                  sha256.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else {
                return false
            }
            return !shaPrefix.isEmpty && sha256.hasPrefix(shaPrefix)
        }
    }
}
