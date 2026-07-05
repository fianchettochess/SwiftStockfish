# Tools — regenerating the prebuilt engine binary

`build-xcframework.sh` compiles the package's bundled Stockfish source
(`Sources/CStockfish/stockfish` + the `Sources/CStockfish/StockfishConfig.h`
prefix header) into **`Frameworks/Stockfish.xcframework`**, the static-library
binary that the `StockfishEngine` binaryTarget links. Day-to-day builds never
recompile Stockfish — they just link this binary.

> **CI runs this script too.** The repo's `Release binary` workflow
> (`.github/workflows/release.yml`) runs `Tools/build-xcframework.sh` on
> `macos-14`, then zips the result, publishes it as a release asset, and
> rewrites `Package.swift`'s binaryTarget to a checksummed `url:`. So this is
> both the local "regenerate the committed binary" tool and the build step of a
> release. See the README's [Releasing](../README.md#releasing) section.

## When to re-run

- **Bumping Stockfish** — after replacing the engine source under
  `Sources/CStockfish/stockfish` (and the `StockfishNetworks.required` manifest).
- **Changing the package's minimum OS** — the slices are baked at a specific
  minimum (currently **iOS 13.0 / macOS 10.15**, the `IOS_MIN` / `MAC_MIN`
  vars). These must stay in sync with `Package.swift`'s `platforms`. The
  engine itself imposes no OS floor; the floor is set by Swift-concurrency
  back-deployment in the Swift wrapper, so the binary is simply built to match.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Tools/build-xcframework.sh
```

Produces `Frameworks/Stockfish.xcframework` with ten slices:

| Slice | Archs |
|---|---|
| `ios-arm64` | arm64 (device) |
| `ios-arm64_x86_64-simulator` | arm64, x86_64 |
| `ios-arm64_x86_64-maccatalyst` | arm64, x86_64 |
| `macos-arm64_x86_64` | arm64, x86_64 |
| `tvos-arm64` | arm64 (device) |
| `tvos-arm64_x86_64-simulator` | arm64, x86_64 |
| `watchos-arm64` | arm64 (device) |
| `watchos-arm64_x86_64-simulator` | arm64, x86_64 |
| `xros-arm64` | arm64 (device) |
| `xros-arm64_x86_64-simulator` | arm64, x86_64 |

Build flags mirror the in-target build exactly: `-std=gnu++20 -O3 -DNDEBUG`,
the `StockfishConfig.h` prefix header (which defines `NNUE_EMBEDDING_OFF` plus
the per-arch SIMD flags, `-mavx2 -mbmi2` on the x86_64 slices). The NNUE
network is **not** embedded — it loads at runtime from a `.nnue` resource, so
the binary stays small and the net can be swapped without a recompile.

After regenerating, commit the updated `Frameworks/Stockfish.xcframework` on
`main` (path mode keeps the binary in git so local `swift build` works). To
publish it for consumers, don't commit a binary by hand — run the `Release
binary` workflow, which builds, uploads it as a release asset, and switches the
binaryTarget to `url:` for that tag.

## Licensing

Stockfish is **GPL-3**. This script + the Stockfish source it reads +
`StockfishConfig.h` are the separately-distributable GPL component: they build a
standalone binary that the wrapper merely links. Ship them together for a clean
GPL source-availability boundary.
