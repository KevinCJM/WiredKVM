#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
bool wk_cable_setup_at_boundary(void);
void wk_cable_setup_reset(void);
void wk_cable_setup_peer_reset(void);
uint32_t wk_cable_setup_size(void);
uint32_t wk_cable_setup_changed(void);
int32_t wk_cable_setup_pending(void);
void wk_cable_setup_input(const uint8_t *,size_t);
size_t wk_cable_setup_ack(uint8_t *,size_t);
void wk_cable_setup_ack_submitted(void);
/* Sixteen fixed status words; no arbitrary RAM or clipboard read access. */
void wk_cable_platform_diagnostic(uint32_t *,size_t);
