#pragma once
#include <stddef.h>
#include <stdint.h>
#include "usb_driver.h"

#define WKMT2_INTERFACE 6
#define WKMT2_ENDPOINT 7
#define WKMT2_CONTROL_CAPACITY 128

void wkmt2_profile_reset(void);
void wkmt2_profile_host_reset(void);
usb_rst_e wkmt2_profile_setup(const usb_req_t *,void **,size_t *);
usb_rst_e wkmt2_profile_data(const usb_req_t *,void *,size_t);
const uint8_t *wkmt2_profile_input(size_t *);
void wkmt2_profile_input_done(void);
typedef void (*wkmt2_forward_fn)(void *,const uint8_t *,size_t,uint32_t);
void wkmt2_profile_control(void *,wkmt2_forward_fn,const uint8_t *,size_t,uint32_t);
const uint8_t *wkmt2_profile_diagnostic(size_t *);
void wkmt2_profile_diagnostic_done(void);

