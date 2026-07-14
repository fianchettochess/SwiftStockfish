# Installation

SwiftStockfish is a Swift Package Manager dependency.

## Requirements

| Platform | Minimum |
|---|---|
| macOS | 10.15 |
| iOS | 13 |
| tvOS | 13 |
| watchOS | 6 |
| visionOS | 1 |
| Mac Catalyst | 13 |
| Linux | x86_64 / arm64 (source build) |
| Android | API 28 (arm64 · x86_64 · armv7, source build) |

Swift tools version 6.0; C++20 (`gnu++20`). WASM is not yet supported. See
[Platform support](concepts/platform-support.md) for the full matrix and SIMD
details.

## Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/fianchettochess/SwiftStockfish", from: "18.0.0"),
],
targets: [
    .target(
        name: "MyChessApp",
        dependencies: [
            .product(name: "SwiftStockfish", package: "SwiftStockfish"),
        ]
    ),
]
```

### Products

| Product | Description |
|---|---|
| `SwiftStockfish` | The high-level Swift API (engine wrapper and NNUE loader). Recommended for most consumers. |
| `CStockfish` | The raw C bridge, for driving the UCI loop with a custom engine lifecycle. |

Both products are `.static`.

!!! warning "GPL-3.0"
    This package links Stockfish and is therefore a **GPL-3.0** work. Consuming it
    carries GPL-3.0 obligations on your application. Treat SwiftStockfish as the
    separately-distributable GPL component.

## `main` vs. release tags

- On **`main`**, the Apple engine binary is referenced by `path:` (the committed
  `Frameworks/Stockfish.xcframework`), so a plain `swift build` succeeds without
  additional setup.
- Each **release tag** rewrites that `binaryTarget` to a `url:` + `checksum:`
  form, pulling the xcframework from the GitHub release asset. This keeps the
  binary out of source control and produces a URL-based binary package.

Pin a version tag for a remote dependency; clone `main` for local development.

## Building the API documentation

SwiftStockfish ships a DocC catalog and depends on the
[swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin):

```bash
swift package generate-documentation --target SwiftStockfish
```

## Verifying the install

```bash
swift build
swift test     # offline logic + filesystem suites (the live-engine suite is gated)
```

The default `swift test` run never touches the network. The real-engine UCI
integration suite is gated behind the `SWIFTSTOCKFISH_INTEGRATION` environment
variable (it needs a ~107 MB net download and a live engine).

!!! note "Build on a local disk"
    `swift build` fails on an SMB network mount — the index store / module cache
    rely on atomic `rename()` semantics SMB does not provide. Build on a local
    APFS volume.
