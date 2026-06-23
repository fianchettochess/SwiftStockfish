// swift-tools-version: 6.0
//
// (tools 6.0, not 5.9: `.macOS(.v15)` / `.iOS(.v18)` were only added to
// PackageDescription in 6.0 — see the spec's "5.9 or 6.0" allowance.)
//
// SwiftStockfish — a Swift Package Manager wrapper around the Stockfish chess
// engine (GPL-3.0). See README.md for the full story; the highlights:
//
//   * BINARYTARGET-BASED, MULTI-ARCH: the Stockfish engine ships as a prebuilt
//     `Stockfish.xcframework` (the `StockfishEngine` binaryTarget). The
//     xcframework carries three slices — ios-arm64, ios-arm64_x86_64-simulator,
//     macos-arm64_x86_64 — built from the same Stockfish 18 source, with the
//     per-arch SIMD flags (`-mavx2 -mbmi2` on the x86_64 slices) baked in at
//     build time. A prebuilt binary needs no per-architecture compile flags, so
//     this package builds for every supported arch, not just arm64.
//
//   * The `CStockfish` target is now BRIDGE-ONLY: it compiles just the small
//     Obj-C++ bridge (`StockfishBridge.mm`) that drives Stockfish's UCI loop
//     over in-process pipes, and links the engine binary for symbols. The
//     Stockfish C++ source still lives under `stockfish/` — its HEADERS are on
//     the bridge's header search path (so `#include "uci.h"` etc. resolve), and
//     its `.cpp` are kept for GPL source-availability but EXCLUDED from
//     compilation (the engine binary already contains them). The
//     `SwiftStockfish` target is the Swift-facing API + NNUE loader.
//
//   * VERSION-PUBLISHABLE: the bridge target carries NO `.unsafeFlags`. The
//     SIMD/NNUE configuration that previously required a force-included prefix
//     header now lives inside the binary; the bridge gets its config via a
//     plain `#include "StockfishConfig.h"` (a source include, not a compiler
//     flag) on its first line. With no `.unsafeFlags`, this package can be
//     consumed as a version-pinned remote dependency once the binaryTarget is
//     hosted remotely.
//
//   * PATH MODE (local prototype): the binaryTarget below references the
//     xcframework by `path:`. To publish remotely, host the xcframework as a
//     release asset (e.g. a GitHub release `Stockfish.xcframework.zip`), compute
//     its checksum with `swift package compute-checksum Stockfish.xcframework.zip`,
//     and swap `path:` for `url:` + `checksum:`. See the README's
//     "binaryTarget migration path".

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
        // The prebuilt Stockfish engine, multi-arch. Path mode for the local
        // prototype; for a remote release swap to:
        //   .binaryTarget(
        //       name: "StockfishEngine",
        //       url: "https://.../Stockfish.xcframework.zip",
        //       checksum: "<sha256 from `swift package compute-checksum`>"
        //   )
        .binaryTarget(
            name: "StockfishEngine",
            path: "Frameworks/Stockfish.xcframework"
        ),
        // The Obj-C++ bridge — links the engine binary for symbols and compiles
        // ONLY itself. (The engine's `.cpp` under `stockfish/` are kept for GPL
        // source-availability but not built; the binary already contains them.)
        .target(
            name: "CStockfish",
            dependencies: ["StockfishEngine"],
            path: "Sources/CStockfish",
            // Restrict the compiled sources to the bridge alone. This keeps every
            // `stockfish/**/*.cpp` out of the build while leaving the engine's
            // HEADERS in place on the header search path below, and the `.cpp`
            // on disk for GPL source availability.
            sources: ["StockfishBridge.mm"],
            // The public umbrella header (`include/StockfishBridge.h`) is the
            // Swift module's C interface.
            publicHeadersPath: "include",
            cxxSettings: [
                // The target root, so the bridge's `#include "StockfishConfig.h"`
                // (now a plain source include, not a force-include flag)
                // resolves. Paths are relative to the target directory.
                .headerSearchPath("."),
                // Let the bridge resolve its `#include "bitboard.h"`-style
                // includes against the engine's kept headers.
                .headerSearchPath("stockfish"),
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
