#ifndef STOCKFISH_BRIDGE_H
#define STOCKFISH_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const void *SFEngineRef;
typedef void (*SFOutputCallback)(const char *line, const void *context);

// CONTRACT for direct CStockfish consumers (the Swift `StockfishEngine` wrapper
// already upholds all of this internally, so Swift API users need not care):
//   * Only ONE engine may be live per process; `sf_create` blocks until any
//     prior engine is destroyed.
//   * Call `sf_destroy` EXACTLY ONCE per successful `sf_create`. A second
//     `sf_destroy`, or any `sf_send_command` / `sf_set_output_callback` after
//     `sf_destroy`, is undefined behaviour (use-after-free) — the returned
//     `SFEngineRef` is dangling once destroyed.
//   * Do not call these concurrently on the same engine; serialize them.
//   * `sf_send_command(engine, NULL)` and calls with a NULL `engine` are no-ops
//     (defensively guarded); every other misuse above is caller responsibility.
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
