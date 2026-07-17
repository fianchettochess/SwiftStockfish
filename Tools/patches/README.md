# Local patches to the vendored Stockfish source

SwiftStockfish carries the Stockfish engine source in-tree under
`Sources/CStockfish/stockfish/` (it must — the non-Apple SwiftPM arm compiles it
directly, the Apple bridge resolves its headers, and GPL-3.0 §3 requires shipping
it). The tree is upstream `official-stockfish/Stockfish` at the tag in
[`.upstream-version`](../../.upstream-version), **minus** `Makefile`/`main.cpp`
(library, not CLI), **plus** the patches here.

This is the SwiftPM analogue of the SwiftReckless fork: because Cargo can build
from a git fork but SwiftPM cannot fetch/compile external source at build time,
Reckless keeps its patches on a fork branch while Stockfish keeps its (smaller)
patch-set here and applies them during re-vendoring.

Applied in sorted order by [`Tools/update-stockfish.sh`](../update-stockfish.sh)
after it syncs the upstream `src/`. Each is a GPLv3 §5(a)-noticed modification:

- `0001-types.h-add-StockfishConfig-include.patch` — add `#include
  "StockfishConfig.h"` to `types.h` so the flagless non-Apple source build gets
  the SIMD/NNUE config (the Apple build force-includes the same header, so this
  is a no-op there via its include guard).
- `0002-nnue-simd.h-dotprod-target-attribute.patch` — add
  `__attribute__((target("dotprod")))` so `vdotq_s32` compiles under Xcode
  without a global `-march`.

If a new upstream tag moves the code a patch touches, `update-stockfish.sh` fails
loudly; rebase that `.patch` against the new source and re-run (regenerate with
`diff -u upstream/src/<file> Sources/CStockfish/stockfish/<file>`).
