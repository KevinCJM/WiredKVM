#pragma once
#include <stdbool.h>
#include <stdint.h>

// Read-only board-resident installer. Validation runs after HID has started.
void wk_flash_setup_init(void);
bool wk_flash_setup_matches(uint32_t blocks, uint32_t crc);
bool wk_flash_setup_read(uint32_t offset, void *buffer, uint32_t length);
