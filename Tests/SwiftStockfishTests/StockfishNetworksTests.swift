//
//  StockfishNetworksTests.swift
//  SwiftStockfishTests
//
//  Pure-logic tests for the NNUE manifest (`StockfishNetworks`). No filesystem,
//  no network — these always run on a plain `swift test`.
//

import Testing
@testable import SwiftStockfish

@Suite("StockfishNetworks manifest")
struct StockfishNetworksTests {

    // MARK: - shaPrefix extraction

    @Test("shaPrefix is the 12-hex between nn- and .nnue")
    func shaPrefixExtractsTheBigNet() {
        let net = StockfishNetworks.Network(filename: "nn-c288c895ea92.nnue")
        #expect(net.shaPrefix == "c288c895ea92")
    }

    @Test("shaPrefix extracts the small net too")
    func shaPrefixExtractsTheSmallNet() {
        let net = StockfishNetworks.Network(filename: "nn-37f18f62d772.nnue")
        #expect(net.shaPrefix == "37f18f62d772")
    }

    @Test(
        "malformed filenames yield an empty shaPrefix",
        arguments: [
            "garbage",     // no prefix/suffix at all
            "nn-.nnue",    // prefix + suffix but nothing between → start == end
            "foo.nnue",    // right suffix, wrong prefix
            "nn-abcdefabcdef0.nnue", // too many digest characters
            "nn-abcdefabcde.nnue",   // too few digest characters
            "nn-abcdefabcdeg.nnue",  // non-hex digest character
            "nn-ABCDEFABCDEF.nnue",  // canonical names are lowercase
            "nn-a/../../outside.nnue", // path separators are never valid
        ]
    )
    func shaPrefixIsEmptyForMalformedNames(_ filename: String) {
        let net = StockfishNetworks.Network(filename: filename)
        #expect(net.shaPrefix == "")
    }

    // MARK: - The required manifest

    /// sf_19 collapsed the big/small pair into a single `EvalFileDefaultName`,
    /// so this went from two to one. The count is pinned rather than merely
    /// asserted non-empty because the loader PRUNES every `nn-*.nnue` outside
    /// this list: a stray extra entry silently keeps a superseded net alive on
    /// every install, and a missing one deletes a net the engine needs and only
    /// fails at the first search. (sf_19 upgrade 2026-09-06)
    @Test("required has exactly one net")
    func requiredHasOneNet() {
        #expect(StockfishNetworks.required.count == 1)
    }

    /// The manifest must match the engine actually bundled. `EvalFileDefaultName`
    /// in evaluate.h is what `Network::load` looks for, so a manifest naming a
    /// different file downloads a net the engine will not read and prunes the
    /// one it will. Read from the vendored source, not from upstream's website.
    @Test("required names the engine's own EvalFileDefaultName")
    func requiredMatchesTheBundledEngine() {
        #expect(StockfishNetworks.required.map(\.filename) == ["nn-1a298aa575a0.nnue"])
    }

    @Test("each required net has a non-empty 12-char shaPrefix")
    func requiredNetsHaveTwelveCharPrefixes() {
        for net in StockfishNetworks.required {
            #expect(!net.shaPrefix.isEmpty)
            #expect(net.shaPrefix.count == 12)
        }
    }

    @Test("each required filename matches nn-<12 hex>.nnue")
    func requiredFilenamesMatchTheStockfishScheme() {
        // `^nn-[0-9a-f]{12}\.nnue$`, hand-rolled to avoid pulling in a regex
        // dependency / a newer-API requirement than the iOS 13 floor.
        for net in StockfishNetworks.required {
            let name = net.filename
            #expect(name.hasPrefix("nn-"))
            #expect(name.hasSuffix(".nnue"))

            let prefix = net.shaPrefix
            #expect(prefix.count == 12)
            let isLowerHex = prefix.allSatisfy { c in
                ("0"..."9").contains(c) || ("a"..."f").contains(c)
            }
            #expect(isLowerHex, "shaPrefix \(prefix) is not 12 lowercase hex chars")
        }
    }

    @Test("each required net pins a canonical full SHA-256 matching its filename")
    func requiredNetsHaveCanonicalFullDigests() {
        for net in StockfishNetworks.required {
            #expect(net.sha256.count == 64)
            #expect(net.sha256.hasPrefix(net.shaPrefix))
            #expect(net.hasValidSHA256)
        }
    }

    @Test("full SHA-256 input is normalized to lowercase")
    func fullDigestInputIsNormalized() {
        let required = StockfishNetworks.required[0]
        let net = StockfishNetworks.Network(
            filename: required.filename,
            sha256: required.sha256.uppercased()
        )
        #expect(net.sha256 == required.sha256)
        #expect(net.hasValidSHA256)
    }

    @Test("stockfishVersion is 19")
    func stockfishVersionIs19() {
        #expect(StockfishNetworks.stockfishVersion == "19")
    }
}
