#pragma once
#include "usb_driver.h"
#include "bridge.h"
#include <stdbool.h>

#define WKAP_INTERFACE 2
#define WKAP_ENDPOINT 2
#define WKAP_TX_KIND 9
#define WKAP_HOST_ENUM 1u
#define WKAP_TARGET_ONLINE 2u
#define WKAP_NORMAL_BUSY 4u
#define WKAP_HELD_INPUT 8u

/* Narrow ABI adapter. All callers are on the existing USB polling thread. */
void wkap_profile_reset(void);
void wkap_profile_cancel_setup(void);
usb_rst_e wkap_profile_setup(const usb_req_t *,void **,size_t *,uint32_t);
usb_rst_e wkap_profile_data(const usb_req_t *,void *,size_t);
unsigned wkap_profile_guards(const wk407_bridge *,bool,bool,bool);
bool wkap_profile_poll(uint32_t,unsigned);
void wkap_profile_quiescing(bool);
const uint8_t *wkap_profile_input(size_t *);
bool wkap_profile_submitted(uint32_t *,uint32_t *);
void wkap_profile_done(uint32_t,uint32_t);
