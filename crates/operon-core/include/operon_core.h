#ifndef OPERON_CORE_H
#define OPERON_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OperonSessionHandle OperonSessionHandle;

enum {
  OPERON_FFI_OK = 0,
  OPERON_FFI_ERROR = 1,
  OPERON_FFI_INVALID_ARGUMENT = 2,
};

/* Static library-owned string. Do not free. */
const char *operon_abi_version(void);

/*
 * Creates a session. `query` must be UTF-8. Pass NULL for `config_json` to use
 * defaults, or provide UTF-8 JSON matching SessionConfig. On failure returns
 * NULL and may set `*out_error`; free any allocated error with
 * operon_string_free.
 */
OperonSessionHandle *operon_session_create(
    const char *query,
    const char *config_json,
    char **out_error);

/*
 * Starts/resumes the command loop. On OPERON_FFI_OK, `*out_step_json` receives
 * allocated UTF-8 JSON shaped as either:
 *   {"kind":"command","command": { ... ExecutionCommand ... }}
 *   {"kind":"complete","result": { ... ExecutionResult ... }}
 *
 * Free every returned step or error string with operon_string_free. `out_step_json`
 * must not be NULL; `out_error` may be NULL.
 */
int32_t operon_session_start(
    OperonSessionHandle *handle,
    char **out_step_json,
    char **out_error);

int32_t operon_session_resume(
    OperonSessionHandle *handle,
    const char *event_json,
    char **out_step_json,
    char **out_error);

/*
 * Serializes/restores versioned deterministic execution state. Snapshot JSON
 * may contain host-private artifact values and must be protected like app data.
 * If a command was outstanding, persist it with the snapshot and redeliver it
 * after restore using the same request ID and idempotency key.
 */
int32_t operon_session_snapshot(
    OperonSessionHandle *handle,
    char **out_snapshot_json,
    char **out_error);

OperonSessionHandle *operon_session_restore(
    const char *snapshot_json,
    char **out_error);

/* Safe to call with NULL. Do not reuse the handle afterwards. */
void operon_session_destroy(OperonSessionHandle *handle);

/* Safe to call with NULL. */
void operon_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif /* OPERON_CORE_H */
