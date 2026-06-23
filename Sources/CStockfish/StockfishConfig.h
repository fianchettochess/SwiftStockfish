#ifndef STOCKFISH_CONFIG_H
#define STOCKFISH_CONFIG_H

#pragma clang diagnostic ignored "-Wcomma"

#define NNUE_EMBEDDING_OFF

#if defined(__aarch64__) || defined(__arm64__)
    #define USE_NEON 8
    #define USE_NEON_DOTPROD 1
#elif defined(__x86_64__)
    #define USE_SSE2 1
    #define USE_SSSE3 1
    #define USE_SSE41 1
    #define USE_POPCNT 1
    #define USE_AVX2 1
    #define USE_PEXT 1
#endif

#define IS_64BIT

#endif
