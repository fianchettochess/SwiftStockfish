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
- `0003-misc.cpp-preserve-embedder-argv0-on-windows.patch` — in
  `CommandLine::get_binary_directory`, fire the Windows `_get_pgmptr()` override
  only when argv[0] carries no directory of its own. This engine is **embedded,
  not launched**: `sf_create` conveys the caller's NNUE directory through a
  synthetic argv[0] and through nothing else, and upstream's unconditional
  override replaced it with the real running image — so on Windows (clang
  targeting the MSVC ABI defines `_MSC_VER`; every other platform takes the
  `#else` arm) the net directory was silently lost. `load_user_net` then fails
  without a diagnostic, so the engine answers `uci` / `isready` / `setoption` /
  `position` perfectly and looks healthy, while `verify_networks()` runs lazily
  from only `go`, `perft` and `trace_eval` — so the FIRST search prints five
  `info string ERROR:` lines and calls `exit(EXIT_FAILURE)`, killing the host
  process. Upstream's own case (a bare `stockfish` at a prompt: extensionless
  argv[0], no separator) still takes the pgmptr path, so CLI behaviour is
  unchanged, and only the directory component of a separator-bearing argv[0] is
  ever used so the absent `.exe` is irrelevant. Windows-only by construction;
  Apple/Linux/Android compile the untouched `#else` arm.
- `0004-bitboard.h-popcount-without-popcnt-on-clang-windows.patch` — take the MSVC
  `_mm_popcnt_u64` branch only under MSVC proper. Clang refuses to inline that
  always_inline intrinsic into a function built without the `popcnt` target
  feature, and this package's non-Apple x86_64 builds are deliberately baseline.
- `0005-misc.h-prefetch-without-intel-intrinsic-on-clang-windows.patch` — the same
  `_MSC_VER` reading applied to `_mm_prefetch`.
- `0006-misc.cpp-keep-embedder-command-line-on-windows.patch` — adopt the command
  line Windows reports only when `argv[0]` proves it is the caller's own. Upstream
  overwrites both the count and the pointer with the host process's real command
  line, which turns the host's ARGUMENTS into UCI commands and replaces the
  embedder's net directory even when the host has none. The companion to `0003`:
  that one protects `argv[0]`'s directory, this one protects the whole vector.
- `0007-types.h-popcnt-header-without-msvc-intrinsics-on-clang-windows.patch` —
  include `<nmmintrin.h>` only under MSVC proper. It is an x86 (SSE4.2) header, and
  clang defines `_MSC_VER` on EVERY Windows target including
  `aarch64-unknown-windows-msvc`, where defining it is exactly what selects the MSVC
  ABI. Upstream reads `_MSC_VER` as "therefore x86", which held while MSVC was the
  only compiler defining it. MEASURED 2026-09-07: an ARM64 Windows build died inside
  clang's own `mmintrin.h` on `__builtin_ia32_*` at 10 of 40 files, before reaching
  any Stockfish code; with this it compiles 37 of 39 and stops only at the link, for
  want of the ARM64 CRT import libraries. Nothing is lost on clang at any
  architecture, because `0004` already stopped clang using the one intrinsic this
  header was included for.

  The neighbouring `<xmmintrin.h>` prefetch include in the same file has the same
  shape and is deliberately untouched: `NO_PREFETCH` already disables it and the
  consuming face passes `-DNO_PREFETCH` for arm64. An ARM64 build without that
  define would still meet it.

If a new upstream tag moves the code a patch touches, `update-stockfish.sh` fails
loudly; rebase that `.patch` against the new source and re-run (regenerate with
`diff -u upstream/src/<file> Sources/CStockfish/stockfish/<file>`).
