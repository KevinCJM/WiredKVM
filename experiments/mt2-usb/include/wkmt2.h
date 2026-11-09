#ifndef WIREDKVM_EXPERIMENT_MT2_H
#define WIREDKVM_EXPERIMENT_MT2_H
#include <stddef.h>
#include <stdint.h>

/* EXPERIMENT ONLY. No production caller; no pixel-scroll capability advertised.
 * All exports are nonblocking and allocate no heap. The state uses 32-bit atomics.
 * GET responses INCLUDE report ID; SET payload EXCLUDES it. The USB adapter must
 * use one explicit contract when removing a SET report prefix.
 * Every negative return means reject/STALL the USB request, never ACK it.
 */
#define WKMT2_REPORT_DESCRIPTOR_SIZE 110u
#define WKMT2_INTERRUPT_PACKET_SIZE 64u
#define WKMT2_FEATURE_BUFFER_SIZE 256u
#define WKMT2_E_ARGUMENT (-1)
#define WKMT2_E_CAPACITY (-2)
#define WKMT2_E_UNSUPPORTED (-3)
#define WKMT2_E_PAYLOAD (-4)

#ifdef __cplusplus
extern "C" {
#endif
void wkmt2_reset(void); /* bus reset/configuration teardown: clears MT enable */
int32_t wkmt2_enabled(void);
int32_t wkmt2_report_descriptor(uint8_t *dst, size_t capacity);
/* capacity is the caller-clipped GET wLength. Zero capacity is valid. */
int32_t wkmt2_feature_get(uint8_t report_id, uint8_t *dst, size_t capacity);
int32_t wkmt2_feature_set(uint8_t report_id, const uint8_t *payload, size_t length);
/* Stage 1 only: returns a single 12-byte zero-contact report after enable.
 * Poll only when target is configured and EP7 idle. 0 means no report pending.
 * A successful call consumes the report; caller must then submit it to EP7.
 * No pointer movement, wheel, button, touch, gesture or WKSC packet is emitted.
 */
int32_t wkmt2_input(uint8_t *dst, size_t capacity);
/* Live gesture extension. One SDK polling owner. No heap or wait. */
void wkmt2_live_reset(void);
int32_t wkmt2_live_faults(void);
int32_t wkmt2_live_begin(uint32_t epoch,uint32_t now);
void wkmt2_live_end(uint32_t epoch);
int32_t wkmt2_live_offer(uint32_t epoch,const uint8_t *,size_t,uint32_t now);
void wkmt2_live_tick(uint32_t now,int32_t enabled);
int32_t wkmt2_live_abort_pending(void);
void wkmt2_live_aborted(void);
int32_t wkmt2_live_input(uint8_t *,size_t);
void wkmt2_live_submitted(void);
void wkmt2_live_done(void);
#ifdef __cplusplus
}
#endif
#endif
