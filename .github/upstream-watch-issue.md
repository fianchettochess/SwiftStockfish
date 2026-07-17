The upstream watcher found a newer **@NAME@** release.

|  | version |
|---|---|
| Pinned here (`.upstream-version`) | `@PINNED@` |
| Latest upstream release | [`@LATEST@`](https://github.com/@REPO@/releases/tag/@LATEST@) |

SwiftStockfish vendors the Stockfish C++ source in-tree under `Sources/CStockfish/stockfish/` and builds it into `Frameworks/Stockfish.xcframework`. Ingesting a new version is a deliberate, verified step — this issue is a reminder + checklist, not an automated change.

### Update checklist
- [ ] Fetch [`@REPO@`](https://github.com/@REPO@) at tag `@LATEST@`
- [ ] Replace the vendored source in `Sources/CStockfish/stockfish/` with the new upstream `src/`
- [ ] Reconcile any new/changed compiler flags in `Tools/build-xcframework.sh`
- [ ] Check for new or renamed NNUE nets referenced by `Sources/SwiftStockfish/StockfishNetworks.swift`
- [ ] Rebuild the xcframework: `Tools/build-xcframework.sh`
- [ ] `swift test` on the path-based `main`
- [ ] Bump `.upstream-version` to `@LATEST@`
- [ ] Push an `N.N.N` release tag — CI builds the xcframework, checksums it, and publishes

<sub>Opened automatically by `.github/workflows/upstream-watch.yml`; it will not be re-created for `@LATEST@`.</sub>
