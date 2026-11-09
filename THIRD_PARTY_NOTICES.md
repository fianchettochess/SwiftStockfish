# Third-Party Notices

## Stockfish

SwiftStockfish vendors source from
[official-stockfish/Stockfish](https://github.com/official-stockfish/Stockfish)
at the tag recorded in [`.upstream-version`](.upstream-version). Stockfish is
distributed under the GNU General Public License, version 3. Its copyright and license notices remain in the vendored source.

The vendored tree omits the upstream command-line entry point and build file,
adds the bridge/configuration needed by this package, and applies the documented
changes in [`Tools/patches`](Tools/patches). The complete corresponding source
and the script used to build `Stockfish.xcframework` are included in this
repository. Because SwiftStockfish ships and links Stockfish, the package as a
whole is distributed under GPL-3.0; see [`LICENSE`](LICENSE).

## incbin

Stockfish includes the `incbin` helper under
`Sources/CStockfish/stockfish/incbin`. Its upstream `UNLICENCE` file is retained
alongside the source and applies to that helper.

## Swift package dependencies

None. `Package.swift` declares no package dependencies: SHA-256 comes from
CryptoKit on Apple platforms and from the package's own FIPS 180-4
implementation (`Sources/CStockfishNetworkHash` behind
`Sources/SwiftStockfish/SHA256.swift`) elsewhere.

`Tools/check-third-party-notices.py` fails if a dependency is added to
`Package.swift` without being listed here, or listed here without being one,
and if this file names a Stockfish tag other than the one in
`.upstream-version`, which stays the single place the tag is recorded.
