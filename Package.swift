// swift-tools-version: 6.0
//
// (tools 6.0, not 5.9: `.macOS(.v15)` / `.iOS(.v18)` were only added to
// PackageDescription in 6.0 — see the spec's "5.9 or 6.0" allowance.)
//
// SwiftStockfish — a Swift Package Manager wrapper around the Stockfish chess
// engine (GPL-3.0). See README.md for the full story; the highlights:
//
//   * The `CStockfish` target compiles the bundled Stockfish C++ source plus a
//     small Obj-C++ bridge that drives Stockfish's UCI loop over in-process
//     pipes. The `SwiftStockfish` target is the Swift-facing API + NNUE loader.
//
//   * PROTOTYPE / arm64-ONLY: `StockfishConfig.h` (force-included below) enables
//     USE_AVX2 / USE_PEXT for x86_64, which require `-mavx2 -mbmi2`. SPM cannot
//     apply C++ flags per-architecture, so the source build here targets Apple
//     Silicon (arm64), where NEON + DOTPROD are baseline on Apple clang and need
//     no extra arch flag. Multi-arch shipping is done via a prebuilt
//     binaryTarget — see the README's "binaryTarget migration path".
//
//   * NOT VERSION-PUBLISHABLE AS-IS: because the C target uses `.unsafeFlags`
//     (the `-include` force-include of the prefix header), this package can be
//     consumed as a LOCAL path dependency but NOT as a version-pinned remote
//     dependency. SwiftPM rejects `.unsafeFlags` in resolved remote packages.
//     The fix is the same binaryTarget migration: a prebuilt xcframework needs
//     no per-arch compile flags, so the remote product becomes publishable.

import PackageDescription

let package = Package(
    name: "SwiftStockfish",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "SwiftStockfish",
            targets: ["SwiftStockfish"]
        ),
    ],
    targets: [
        // The Stockfish engine source + the Obj-C++ bridge.
        .target(
            name: "CStockfish",
            path: "Sources/CStockfish",
            // The engine source tree lives in `stockfish/`. Everything else in
            // the target directory (the bridge, the prefix header, the public
            // umbrella in include/) is picked up automatically.
            publicHeadersPath: "include",
            cxxSettings: [
                // The target root, so the `-include StockfishConfig.h`
                // force-include below (and the bridge's `#include
                // "StockfishConfig.h"`) resolves. Paths are relative to the
                // target directory.
                .headerSearchPath("."),
                // Let the bridge and the engine's own translation units resolve
                // their `#include "bitboard.h"`-style includes.
                .headerSearchPath("stockfish"),
                // Force-include the prefix header on every translation unit. It
                // sets NNUE_EMBEDDING_OFF (nets are loaded from disk, not
                // embedded) and the per-arch SIMD defines. On arm64 the NEON /
                // DOTPROD it enables are baseline for Apple clang, so no extra
                // `-march`/`-m...` flag is needed. THIS is the `.unsafeFlags`
                // that blocks remote version-pinned consumption (see header).
                .unsafeFlags(["-include", "StockfishConfig.h"]),
                .define("NDEBUG", .when(configuration: .release)),
            ]
        ),
        // The Swift-facing API: the engine wrapper + the version-aware NNUE
        // network loader.
        .target(
            name: "SwiftStockfish",
            dependencies: ["CStockfish"],
            path: "Sources/SwiftStockfish"
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
