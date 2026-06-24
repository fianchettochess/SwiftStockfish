#ifndef STOCKFISH_CONFIG_H
#define STOCKFISH_CONFIG_H

#pragma clang diagnostic ignored "-Wcomma"

#define NNUE_EMBEDDING_OFF

#if defined(__aarch64__) || defined(__arm64__)
    #define USE_NEON 8
    #define USE_NEON_DOTPROD 1
#elif defined(__x86_64__)
    // SSE2 is the x86-64 ABI baseline: `__SSE2__` is ALWAYS a compiler
    // predefine on this arch, so its intrinsics are always legal codegen and
    // this define needs no `-m…` flag. It therefore stays `.unsafeFlags`-free
    // (remote version-pinnable).
    #define USE_SSE2 1
    // The higher SSE tiers each need their own `-m…` codegen flag for their
    // intrinsics to compile (`-mssse3`, `-msse4.1`, `-mpopcnt`). The
    // publishable SOURCE build (the non-Apple `#else` manifest arm) passes NO
    // such flags — adding `.unsafeFlags` to the manifest would break remote
    // version-pinning — so we must NOT enable these tiers unconditionally.
    // Instead, gate each on the compiler's OWN feature predefine: the tier
    // lights up only when the consumer actually passed the matching flag, in
    // which case the intrinsics are guaranteed legal.
    //
    // TRADE-OFF: a no-flag x86_64 source build gets USE_SSE2 only, so
    // Stockfish's NNUE falls back to its generic (scalar SSE2) path —
    // correct + publishable, but slow. Faster x86_64 codegen is opt-in:
    //   `-mssse3 -msse4.1 -mpopcnt`      -> the SSSE3 NNUE path
    //   `-mavx2 -mbmi2 -DSF_ENABLE_AVX2` -> full AVX2 (see below)
    // The PREBUILT Apple xcframework is UNAFFECTED: Tools/build-xcframework.sh
    // passes `-mavx2 -mbmi2 -DSF_ENABLE_AVX2` for every x86_64 slice, so
    // `__AVX2__`/`__BMI2__` (and the lower SSE predefines they imply) plus
    // SF_ENABLE_AVX2 are all set there -> full AVX2 is retained.
    #if defined(__SSSE3__)
        #define USE_SSSE3 1
    #endif
    #if defined(__SSE4_1__)
        #define USE_SSE41 1
    #endif
    #if defined(__POPCNT__)
        #define USE_POPCNT 1
    #endif
    // AVX2/PEXT need `-mavx2 -mbmi2` codegen flags AND the explicit
    // SF_ENABLE_AVX2 opt-in. OFF by default in source builds; the Apple
    // xcframework opts in via the build script (above).
    #if defined(SF_ENABLE_AVX2) && defined(__AVX2__) && defined(__BMI2__)
        #define USE_AVX2 1
        #define USE_PEXT 1
    #endif
#endif

#define IS_64BIT

#endif
