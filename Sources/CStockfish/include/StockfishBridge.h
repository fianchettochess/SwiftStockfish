#ifndef STOCKFISH_BRIDGE_H
#define STOCKFISH_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef const void *SFEngineRef;
typedef void (*SFOutputCallback)(const char *line, const void *context);

SFEngineRef sf_create(const char *nnueDir);
void sf_destroy(SFEngineRef engine);
void sf_set_output_callback(SFEngineRef engine, SFOutputCallback callback, const void *context);
void sf_send_command(SFEngineRef engine, const char *command);

#ifdef __cplusplus
}
#endif

#endif
