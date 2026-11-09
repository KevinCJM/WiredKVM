#pragma once
#include "usb_driver.h"
#include <stdbool.h>

/* One polling owner, USB2 non-burst interrupt IN EP82 only. False means
 * retain the old transfer's ownership and retry on a later loop pass. */
bool wkap_abort_ep82(usbd_handle_t *h);
