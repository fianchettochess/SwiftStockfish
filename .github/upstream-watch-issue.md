The upstream watcher found a newer **@NAME@** release.

|  | version |
|---|---|
| Pinned here (`.upstream-version`) | `@PINNED@` |
| Latest upstream release | [`@LATEST@`](https://github.com/@REPO@/releases/tag/@LATEST@) |

SwiftStockfish vendors the Stockfish C++ source in-tree under `Sources/CStockfish/stockfish/` (the non-Apple SwiftPM arm compiles it directly, and GPL-3.0 requires shipping it), with our local changes kept as explicit patches in `Tools/patches/`. Ingesting a new version is a deliberate, verified step — this issue is a reminder + checklist, not an automated change.

### Update checklist
- [ ] Re-vendor + re-apply patches: `Tools/update-stockfish.sh @LATEST@` (fails loudly if a patch needs a rebase)
- [ ] Reconcile any new/changed compiler flags in `Tools/build-xcframework.sh`
- [ ] Check for new or renamed NNUE nets referenced by `Sources/SwiftStockfish/StockfishNetworks.swift` (bump `stockfishVersion` + `required`)
- [ ] Rebuild the xcframework: `Tools/build-xcframework.sh`
- [ ] `swift test` on the path-based `main`
- [ ] Review the diff, commit, then run **Actions → Release binary** with a new `N.N.N` version (the workflow builds/tests the exact artifact and creates the tag once)

<sub>`Tools/update-stockfish.sh` updates `.upstream-version` for you.</sub>

<sub>Opened automatically by `.github/workflows/upstream-watch.yml`; it will not be re-created for `@LATEST@`.</sub>
