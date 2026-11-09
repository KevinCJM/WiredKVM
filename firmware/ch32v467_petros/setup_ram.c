/* Petros V467WEU6 only. Program image is volatile, never written to CodeFlash.
 * WCH PSRAM 200MHz example (2026-10-16) defines the timing/MR contract.
 * All register waits are bounded; failed RAM leaves keyboard/mouse USB usable.
 */
#include "ch32v4x7.h"
#include "ch32v4x7_psram.h"
#include "ch32v4x7_pwr.h"
#include "setup_flash.h"
#include "setup_ram.h"

/* CPU accesses use aligned words. WCH also supports byte accesses; this is
 * an explicit ordering/read-FIFO policy for verified sequential uploads. */
#ifdef WK_RAM_MODEL
extern uint32_t wk_ram_model_load(uint32_t);
extern void wk_ram_model_store(uint32_t,uint32_t);
extern void wk_ram_model_fence(void);
#define load_word wk_ram_model_load
#define store_word wk_ram_model_store
#define barrier wk_ram_model_fence
#else
static uint32_t load_word(uint32_t at) {return *(volatile uint32_t *)(uintptr_t)(0x80000000u+at);}
static void store_word(uint32_t at,uint32_t word) {*(volatile uint32_t *)(uintptr_t)(0x80000000u+at)=word;}
static void barrier(void) {__asm__ volatile("fence iorw,iorw" ::: "memory");}
#endif
static bool ready,clocked;
/* stage, first failed byte, expected, observed, MR0/MR2/MR4, verified blocks */
static uint32_t stage,fault_at,fault_expected,fault_actual,mr[3],blocks;
static bool wait_idle(void) {
    for(unsigned n=0;n<200000;n++)if(!(PSRAM->ADDR&1u))return true;
    stage=1;ready=false;return false;
}
static bool mode(unsigned address,uint16_t value) {
    if(!wait_idle())return false;
    PSRAMSetData(value);PSRAM_Set_MR_ADDR((uint8_t)address);
    PSRAM_Set_CMD((uint8_t)(PSRAM->CMD1_CFG>>8));
    PSRAM_Set_Busy(ENABLE);PSRAM_Set_MW(ENABLE);barrier();
    return wait_idle();
}
static bool mode_read(unsigned address,uint32_t *value) {
    if(!wait_idle())return false;
    PSRAM_Set_MR_ADDR((uint8_t)address);PSRAM_Set_CMD((uint8_t)PSRAM->CMD1_CFG);
    PSRAM_Set_Busy(ENABLE);PSRAM_Set_MW(DISABLE);barrier();
    if(!wait_idle())return false;
    *value=PSRAMGetData();return true;
}
static bool verify_write(uint32_t offset,const uint8_t *bytes,size_t n) {
    size_t i=0;
    while(i<n) {
        uint32_t at=(offset+(uint32_t)i)&~3u;
        unsigned first=(offset+(uint32_t)i)&3u;
        size_t take=n-i;if(take>4-first)take=4-first;
        uint32_t word=(first||take!=4)?load_word(at):0;
        for(size_t j=0;j<take;j++) {
            unsigned shift=(first+(unsigned)j)*8;
            word=(word&~(0xffu<<shift))|((uint32_t)bytes[i+j]<<shift);
        }
        store_word(at,word);i+=take;
    }
    /* Volatile alone is not an ordering primitive between HB memory and USB. */
    barrier();
    for(i=0;i<n;) {
        uint32_t at=(offset+(uint32_t)i)&~3u,word=load_word(at);
        unsigned first=(offset+(uint32_t)i)&3u;
        for(unsigned j=first;j<4&&i<n;j++,i++) {
            uint32_t actual=(word>>(j*8))&0xffu;
            if(actual!=bytes[i]) {
                fault_at=offset+(uint32_t)i;fault_expected=bytes[i];fault_actual=actual;
                ready=false;return false;
            }
        }
    }
    blocks++;return true;
}
bool wk_setup_flash_init(void) {
    ready=false;clocked=false;stage=0;blocks=0;fault_at=0xffffffffu;
    fault_expected=fault_actual=0;for(unsigned i=0;i<3;i++)mr[i]=0xffffffffu;
    if(SystemCoreClock!=200000000u)return false;
    /* Same prerequisite as WCH's complete PSRAM example main(), outside its
     * PSRAM_INIT function. Leave USB and system clock configuration intact. */
    PWR_VDD18LevelConfig(PWR_VDD18_Level1);
    RCC_HBPeriphClockCmd(RCC_HBPeriph_PSRAM,ENABLE);clocked=true;PSRAMDeInit();
    PSRAMTimingInitTypeDef timing={0x14,0x0c,0x07};
    /* Clear the read FIFO on every CPU/DMA write, including adjacent cells. */
    PSRAMInitTypeDef config={PSRAM_CFIFO_WRADD,PSRAM_CAP_64M,PSRAM_EXIT_LPMD,&timing};
    PSRAMInit(&config);
    for(volatile unsigned n=0;n<200000;n++){} /* bounded power-up settle, before USB starts */
    PSRAMSetWrLatency(7);if(!mode(4,1u<<5))return false;
    PSRAMSetRdLatency(7);if(!mode(0,4u<<2))return false;
    if(!mode_read(0,&mr[0])||!mode_read(2,&mr[1])||!mode_read(4,&mr[2]))return false;
    /* Probe full cells, adjacent 476-byte bodies and a 1KiB page crossing,
     * then separated regions. Restricted to the unpublished 4MiB image. */
    uint8_t pattern[512];
    const uint32_t offsets[]={0,476,952,0x1000,0x100000,0x200000,0x3ffe00};
    stage=2;
    for(unsigned pass=0;pass<2;pass++)for(unsigned i=0;i<7;i++) {
        for(unsigned j=0;j<sizeof(pattern);j++)pattern[j]=(uint8_t)(0x37u+i*19u+j*13u+pass*127u);
        if(!verify_write(offsets[i],pattern,sizeof(pattern)))return false;
    }
    ready=true;stage=3;return true;
}
int32_t wk_cable_platform_ready(void) {return ready?1:0;}
int32_t wk_cable_platform_write(uint32_t offset,const uint8_t *bytes,size_t n) {
    if(!ready||!bytes||offset>WK_SETUP_FLASH_BYTES||n>512||n>WK_SETUP_FLASH_BYTES-offset)return 0;
    if(!verify_write(offset,bytes,n)){stage=4;return 0;}return 1;
}
bool wk_setup_flash_read(void *context,uint32_t address,void *bytes,size_t n) {
    (void)context;uint32_t available=wk_cable_setup_size();
    if(!ready||!bytes||address>available||n>512||n>available-address)return false;
    barrier();uint8_t *out=bytes;size_t i=0;
    while(i<n) {
        uint32_t word=load_word((address+(uint32_t)i)&~3u);
        unsigned first=(address+(uint32_t)i)&3u;
        for(unsigned j=first;j<4&&i<n;j++,i++)out[i]=(uint8_t)(word>>(j*8));
    }
    return true;
}
void wk_cable_platform_diagnostic(uint32_t *out,size_t n) {
    if(!out||n!=16)return;
    const uint32_t words[16]={2,ready,stage,fault_at,fault_expected,fault_actual,SystemCoreClock,
        clocked?PSRAM->CTLR:0,clocked?PSRAM->TIMING:0,clocked?PSRAM->LATENCY:0,
        clocked?PSRAM->CMD1_CFG:0,mr[0],mr[1],mr[2],blocks,EXTEN->EXTEN_CTR};
    for(unsigned i=0;i<16;i++)out[i]=words[i];
}
