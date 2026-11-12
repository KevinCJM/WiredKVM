#ifndef WIREDKVM_CLIPBOARD_STATE_H
#define WIREDKVM_CLIPBOARD_STATE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Main-thread owned. No OS, clipboard, USB, file or clock access. */
typedef struct WKCSState WKCSState;
enum { WKCS_BOOK = 0, WKCS_MINI = 1, WKCS_NO_SIDE = 2 };
enum { WKCS_UNKNOWN = 0, WKCS_LOCAL = 1, WKCS_RECEIVED = 2 };
enum { WKCS_NATIVE = 0, WKCS_TRANSFER = 1, WKCS_BLOCKED = 2, WKCS_REFRESH = 3 };
enum {
    WKCS_OK = 0, WKCS_INVALID = 1, WKCS_SESSION = 2, WKCS_SEQUENCE = 3,
    WKCS_REVISION = 4, WKCS_UNKNOWN_SOURCE = 5, WKCS_CUT_UNCONFIRMED = 6,
    WKCS_FOCUS = 7, WKCS_STALE = 8
};

typedef struct {
    uint32_t side, provenance;
    uint64_t session, stamp, revision;
    uint32_t original_side, reserved;
    uint64_t original_session, original_stamp;
} WKCSnapshot;

typedef struct {
    uint64_t generation, applied_sequence, focus_epoch;
    uint32_t selected_side, cut_blocked, context_side, reserved;
    uint64_t active_id;
} WKCSProjection;

typedef struct {
    uint32_t action, reason;
    uint64_t id;
    WKCSnapshot source, destination;
    uint64_t focus_epoch, generation;
} WKCSPlan;

WKCSState *wkcs_create(void);
void wkcs_destroy(WKCSState *state);
/* reset must precede a new endpoint session. session=0 binds the next snapshot. */
int32_t wkcs_reset(WKCSState *state, uint32_t side, uint64_t session);
int32_t wkcs_observe(WKCSState *state, WKCSnapshot snapshot, uint32_t select_source);
int32_t wkcs_select(WKCSState *state, uint64_t sequence, uint32_t side,
                   uint32_t cut, uint64_t baseline_stamp);
int32_t wkcs_context(WKCSState *state, uint64_t sequence, uint32_t side,
                    uint64_t focus_epoch);
/* Caller must first validate the matching departure nonce and unchanged local
 * clipboard revision. Ordinary keepalives are not departure evidence. */
int32_t wkcs_confirm_departure(WKCSState *state, uint32_t side,
                              uint64_t expected_sequence, uint64_t focus_epoch,
                              uint64_t baseline_session, uint64_t baseline_stamp);
WKCSPlan wkcs_plan(WKCSState *state, uint64_t id, uint32_t destination,
                   uint64_t min_sequence, uint64_t destination_revision,
                   uint64_t focus_epoch);
int32_t wkcs_active(const WKCSState *state, uint64_t id);
int32_t wkcs_commit(WKCSState *state, uint64_t id, WKCSnapshot destination);
void wkcs_abort(WKCSState *state, uint64_t id);
int32_t wkcs_snapshot(const WKCSState *state, uint32_t side, WKCSnapshot *output);
WKCSProjection wkcs_projection(const WKCSState *state);

#ifdef __cplusplus
}
#endif
#endif
