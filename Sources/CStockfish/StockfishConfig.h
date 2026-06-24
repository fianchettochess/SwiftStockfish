#ifndef STOCKFISH_CONFIG_H
#define STOCKFISH_CONFIG_H

#pragma clang diagnostic ignored "-Wcomma"

#define NNUE_EMBEDDING_OFF

#if defined(__aarch64__) || defined(__arm64__)
    #define USE_NEON 8
    #define USE_NEON_DOTPROD 1
#elif defined(__x86_64__)
    // SSE baseline — available on every x86_64 target's default codegen, so
    // this requires no `-m…` flag and stays `.unsafeFlags`-free (remote
    // version-pinnable).
    #define USE_SSE2 1
    #define USE_SSSE3 1
    #define USE_SSE41 1
    #define USE_POPCNT 1
    // AVX2/PEXT need the `-mavx2 -mbmi2` codegen flags for their intrinsics, so
    // they are gated behind SF_ENABLE_AVX2 and OFF by default. SOURCE builds
    // (the non-Apple `#else` manifest arm) therefore default to the SSE
    // baseline and carry no `.unsafeFlags`. The PREBUILT Apple xcframework
    // KEEPS full AVX2: Tools/build-xcframework.sh passes both `-mavx2 -mbmi2`
    // AND `-DSF_ENABLE_AVX2` for the x86_64 slices. A power user who controls
    // their own x86_64 source build can opt back in by defining SF_ENABLE_AVX2
    // and passing `-mavx2 -mbmi2` via their own CXXFLAGS.
    #if defined(SF_ENABLE_AVX2)
        #define USE_AVX2 1
        #define USE_PEXT 1
    #endif
#endif

#define IS_64BIT

#endif
