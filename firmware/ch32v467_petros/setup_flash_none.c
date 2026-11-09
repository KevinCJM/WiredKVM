/* Petros first-board test: no external NOR is established on this board.
 * This adapter deliberately has no peripheral header, GPIO access or SPI calls.
 * Keep the common read-only MSC protocol, but report no medium until a later,
 * separately verified NOR configuration is selected. PSRAM is not storage. */
#include "setup_flash.h"

bool wk_setup_flash_init(void) { return false; }

bool wk_setup_flash_read(void *context, uint32_t address, void *bytes, size_t n) {
    (void)context;
    (void)address;
    (void)bytes;
    (void)n;
    return false;
}
