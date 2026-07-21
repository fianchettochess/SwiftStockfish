# Third-Party Notices

## Stockfish

SwiftStockfish vendors source from
[official-stockfish/Stockfish](https://github.com/official-stockfish/Stockfish)
at the tag recorded in [`.upstream-version`](.upstream-version), currently
`sf_18`. Stockfish is distributed under the GNU General Public License,
version 3. Its copyright and license notices remain in the vendored source.

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

- [swift-crypto](https://github.com/apple/swift-crypto) supplies the `Crypto`
  SHA-256 implementation on non-Apple hosts and is licensed under Apache 2.0.
- [Swift-DocC Plugin](https://github.com/swiftlang/swift-docc-plugin) is a
  build-time documentation dependency licensed under Apache 2.0. It is not
  linked into the SwiftStockfish products.

Those packages are resolved independently by Swift Package Manager and retain
their own license and third-party-notice requirements. This file does not
relicense third-party work or replace the notices shipped by those projects.
