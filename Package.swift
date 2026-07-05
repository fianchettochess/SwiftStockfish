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
//     xcframework carries ten slices (ios-arm64, ios-arm64_x86_64-simulator,
//     ios-arm64_x86_64-maccatalyst, macos-arm64_x86_64, tvos-arm64,
//     tvos-arm64_x86_64-simulator, watchos-arm64, watchos-arm64_x86_64-simulator,
//     xros-arm64, xros-arm64_x86_64-simulator) — built from the same Stockfish 18
//     source, with the
//     per-arch SIMD flags (`-mavx2 -mbmi2` on the x86_64 slices) baked in at
//     build time. A prebuilt binary needs no per-architecture compile flags, so
//     this package builds for every supported arch, not just arm64.
//
//   * The `CStockfish` target is now BRIDGE-ONLY: it compiles just the small
//     C++ bridge (`StockfishBridge.cpp`) that drives Stockfish's UCI loop
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
//   * PATH MODE on `main`, URL MODE at a release tag. The active binaryTarget
//     below references the xcframework by `path:` so a plain `swift build` works
//     against the committed binary. The release workflow
//     (.github/workflows/release.yml, run via Actions → "Release binary") builds
//     the xcframework, publishes it as a release asset, and rewrites THIS
//     binaryTarget to `url:` + `checksum:` in the tagged commit — so each release
//     tag is a clean url-based binary package while `main` stays path-buildable.
//     See the README's "Releasing" section.

import PackageDescription

// ENGINE SOURCING OVERRIDE — Apple hosts link the prebuilt
// `Stockfish.xcframework`; non-Apple hosts compile Stockfish from source.
// SwiftPM evaluates THIS manifest on the BUILD HOST, so `#if os(macOS)` reflects
// the host, not the build target. That is correct for native builds, but an
// Apple→Android/Linux CROSS-COMPILE (`swift build --swift-sdk <id>`) still runs
// the manifest on the Apple host and would wrongly pick the xcframework arm.
// Setting `SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE=1` forces the from-source arm
// regardless of host — the Android (Skip) build sets it to compile the engine
// for the device. `useBinaryEngine` is the single switch every conditional below
// keys on (replacing the bare host-only `#if os()` gates).
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let hostIsApple = true
#else
let hostIsApple = false
#endif
let useBinaryEngine = hostIsApple
    && Context.environment["SWIFTSTOCKFISH_FORCE_SOURCE_ENGINE"] != "1"

// CONDITIONAL ENGINE TARGETS — the manifest's `#if os(...)` evaluates against
// the BUILD HOST, which is exactly what we want for native builds: a Mac host
// links the prebuilt xcframework; a Linux/Windows host compiles Stockfish from
// source. The target NAME stays `CStockfish` in BOTH arms, so the product
// (`.library(name: "CStockfish", …)`) and the `SwiftStockfish` target's
// `dependencies: ["CStockfish"]` are identical on every platform — the `#if`
// is confined to the engine target body.
//
// NOTE: cross-compiling Apple→non-Apple evaluates this on the macOS host, so we
// gate on the runtime `useBinaryEngine` flag (host AND no FORCE_SOURCE override)
// rather than a bare `#if os()` — otherwise a `--swift-sdk` Android build would
// pick the xcframework arm. Native non-Apple builds have hostIsApple == false.
let engineTargets: [Target]
if useBinaryEngine {
// APPLE — link the prebuilt, multi-arch Stockfish.xcframework via a
// binaryTarget; the `CStockfish` bridge compiles ONLY itself (the engine's
// `.cpp` under `stockfish/` stay on disk for GPL source-availability but are
// excluded — the binary already contains them).
//
// PATH MODE on `main` (links the committed Frameworks/Stockfish.xcframework, so
// `swift build` just works). At release time CI rewrites the binaryTarget block
// — and only that block — to the url+checksum form:
//   .binaryTarget(
//       name: "StockfishEngine",
//       url: "https://.../releases/download/<version>/Stockfish.xcframework.zip",
//       checksum: "<sha256 from `swift package compute-checksum`>"
//   )
engineTargets = [
    .binaryTarget(
        name: "StockfishEngine",
        path: "Frameworks/Stockfish.xcframework"
    ),
    .target(
        name: "CStockfish",
        dependencies: ["StockfishEngine"],
        path: "Sources/CStockfish",
        // Restrict the compiled sources to the bridge alone. This keeps every
        // `stockfish/**/*.cpp` out of the build while leaving the engine's
        // HEADERS in place on the header search path below, and the `.cpp`
        // on disk for GPL source availability.
        sources: ["StockfishBridge.cpp"],
        // The public umbrella header (`include/StockfishBridge.h`) is the
        // Swift module's C interface.
        publicHeadersPath: "include",
        cxxSettings: [
            // The target root, so the bridge's `#include "StockfishConfig.h"`
            // (a plain source include, not a force-include flag) resolves.
            // Paths are relative to the target directory.
            .headerSearchPath("."),
            // Let the bridge resolve its `#include "bitboard.h"`-style
            // includes against the engine's kept headers.
            .headerSearchPath("stockfish"),
            .define("NDEBUG", .when(configuration: .release)),
        ]
    ),
]
} else {
// NON-APPLE (Linux / Windows / Android / …) OR a forced source build — compile
// the engine FROM SOURCE plus the bridge in ONE target. No `sources:` is set, so
// SwiftPM compiles every `.cpp` it finds under the target directory: the bridge
// (`StockfishBridge.cpp`) AND all 23 engine translation units under
// `stockfish/` (the exact set Tools/build-xcframework.sh enumerates). There is
// no binaryTarget on these platforms.
engineTargets = [
    .target(
        name: "CStockfish",
        path: "Sources/CStockfish",
        // The public umbrella header (`include/StockfishBridge.h`) is the
        // Swift module's C interface.
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("."),
            .headerSearchPath("stockfish"),
            .define("NDEBUG", .when(configuration: .release)),
            // Make the engine's own `NativeThread` use pthread (matching its
            // thread_win32_osx.h:30 condition) on Linux/Android; everywhere
            // else it falls back to std::thread. Optional — std::thread also
            // works — but it matches the upstream default on those hosts.
            .define("USE_PTHREADS", .when(platforms: [.linux, .android])),
        ]
    ),
]
}

// CRYPTO BACKEND — the NNUE loader verifies downloaded nets with SHA-256.
// Apple platforms use the OS-provided CryptoKit (no dependency). NON-APPLE
// hosts have no CryptoKit, so they pull swift-crypto's `Crypto` module, which
// exposes the identical `SHA256` API. The dependency + the target link are
// gated on `useBinaryEngine` (an Apple host with no source-build override), so
// the Apple build never resolves, downloads, or links swift-crypto — the Apple
// dependency graph is unchanged. A forced source build pulls swift-crypto too.
let cryptoPackageDeps: [Package.Dependency]
let cryptoTargetDeps: [Target.Dependency]
if useBinaryEngine {
cryptoPackageDeps = []
cryptoTargetDeps = []
} else {
cryptoPackageDeps = [
    .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
]
cryptoTargetDeps = [
    .product(name: "Crypto", package: "swift-crypto"),
]
}

// DOCC GENERATION — the swift-docc-plugin is a command plugin used only by
// `swift package generate-documentation`. It adds nothing to the library's own
// dependency graph or its compiled output and is unconditional (it does not
// touch the engine-sourcing or crypto-backend selection above).
let doccPluginDeps: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
]

let package = Package(
    name: "SwiftStockfish",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
        .macCatalyst(.v13),
    ],
    products: [
        // Both products are `.static`. This package wraps a static-library
        // xcframework plus a thin bridge, so a dynamic framework buys nothing —
        // and static linkage lets a (coverage-)instrumented bridge resolve the
        // LLVM profile runtime from the consuming target, instead of failing a
        // standalone package-framework link with an undefined
        // `___llvm_profile_runtime`.
        //
        // The high-level Swift API (engine wrapper + NNUE loader) — the
        // primary interface for most consumers.
        .library(
            name: "SwiftStockfish",
            type: .static,
            targets: ["SwiftStockfish"]
        ),
        // The low-level C/C++ bridge (sf_create / sf_send_command / …),
        // for consumers that want to drive the UCI loop with their own engine
        // lifecycle rather than the Swift wrapper. (Fianchetto uses this to
        // keep its existing start/stop generation logic during validation.)
        .library(
            name: "CStockfish",
            type: .static,
            targets: ["CStockfish"]
        ),
    ],
    // swift-crypto on non-Apple hosts (see cryptoPackageDeps) + the DocC plugin.
    dependencies: cryptoPackageDeps + doccPluginDeps,
    targets: engineTargets + [
        // The Swift-facing API: the engine wrapper + the version-aware NNUE
        // network loader.
        .target(
            name: "SwiftStockfish",
            // `cryptoTargetDeps` is empty on Apple (CryptoKit comes from the OS)
            // and adds swift-crypto's `Crypto` product on non-Apple hosts.
            dependencies: ["CStockfish"] + cryptoTargetDeps,
            path: "Sources/SwiftStockfish"
        ),
        // The test suite. Suites 1 & 2 are pure-logic / offline filesystem
        // tests that run on a plain `swift test` (they NEVER touch the
        // network). Suite 3 is a real-engine UCI integration suite, gated
        // behind the SWIFTSTOCKFISH_INTEGRATION env var so it stays out of the
        // default run (it needs a ~107 MB net download + a live engine).
        .testTarget(
            name: "SwiftStockfishTests",
            // `cryptoTargetDeps` is empty on Apple and links swift-crypto on
            // non-Apple, where the loader test hashes a synthetic net with
            // `SHA256` (CryptoKit has no Linux module).
            dependencies: ["SwiftStockfish"] + cryptoTargetDeps
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
