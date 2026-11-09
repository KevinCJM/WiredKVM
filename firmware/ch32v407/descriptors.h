#pragma once
#include "usb_driver.h"
usb_rst_e wk407_descriptor(usbd_handle_t *,const usb_req_t *,void **,size_t *);
usb_rst_e wk407_hid_descriptor(usbd_handle_t *,const usb_req_t *,void **,size_t *);
unsigned wk407_port(usbd_handle_t *h);
