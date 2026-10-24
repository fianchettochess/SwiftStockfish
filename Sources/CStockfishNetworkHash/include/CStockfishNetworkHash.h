// Streaming SHA-256 for network artifact integrity, FIPS 180-4.
#ifndef CStockfishNetworkHash_H
#define CStockfishNetworkHash_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint32_t state[8];
    uint8_t buffer[64];
    uint64_t total_bytes;
    size_t buffer_count;
} sf_network_hash_context;
void sf_network_hash_init(sf_network_hash_context *context);
void sf_network_hash_update(sf_network_hash_context *context, const uint8_t *bytes, size_t count);
void sf_network_hash_finalize(sf_network_hash_context *context, uint8_t digest[32]);
#ifdef __cplusplus
}
#endif
#endif
