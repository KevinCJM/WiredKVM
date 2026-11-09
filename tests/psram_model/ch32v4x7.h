#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef enum {DISABLE,ENABLE} FunctionalState;
typedef struct {uint32_t ADDR,CTLR,TIMING,LATENCY,CMD1_CFG,DATA;} TestPSRAM;
extern TestPSRAM test_psram;
extern uint32_t SystemCoreClock;
#define PSRAM (&test_psram)
#define RCC_HBPeriph_PSRAM 1
#define PSRAM_EXIT_LPMD 0x10000
void RCC_HBPeriphClockCmd(unsigned,FunctionalState);
