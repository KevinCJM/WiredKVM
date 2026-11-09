#pragma once
#include "ch32v4x7.h"
typedef struct {uint32_t PSRAM_trc,PSRAM_tcph,PSRAM_txlpd;} PSRAMTimingInitTypeDef;
typedef struct {uint32_t PSRAM_cfifo,PSRAM_cap_cfg,PSRAM_exti_lpmd;PSRAMTimingInitTypeDef *PSRAMTimingStruct;} PSRAMInitTypeDef;
#define PSRAM_CFIFO_WRADD 0x10
#define PSRAM_CAP_64M 0x300
void PSRAMDeInit(void);
void PSRAMInit(PSRAMInitTypeDef *);
void PSRAMSetData(uint16_t);
uint16_t PSRAMGetData(void);
void PSRAM_Set_MR_ADDR(uint8_t);
void PSRAM_Set_CMD(uint8_t);
void PSRAM_Set_Busy(FunctionalState);
void PSRAM_Set_MW(FunctionalState);
void PSRAMSetWrLatency(uint32_t);
void PSRAMSetRdLatency(uint32_t);
