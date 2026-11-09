/* Petros V467WEU6 only. Program image is volatile, never written to CodeFlash.
 * WCH PSRAM 200MHz example (2026-10-16) defines the timing/MR contract.
 * All register waits are bounded; failed RAM leaves keyboard/mouse USB usable.
 */
#include "ch32v4x7.h"
#include "ch32v4x7_psram.h"
#include "setup_flash.h"
#include "setup_ram.h"

#define RAM ((volatile uint8_t *)0x80000000u)
static bool ready;
static bool wait_idle(void) {
    for(unsigned n=0;n<200000;n++)if(!(PSRAM->ADDR&1u))return true;
    return false;
}
static bool mode(unsigned address,uint16_t value) {
    if(!wait_idle())return false;
    PSRAMSetData(value);PSRAM_Set_MR_ADDR((uint8_t)address);
    PSRAM_Set_CMD((uint8_t)(PSRAM->CMD1_CFG>>8));
    PSRAM_Set_Busy(ENABLE);PSRAM_Set_MW(ENABLE);
    return wait_idle();
}
bool wk_setup_flash_init(void) {
    ready=false;
    if(SystemCoreClock!=200000000u)return false;
    RCC_HBPeriphClockCmd(RCC_HBPeriph_PSRAM,ENABLE);PSRAMDeInit();
    PSRAMTimingInitTypeDef timing={0x14,0x0c,0x07};
    PSRAMInitTypeDef config={0,PSRAM_CAP_64M,0,&timing};
    /* The SDK defines exit-low-power at controller bit 16. */
    config.PSRAM_exti_lpmd=PSRAM_EXIT_LPMD;
    PSRAMInit(&config);
    for(volatile unsigned n=0;n<200000;n++){} /* bounded power-up settle, before USB starts */
    PSRAMSetWrLatency(7);if(!mode(4,1u<<5))return false;
    PSRAMSetRdLatency(7);if(!mode(0,4u<<2))return false;
    /* Sparse destructive probe is restricted to the unallocated image region.
     * No source volume exists yet. Catch aliasing across its 4MiB range. */
    const uint32_t offsets[]={0,0x1000,0x100000,0x200000,0x3ffffc};
    for(unsigned i=0;i<5;i++)for(unsigned j=0;j<4;j++)RAM[offsets[i]+j]=(uint8_t)(0x37u+i*19u+j);
    for(unsigned i=0;i<5;i++)for(unsigned j=0;j<4;j++)if(RAM[offsets[i]+j]!=(uint8_t)(0x37u+i*19u+j))return false;
    ready=true;return true;
}
int32_t wk_cable_platform_ready(void) {return ready?1:0;}
int32_t wk_cable_platform_write(uint32_t offset,const uint8_t *bytes,size_t n) {
    if(!ready||!bytes||offset>WK_SETUP_FLASH_BYTES||n>512||n>WK_SETUP_FLASH_BYTES-offset)return 0;
    for(size_t i=0;i<n;i++)RAM[offset+i]=bytes[i];
    for(size_t i=0;i<n;i++)if(RAM[offset+i]!=bytes[i]){ready=false;return 0;}
    return 1;
}
bool wk_setup_flash_read(void *context,uint32_t address,void *bytes,size_t n) {
    (void)context;uint32_t available=wk_cable_setup_size();
    if(!ready||!bytes||address>available||n>512||n>available-address)return false;
    uint8_t *out=bytes;for(size_t i=0;i<n;i++)out[i]=RAM[address+i];return true;
}
