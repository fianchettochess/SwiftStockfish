# SwiftStockfish — Broad Platform Compatibility: Decision-Ready Phased Plan

## Verified ground truth (corrections to the lenses, so the plan is accurate)

- **23 translation units**, not "17 .cpp": `find` shows 17 at `stockfish/` top level **plus 6 in subdirs** (`nnue/network.cpp`, `nnue/nnue_accumulator.cpp`, `nnue/nnue_misc.cpp`, `nnue/features/full_threats.cpp`, `nnue/features/half_ka_v2_hm.cpp`, `syzygy/tbprobe.cpp`). The build script already enumerates them dynamically (`build-xcframework.sh:61` `find . -name "*.cpp"`), so a source target should **not** hardcode 23 paths.
- **`StockfishConfig.h:11-18` currently DOES define `USE_AVX2`/`USE_PEXT` on x86_64** — the POSIX lens's claim that the file is already baseline is wrong. Any "baseline x86_64" decision requires an actual change here, gated on a macro so Apple keeps AVX2.
- **Stockfish's own threading is already cross-platform**: `thread_win32_osx.h:30` uses `pthread` on `__APPLE__`/MinGW/`USE_PTHREADS` and **falls back to `std::thread` everywhere else** (line ~72). So Windows/WASI multi-core threading in the *engine* needs **zero** porting — the only thread code we must touch is the **bridge's own** `pthread` use.
- **The only genuinely platform-specific code we own** is in `StockfishBridge.mm`: POSIX pipes (`pipe` at :99, `read` at :49/:139, `write` at :65/:70/:209/:239), the bridge's own `pthread_create`/`pthread_join` (:133/:168/:213/:219), and the Apple-only **`pthread_attr_set_qos_class_np`** (:130, :166). The `std::cin/std::cout` rdbuf swap (:176-177, :185-186) is portable C++ and stays.

---

## 1. Target architecture — the linchpin

### 1a. Conditional manifest: prebuilt on Apple, source on everything else

SwiftPM manifest `#if os(...)` evaluates against the **build host**, which is exactly what we want for *native* builds (a Linux host builds the Linux source target; a Mac host builds the binaryTarget). The structure, replacing the single target list at `Package.swift:84-140`:

```swift
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
  // APPLE — UNCHANGED. binaryTarget + bridge-only CStockfish (today's lines 94-123).
  let engineTargets: [Target] = [
    .binaryTarget(name: "StockfishEngine", path: "Frameworks/Stockfish.xcframework"),
    .target(name: "CStockfish",
            dependencies: ["StockfishEngine"],
            path: "Sources/CStockfish",
            sources: ["StockfishBridge.mm"],          // bridge only; engine .cpp excluded
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("."), .headerSearchPath("stockfish"),
                          .define("NDEBUG", .when(configuration: .release))]),
  ]
#else
  // NON-APPLE — compile the engine from source + the bridge in ONE target.
  // Do NOT set `sources:` -> SwiftPM compiles every .cpp it finds (bridge +
  // all 23 engine TUs), exactly the set build-xcframework.sh already builds.
  let engineTargets: [Target] = [
    .target(name: "CStockfish",
            path: "Sources/CStockfish",
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("."), .headerSearchPath("stockfish"),
                          .define("NDEBUG", .when(configuration: .release)),
                          .define("USE_PTHREADS", .when(platforms: [.linux, .android]))]),
  ]
#endif
```

Then `SwiftStockfish` depends on `"CStockfish"` in **both** arms — the product (`Package.swift:78-82`) and the Swift target's dependency (`:128`) are unchanged because the target **name stays `CStockfish`**. This is cleaner than the POSIX lens's `CStockfishPOSIX` rename, which forced conditional product/dependency arrays. Keeping the name constant confines the `#if` to the target *body*.

Add to `platforms` (`Package.swift:55-58`): `.tvOS`, `.watchOS`, `.visionOS`, `.macCatalyst` in Phase A; SwiftPM does not have a `.linux`/`.windows` platform enum entry, so non-Apple support is expressed purely by the `#else` target arm plus CI that builds on those hosts (no `platforms:` line needed for them).

Two real constraints to document, not hide:
- **`.mm` compiles as Objective-C++ on non-Apple clang.** Swift's Linux/Windows clang treats `.mm` as ObjC++ and will try to find an ObjC runtime. Even though the file is pure C++, **rename `StockfishBridge.mm` → `StockfishBridge.cpp`** as the first step of Phase B (the Apple build is equally happy with `.cpp`; update `sources: ["StockfishBridge.cpp"]` at `:109`). This is a one-line, all-platforms-safe change and removes a latent non-Apple blocker.
- **Cross-compiling Apple→Linux picks the wrong arm** (host is macOS ⇒ `#if os(macOS)` true ⇒ binaryTarget). Document "non-Apple builds must be native (or use a native CI runner / a Swift SDK whose `swift build` runs the manifest under the *target* triple)." This is a known SwiftPM limitation, not our bug.

### 1b. Portable bridge I/O — replace the POSIX-pipe rdbuf swap with an in-memory queue

This is the single highest-leverage refactor: it makes the bridge identical on Linux, Windows, and WASM, and removes the only OS-specific I/O we own. Keep the public C API (`sf_create/sf_destroy/sf_set_output_callback/sf_send_command` in `include/StockfishBridge.h`) byte-for-byte so **Fianchetto and the Swift wrapper don't change at all.**

Concrete swap inside `StockfishBridge.mm/.cpp`:

| Today (POSIX) | Replacement (portable) |
|---|---|
| `int stdinPipe[2]`, `stdoutPipe[2]` (`:77-78`) | one `CommandQueue` (thread-safe `std::queue<std::string>` + `std::mutex` + `std::condition_variable`) for input; output goes straight to the callback |
| `PipeInputBuf::underflow` `read(fd,…)` (`:49`) | `underflow()` pops the next command from the queue, blocking on the condvar until data or shutdown |
| `PipeOutputBuf::overflow/xsputn` `write(fd,…)` (`:65,:70`) | `overflow/xsputn` append to a per-thread line buffer; on `'\n'` invoke `impl->callback` **directly** — this deletes the entire reader thread (`:133-155`) |
| reader thread (`:133-155`) | **removed** — output is synchronous from the engine thread's `cout` |
| `sf_send_command` `write(stdinPipe[1],…)` (`:239`) | push the string onto `CommandQueue`, notify condvar |
| `sf_destroy` writes `"quit\n"` to pipe (`:209`) | push `"quit"` + set `running=false`, notify; condvar wakes `underflow`, returns EOF, UCI loop exits |

The `std::cin/std::cout.rdbuf` swap (`:176-177`) **stays** — only the two streambuf subclasses change their backing store from an fd to a queue/callback. New header `Sources/CStockfish/StockfishIO.h` (header-only, `std::mutex`/`std::condition_variable`/`std::queue` — all portable) holds `CommandQueue`. This is the Windows lens's "Option B" and the WASM lens's prerequisite, unified.

Bridge thread management: the engine thread can stay `pthread` on POSIX/Apple, but to be Windows- and WASM-clean, switch the bridge's own engine thread to **`std::thread`** (the engine internals already use `std::thread` off-Apple via `thread_win32_osx.h`; matching that in the bridge removes our last `pthread` dependency outside Apple). Guard the Apple QoS pinning, which has no portable equivalent:

```cpp
#if defined(__APPLE__)
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_UTILITY, 0);   // :130, :166
#endif
```

On Apple, **keep today's exact `pthread`+QoS path** (the QoS pinning at `:115-127` is load-bearing for the Microhang fix recorded in the comments — do not regress it). The clean way: `#if defined(__APPLE__)` → existing pthread+QoS engine/reader threads; `#else` → `std::thread` engine thread + direct-callback output (no reader thread). Both arms feed the same `CommandQueue`/streambuf core.

---

## 2. The SIMD-vs-publishability decision (source-compiled platforms)

**Recommendation: ship a portable baseline by default, with an opt-in `define` for AVX2 — no `.unsafeFlags`, so remote version-pinning is preserved.**

The tension is real: `-mavx2 -mbmi2` are needed for the AVX2 *intrinsics* that `USE_AVX2`/`USE_PEXT` (`StockfishConfig.h:16-17`) compile in, but `.unsafeFlags` is forbidden in version-pinned remote deps. The resolution that the lenses missed: **you don't need `.unsafeFlags` to get NEON, and you can get AVX2 without it via `cxxSettings` `.define` of the arch macro `__AVX2__`-equivalent isn't enough — the intrinsics still need the codegen flag.** So:

- **ARM64 (Linux/aarch64, Graviton, Windows-ARM, all Apple): full speed, free.** NEON/DOTPROD (`:8-10`) is baseline on every 64-bit ARM target's default codegen; **no flags, no perf loss.** This covers the fastest-growing server fleet.
- **x86_64 source builds: ship baseline (SSE2/SSSE3/SSE4.1/POPCNT), gate AVX2/PEXT off.** Edit `StockfishConfig.h:11-18` so the AVX2/PEXT block is `#if defined(SF_ENABLE_AVX2)` inside the x86_64 arm; **Apple keeps AVX2 because `build-xcframework.sh:74` passes `-mavx2 -mbmi2` and would also pass `-DSF_ENABLE_AVX2`** (one-word change to the script's `extra`). Result: the prebuilt Apple x86_64 simulator/Mac slices are unchanged (full AVX2); source x86_64 builds default to SSE-baseline and stay `.unsafeFlags`-free → **remote-publishable**.
- **Perf cost, honest:** SSE-baseline vs AVX2 on modern x86_64 is roughly **15–25% fewer nodes/sec** (Stockfish's own range). For a *analysis/training app* this is acceptable; it is not a benchmarking distribution.
- **Power-user escape hatch (no perf compromise, still publishable):** a consumer who controls their own build can re-enable it locally via an env/define without us shipping `.unsafeFlags`. Document: define `SF_ENABLE_AVX2` **and** pass `-mavx2 -mbmi2` through `CXXFLAGS` / a local `unsafeFlags` fork. This stays in *their* package graph, not ours.

Net: **NEON platforms pay nothing; x86_64 source builds pay ~15–25% by default and can opt back in.** The package remains version-pinnable as a remote dependency on every platform. This is strictly better than the POSIX lens's "remove AVX2 entirely" (which would have silently de-tuned the **Apple** x86_64 slices too, since they share `StockfishConfig.h`).

---

## 3. Phased plan, ordered by leverage/effort

### Phase A — Extra Apple slices (tvOS / visionOS / Mac Catalyst; watchOS with caveat)
**Effort: ~0.5–1 day. Risk: very low. Model unchanged (still binaryTarget).**

Steps:
1. `build-xcframework.sh`: add `TVOS_MIN/WATCHOS_MIN/VISIONOS_MIN` constants near `:50-51`; add `build_arch` calls for `appletvos`/`appletvsimulator`, `xros`/`xrsimulator`, Mac Catalyst (`-target <arch>-apple-ios13.2-macabi`), and watchOS (`watchos arm64`, `watchsimulator arm64+x86_64`); add each `-library` to the `xcodebuild -create-xcframework` at `:106-110`. The per-arch SIMD logic at `:74` already does the right thing (x86_64 sim slices get AVX2; arm64 gets NEON) — **no change**.
2. `Package.swift:55-58`: add `.tvOS(.v13)`, `.visionOS(.v1)`, `.macCatalyst(.v13)`, and `.watchOS(.v6)`.
3. The release workflow runs the script verbatim, so it picks up new slices automatically. The committed xcframework grows (more slices); re-`compute-checksum` at release.

Caveats to honor: **omit `watchos-arm64_32`** (target Series 5+/watchOS 6) unless 32-bit is explicitly wanted — `arm64_32` is a separate slice and only adds value for Series 4. watchOS memory is tight (~25 MB NNUE + engine); ship with a small default Hash and document it. Mac Catalyst has **no simulator slice**.

**Unlocks:** every Apple platform, zero architectural change, fully remote-publishable today.

### Phase B — Portable bridge refactor + Linux/POSIX source build (foundation for all non-Apple)
**Effort: ~1–2 weeks. Risk: medium (touches the bridge core; mitigated by an unchanged C API + existing integration tests).**

Steps:
1. **Rename** `StockfishBridge.mm` → `.cpp` (update `Package.swift:109`). Verify Apple build/tests still green.
2. **Implement the in-memory queue I/O** (Section 1b): new `StockfishIO.h`; rewire the two streambufs; delete the reader thread on the non-Apple arm; `#if defined(__APPLE__)` guard around `pthread_attr_set_qos_class_np` (`:130,:166`) and keep the Apple pthread+QoS path intact. Re-run the gated integration suite (`SWIFTSTOCKFISH_INTEGRATION`) on macOS — behavior must be identical.
3. **Add the `#else` source target arm** (Section 1a): no `sources:` (compiles bridge + all 23 TUs), `USE_PTHREADS` define for Linux/Android so the engine's own `NativeThread` uses pthread (matching its `thread_win32_osx.h:30` condition; optional — `std::thread` fallback also works).
4. **`StockfishConfig.h:11-18`**: gate AVX2/PEXT behind `SF_ENABLE_AVX2`; pass `-DSF_ENABLE_AVX2` from `build-xcframework.sh:74` so Apple is unaffected (Section 2).
5. Build & test natively on Linux (`swift build && swift test`); the NNUE loader works via swift-corelibs-foundation `URLSession`.

**Unlocks:** Linux (x86_64 + aarch64), and the **entire portable foundation** — once the bridge is queue-based and `.cpp`, Windows and WASM become incremental.

### Phase C — Windows
**Effort: ~1 week *on top of B* (B does the heavy lifting). Risk: medium, mostly toolchain/CI.**

After Phase B, the bridge has **no POSIX I/O and no mandatory pthread**, so Windows needs almost no new bridge code:
1. Confirm the `#else` arm compiles under Swift-on-Windows clang (C++20, `std::thread`, `std::mutex`, `std::condition_variable` — all present). The engine's `NativeThread` already resolves to `std::thread` off-Apple.
2. Threading priority: optionally add a `#elif defined(_WIN32)` branch using `SetThreadPriority` where Apple uses QoS — **optional**, not a blocker.
3. CI: GitHub Actions `windows-latest` + Swift toolchain; `swift build && swift test`.
4. x86_64 SIMD: baseline by default per Section 2 (publishable). 

**Unlocks:** Windows x86_64/ARM64 native. The Windows lens's 6–10 week estimate collapses to ~1 week **because Phase B already paid the I/O-abstraction cost.**

### Phase D — WASM
**Verdict: DEFER. Do not attempt now; revisit when WASI threads ship (est. 2027–2028).**

Honest read of the WASM lens: there are two toolchains and neither is clean today.
- **WASI SDK + Swift WASM SDK** (the only path that fits SwiftPM's source-build model) is blocked by **three** things: (a) no working multi-thread story (`wasi-threads` withdrawn Aug 2023; `shared-everything-threads` has no runtimes as of mid-2026) → single-threaded only, **4–8× slower**; (b) `-fno-exceptions` default while Stockfish uses exceptions → must patch the engine; (c) C++↔Swift interop is **undocumented for WASM**, so the `CStockfish` module may not bridge.
- **Emscripten** (Lichess-proven, threads + SIMD work) **does not integrate with SwiftPM** — you'd hand-build a `.wasm/.js` and bind it as a manual binaryTarget-equivalent, outside `swift build`.

**What Phase B/1b buys you for free toward WASM:** the queue-based bridge is *exactly* the WASI-compatible I/O model (no pipes, no fds). So the most expensive WASM prerequisite is already done after Phase B. **If** WASM is pursued later, the path is: WASI SDK + Swift WASM SDK, `-fno-exceptions` patch (or wait for libunwind/wasm), accept single-thread until `shared-everything-threads` runtimes exist, and (optionally) hand-port the eval SIMD to `wasm-simd128` for ~20–40%. That's a 2–4 week spike **on top of** B, delivering a slow engine — not worth it until threading lands. **Recommendation: do not build now; the bridge refactor in B keeps the door open at zero extra cost.**

---

## 4. CI + testing + SPI impact

**Build matrix by phase:**
- **A:** macOS runner only (`build-xcframework.sh` produces all Apple slices; `xcodebuild -create-xcframework` validates them). Smoke-build for tvOS/visionOS/Catalyst destinations; watchOS test on simulator with a reduced `Hash`.
- **B:** add a **native Linux runner** (`ubuntu-latest`, both x86_64 and — if available — `arm64` runner) doing `swift build && swift test`; gate the engine integration suite behind `SWIFTSTOCKFISH_INTEGRATION` as today. Keep the macOS job to prove the binaryTarget arm still builds (guards against the conditional manifest breaking Apple).
- **C:** add `windows-latest` + Swift toolchain, `swift build && swift test`.
- **D (if ever):** a WASI job under Wasmtime, non-blocking/experimental, single-thread.

**SPI compatibility badges:** Swift Package Index derives the platform/Swift-version matrix from what actually builds.
- After **A**: Apple badges expand from iOS/macOS to **iOS/macOS/tvOS/watchOS/visionOS (+Catalyst)** — all green, since the binaryTarget carries the slices.
- After **B**: the **Linux** badge goes green (SPI builds packages on Linux; the source arm makes it compile there). This is the single biggest visible jump in "broad compatibility."
- After **C**: SPI does not currently run Windows builds, so no Windows badge — but the README/manifest can advertise it and CI proves it.
- **Risk to badges:** the conditional manifest must keep **the Apple arm building on SPI's macOS builder and the source arm building on SPI's Linux builder**. Test both before tagging, or a green→red regression on either platform is possible.

---

## 5. Recommendation

**Pursue A → B → C. Defer D.**

1. **Phase A first (½–1 day)** — pure upside, no architecture change, ships every Apple platform and immediately widens the SPI Apple badges. Do this now.
2. **Phase B is the real investment and the keystone (~1–2 wks)** — the queue-based bridge + `.cpp` rename + conditional manifest + the `SF_ENABLE_AVX2` gate. It unlocks Linux *and* pre-pays the entire I/O cost for Windows and WASM. **This is the one effort cliff**; budget for it deliberately and lean on the unchanged C API + the integration suite to de-risk the Apple side.
3. **Phase C is cheap once B lands (~1 wk)** — Windows is mostly CI/toolchain, because B already removed the POSIX I/O and pthread dependence. The "6–10 week" figure only applies if you skip B and abstract I/O Windows-first; sequencing B before C is what makes C small.
4. **WASM: not now.** It is not impractical forever, but today it delivers a 4–8× slower, single-threaded, exception-patched engine through a toolchain that breaks SwiftPM's build model. The honest call: **revisit when `shared-everything-threads` has a shipping runtime.** B keeps the door open for free, so deferring costs nothing.

**SIMD call, restated:** baseline-by-default + `SF_ENABLE_AVX2` opt-in, no `.unsafeFlags` anywhere → the package stays a version-pinnable remote dependency on **all** platforms; ARM64 pays zero, x86_64 source builds pay ~15–25% unless opted in, and the Apple prebuilt slices keep full AVX2 unchanged.

**No platform here is genuinely impractical except WASM-right-now**, and that one is a timing problem (missing WASI threading), not a fundamental one.

### Where the changes land (file:line)
- `Package.swift:55-58` (platforms +4 Apple), `:84-140` (conditional target arms; name stays `CStockfish`), `:109` (`.mm`→`.cpp`).
- `Sources/CStockfish/StockfishBridge.mm` → rename to `.cpp`; queue I/O replacing pipes at `:41-74` (streambufs), `:77-78` (pipe fds → `CommandQueue`), `:99` (drop `pipe()`), `:133-155` (delete reader thread on non-Apple), `:130/:166` (`#if defined(__APPLE__)` around QoS), `:209/:239` (`write`→queue push).
- New `Sources/CStockfish/StockfishIO.h` (portable `CommandQueue`).
- `Sources/CStockfish/StockfishConfig.h:11-18` (gate AVX2/PEXT behind `SF_ENABLE_AVX2`).
- `Tools/build-xcframework.sh:50-51` (new mins), `:74` (add `-DSF_ENABLE_AVX2` to the x86_64 `extra`), `:91-110` (new Apple slices + `-library` lines).