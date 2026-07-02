#ifndef STOCKFISH_BRIDGE_H
#define STOCKFISH_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const void *SFEngineRef;
typedef void (*SFOutputCallback)(const char *line, const void *context);

SFEngineRef sf_create(const char *nnueDir);
void sf_destroy(SFEngineRef engine);
void sf_set_output_callback(SFEngineRef engine, SFOutputCallback callback, const void *context);
void sf_send_command(SFEngineRef engine, const char *command);

/// Wait until no engine instance is live (the process-wide lifecycle gate
/// that `sf_create` blocks on is free). Returns true if the gate freed
/// within `timeoutMs`, false on timeout. Intended for tests that run
/// engine lifecycles back-to-back: waiting here keeps the NEXT test's
/// ready-timeout budget from silently absorbing the PREVIOUS engine's
/// teardown latency. Returns immediately when nothing is live.
bool sf_wait_idle(int timeoutMs);

#ifdef __cplusplus
}
#endif

#endif
