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
static bool ready,clocked,initialized;
/* stage, first failed byte, expected, observed, MR0/MR2/MR4, verified blocks */
static uint32_t stage,fault_at,fault_expected,fault_actual,mr[3],blocks;
/* Budget belongs to this firmware boot, not a USB connection or uploader process. */
enum { RECOVERY_LIMIT=2, WAIT_MS=20, SETTLE_MS=2 };
enum { WK_RAM_REC_IDLE, WK_RAM_REC_RESET, WK_RAM_REC_SETTLE, WK_RAM_REC_WRITE4, WK_RAM_REC_WAIT4, WK_RAM_REC_WRITE0, WK_RAM_REC_WAIT0, WK_RAM_REC_READ_MR, WK_RAM_REC_WAIT_MR, WK_RAM_REC_PROBE };
static unsigned recovery_phase,recoveries,probe_index,mr_index;
static uint32_t phase_at;
static const uint32_t probe_offsets[]={0,476,952,0x1000,0x100000,0x200000,0x3ffe00};
static const unsigned mr_addresses[]={0,2,4};
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
static void configure(void) {
    /* Same prerequisite as WCH's complete PSRAM example main(), outside its
     * PSRAM_INIT function. Leave USB and system clock configuration intact. */
    PWR_VDD18LevelConfig(PWR_VDD18_Level1);
    RCC_HBPeriphClockCmd(RCC_HBPeriph_PSRAM,ENABLE);clocked=true;PSRAMDeInit();
    PSRAMTimingInitTypeDef timing={0x14,0x0c,0x07};
    /* Clear the read FIFO on every CPU/DMA write, including adjacent cells. */
    PSRAMInitTypeDef config={PSRAM_CFIFO_WRADD,PSRAM_CAP_64M,PSRAM_EXIT_LPMD,&timing};
    PSRAMInit(&config);
}
static bool probe(unsigned index) {
    uint8_t pattern[512];unsigned i=index%7,pass=index/7;
    for(unsigned j=0;j<sizeof(pattern);j++)pattern[j]=(uint8_t)(0x37u+i*19u+j*13u+pass*127u);
    return verify_write(probe_offsets[i],pattern,sizeof(pattern));
}
bool wk_setup_flash_init(void) {
    /* This is a boot-only entry point. Retries must go through the bounded,
     * cooperative recovery path, never this synchronous pre-USB initializer. */
    if(initialized||wk_cable_setup_size())return ready;
    initialized=true;ready=false;clocked=false;stage=0;blocks=0;fault_at=0xffffffffu;
    fault_expected=fault_actual=0;for(unsigned i=0;i<3;i++)mr[i]=0xffffffffu;
    if(SystemCoreClock!=200000000u)return false;
    configure();
    for(volatile unsigned n=0;n<200000;n++){} /* bounded power-up settle, before USB starts */
    PSRAMSetWrLatency(7);if(!mode(4,1u<<5))return false;
    PSRAMSetRdLatency(7);if(!mode(0,4u<<2))return false;
    if(!mode_read(0,&mr[0])||!mode_read(2,&mr[1])||!mode_read(4,&mr[2]))return false;
    /* Probe full cells, adjacent 476-byte bodies and a 1KiB page crossing,
     * then separated regions. Restricted to the unpublished 4MiB image. */
    stage=2;
    for(unsigned i=0;i<14;i++)if(!probe(i))return false;
    ready=true;stage=3;return true;
}
int32_t wk_cable_platform_recover(void) {
    if(ready||wk_cable_setup_size())return 0;
    if(recovery_phase!=WK_RAM_REC_IDLE)return 1; /* idempotent; no extra budget */
    if(recoveries>=RECOVERY_LIMIT){stage=6;return 0;}
    if(stage!=1&&stage!=2&&stage!=4)return 0;
    recoveries++;recovery_phase=WK_RAM_REC_RESET;stage=5;return 1;
}
static void recovery_failed(uint32_t reason) {
    ready=false;recovery_phase=WK_RAM_REC_IDLE;stage=recoveries>=RECOVERY_LIMIT?6:reason;
}
void wk_cable_platform_poll(uint32_t now) {
    if(recovery_phase==WK_RAM_REC_IDLE)return;
    /* Defence in depth: never touch a published source, even if the caller's
     * protocol guard was bypassed. Do not reset either USB controller. */
    if(wk_cable_setup_size()){recovery_phase=WK_RAM_REC_IDLE;stage=ready?3:4;return;}
    switch(recovery_phase) {
    case WK_RAM_REC_RESET:
        if(SystemCoreClock!=200000000u){recovery_failed(1);return;}
        configure();phase_at=now;recovery_phase=WK_RAM_REC_SETTLE;return;
    case WK_RAM_REC_SETTLE:
        if((uint32_t)(now-phase_at)>=SETTLE_MS)recovery_phase=WK_RAM_REC_WRITE4;
        return;
    case WK_RAM_REC_WRITE4:case WK_RAM_REC_WRITE0:case WK_RAM_REC_READ_MR: {
        if(PSRAM->ADDR&1u){recovery_failed(1);return;}
        bool read=recovery_phase==WK_RAM_REC_READ_MR;
        unsigned address=read?mr_addresses[mr_index]:(recovery_phase==WK_RAM_REC_WRITE4?4:0);
        if(!read){
            if(address==4){PSRAMSetWrLatency(7);PSRAMSetData(1u<<5);}
            else {PSRAMSetRdLatency(7);PSRAMSetData(4u<<2);}
        }
        PSRAM_Set_MR_ADDR((uint8_t)address);
        PSRAM_Set_CMD((uint8_t)(PSRAM->CMD1_CFG>>(read?0:8)));
        PSRAM_Set_Busy(ENABLE);PSRAM_Set_MW(read?DISABLE:ENABLE);barrier();
        phase_at=now;recovery_phase=read?WK_RAM_REC_WAIT_MR:(address==4?WK_RAM_REC_WAIT4:WK_RAM_REC_WAIT0);return;
    }
    case WK_RAM_REC_WAIT4:case WK_RAM_REC_WAIT0:case WK_RAM_REC_WAIT_MR:
        if(PSRAM->ADDR&1u){
            if((uint32_t)(now-phase_at)>=WAIT_MS)recovery_failed(1);
            return; /* one busy check; no spinning while input is live */
        }
        if(recovery_phase==WK_RAM_REC_WAIT4)recovery_phase=WK_RAM_REC_WRITE0;
        else if(recovery_phase==WK_RAM_REC_WAIT0){mr_index=0;recovery_phase=WK_RAM_REC_READ_MR;}
        else {
            mr[mr_index++]=PSRAMGetData();
            if(mr_index<3)recovery_phase=WK_RAM_REC_READ_MR;
            else {probe_index=0;recovery_phase=WK_RAM_REC_PROBE;}
        }
        return;
    case WK_RAM_REC_PROBE:
        if(!probe(probe_index++)){recovery_failed(2);return;}
        if(probe_index==14){ready=true;stage=3;recovery_phase=WK_RAM_REC_IDLE;}
        return; /* at most one 512-byte probe per input-service pass */
    default:recovery_failed(1);return;
    }
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
    const uint32_t words[16]={3,ready,stage,fault_at,fault_expected,fault_actual,SystemCoreClock,
        clocked?PSRAM->CTLR:0,clocked?PSRAM->TIMING:0,clocked?PSRAM->LATENCY:0,
        clocked?PSRAM->CMD1_CFG:0,mr[0],mr[1],mr[2],blocks,EXTEN->EXTEN_CTR};
    for(unsigned i=0;i<16;i++)out[i]=words[i];
}
