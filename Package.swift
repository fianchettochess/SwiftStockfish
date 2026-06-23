// swift-tools-version: 6.0
//
// DEPLOYMENT FLOOR: iOS 13.0 / macOS 10.15 (Catalina). This is set purely by
// SWIFT-CONCURRENCY BACK-DEPLOYMENT — `async`/`await`, `AsyncStream`,
// `withCheckedThrowingContinuation` and friends back-deploy to exactly iOS 13 /
// macOS 10.15, no further. The Stockfish engine itself imposes no OS floor; the
// network loader was written to stay on iOS-13-era Foundation APIs
// (`URLSession.downloadTask(with:completionHandler:)` rather than the iOS-15
// async `download(from:)`, `appendingPathComponent(_:)` rather than the iOS-16
// `appending(path:)`). The prebuilt `Stockfish.xcframework` is compiled with
// matching minimums (iOS 13.0 / macOS 10.15) — see Tools/build-xcframework.sh;
// re-run that script (and keep its minimums in sync) when bumping Stockfish.
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
        .macOS(.v10_15),
        .iOS(.v13),
    ],
    products: [
        // The high-level Swift API (engine wrapper + NNUE loader) — the
        // primary interface for most consumers.
        .library(
            name: "SwiftStockfish",
            targets: ["SwiftStockfish"]
        ),
        // The low-level C/Obj-C++ bridge (sf_create / sf_send_command / …),
        // for consumers that want to drive the UCI loop with their own engine
        // lifecycle rather than the Swift wrapper. (Fianchetto uses this to
        // keep its existing start/stop generation logic during validation.)
        .library(
            name: "CStockfish",
            targets: ["CStockfish"]
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
