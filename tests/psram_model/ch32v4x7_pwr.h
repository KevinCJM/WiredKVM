#pragma once
#include "ch32v4x7.h"
typedef struct {uint32_t EXTEN_CTR;} TestEXTEN;
extern TestEXTEN test_exten;
#define EXTEN (&test_exten)
#define PWR_VDD18_Level1 0x1000
void PWR_VDD18LevelConfig(uint32_t);
