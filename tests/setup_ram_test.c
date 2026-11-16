/* Real PSRAM adapter with a posted-write/read-FIFO/register model.
 * This is an ordering/bounds/fault test, not a physical memory timing test. */
#include "ch32v4x7_psram.h"
#include "ch32v4x7_pwr.h"
#include "setup_flash.h"
#include "setup_ram.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
TestPSRAM test_psram;
TestEXTEN test_exten;
uint32_t SystemCoreClock=200000000;
static uint32_t memory[WK_SETUP_FLASH_BYTES/4],modes[16],writes,reads,fences,available;
static uint32_t posted_at,posted_value,cache_at,cache_value,initializations;
static bool posted,cached,inject,timeout;
uint32_t wk_cable_setup_size(void){return available;}
void RCC_HBPeriphClockCmd(unsigned p,FunctionalState state){assert(p==1&&state==ENABLE);}
void PWR_VDD18LevelConfig(uint32_t level){assert(level==PWR_VDD18_Level1);EXTEN->EXTEN_CTR=level;}
void PSRAMDeInit(void){initializations++;memset(&test_psram,0,sizeof(test_psram));PSRAM->CMD1_CFG=0xffc040;modes[2]=0x88;}
void PSRAMInit(PSRAMInitTypeDef *p){assert(EXTEN->EXTEN_CTR==PWR_VDD18_Level1);PSRAM->CTLR=p->PSRAM_cfifo|p->PSRAM_cap_cfg|p->PSRAM_exti_lpmd;
    PSRAM->TIMING=p->PSRAMTimingStruct->PSRAM_trc|(p->PSRAMTimingStruct->PSRAM_tcph<<16)|(p->PSRAMTimingStruct->PSRAM_txlpd<<24);}
void PSRAMSetData(uint16_t d){PSRAM->DATA=d;}
uint16_t PSRAMGetData(void){return (uint16_t)PSRAM->DATA;}
void PSRAM_Set_MR_ADDR(uint8_t d){PSRAM->ADDR=(PSRAM->ADDR&~0xf0000)|(uint32_t)d<<16;}
void PSRAM_Set_CMD(uint8_t d){PSRAM->ADDR=(PSRAM->ADDR&~0xff00)|(uint32_t)d<<8;}
void PSRAM_Set_Busy(FunctionalState s){if(s)PSRAM->ADDR|=1;else PSRAM->ADDR&=~1u;}
void PSRAM_Set_MW(FunctionalState s){unsigned mr=(PSRAM->ADDR>>16)&15;
    if(s)modes[mr]=PSRAM->DATA;else PSRAM->DATA=modes[mr];if(!timeout)PSRAM->ADDR&=~1u;}
void PSRAMSetWrLatency(uint32_t n){PSRAM->LATENCY=(PSRAM->LATENCY&255)|(n<<8);}
void PSRAMSetRdLatency(uint32_t n){PSRAM->LATENCY=(PSRAM->LATENCY&0xff00)|n;}
static void flush(void){if(posted){memory[posted_at/4]=posted_value;posted=false;}}
void wk_ram_model_store(uint32_t at,uint32_t value){assert(!(at&3)&&at<WK_SETUP_FLASH_BYTES);
    flush();posted=true;posted_at=at;posted_value=value;writes++;
    if(PSRAM->CTLR&PSRAM_CFIFO_WRADD)cached=false;}
void wk_ram_model_fence(void){flush();fences++;}
uint32_t wk_ram_model_load(uint32_t at){assert(!(at&3)&&at<WK_SETUP_FLASH_BYTES);reads++;
    if(cached&&cache_at==at)return cache_value;
    cache_at=at;cache_value=memory[at/4]^(inject?1:0);cached=true;return cache_value;}
extern int32_t wk_cable_platform_ready(void);
extern int32_t wk_cable_platform_write(uint32_t,const uint8_t *,size_t);
extern int32_t wk_cable_platform_recover(void);
extern void wk_cable_platform_poll(uint32_t);

/* The test deliberately runs without a USB/keyboard implementation. Advancing
 * this input marker between poll calls models the single polling owner's duty
 * to return to input service; it does not measure physical input latency. */
static unsigned input_steps,recovery_polls;
static uint32_t now;
static void poll_once(void) {
    unsigned before_writes=writes,before_reads=reads;
    wk_cable_platform_poll(now++);
    assert(writes-before_writes<=128);
    assert(reads-before_reads<=128);
    input_steps++;recovery_polls++;
}
static unsigned finish_recovery(void) {
    uint32_t d[16];unsigned loops=0;
    do {
        poll_once();wk_cable_platform_diagnostic(d,16);
        assert(++loops<128); /* Also bounds a stuck busy register in model time. */
    } while(d[2]==5);
    return loops;
}
static void fail_write(const uint8_t *body) {
    uint32_t d[16];inject=true;
    assert(!wk_cable_platform_write(2048,body,512));
    wk_cable_platform_diagnostic(d,16);
    assert(!d[1]&&d[2]==4&&d[3]==2048&&d[4]==body[0]&&d[5]==(uint8_t)(body[0]^1));
    inject=false;
}
int main(void){
    assert(wk_setup_flash_init());uint32_t d[16];wk_cable_platform_diagnostic(d,16);
    assert(d[0]==3&&d[1]==1&&d[2]==3&&d[7]&PSRAM_CFIFO_WRADD);assert(d[11]==16&&d[13]==32&&d[14]==14&&d[15]==PWR_VDD18_Level1);
    uint8_t body[512],out[512];for(unsigned i=0;i<512;i++)body[i]=(uint8_t)(i*71+39);
    /* Adjacent/unaligned bodies and 1KiB page boundaries, up to the final byte. */
    const uint32_t offsets[]={0,476,952,1023,4095,WK_SETUP_FLASH_BYTES-512,WK_SETUP_FLASH_BYTES-7};
    available=WK_SETUP_FLASH_BYTES;
    for(unsigned pass=0;pass<2;pass++)for(unsigned i=0;i<7;i++){
        size_t n=i==6?7:512;body[0]^=0x5a;
        assert(wk_cable_platform_write(offsets[i],body,n));assert(wk_setup_flash_read(NULL,offsets[i],out,n));assert(!memcmp(out,body,n));
    }
    unsigned before=writes;assert(!wk_cable_platform_write(WK_SETUP_FLASH_BYTES-1,body,2));
    assert(!wk_cable_platform_write(0,body,513));assert(!wk_cable_platform_write(0,NULL,1));assert(writes==before);
    available=100;assert(!wk_setup_flash_read(NULL,99,out,2));
    /* Healthy or published storage cannot be destructively reinitialized. */
    unsigned init_before=initializations;
    before=writes;assert(!wk_cable_platform_recover());
    assert(wk_setup_flash_init()); /* Repeated boot init is a read-only ready query. */
    assert(initializations==init_before&&writes==before&&wk_cable_platform_ready());

    available=0;fail_write(body);
    before=writes;assert(!wk_cable_platform_write(0,body,512));assert(writes==before);
    /* First attempt recovers a transient readback fault. Repeated requests must
     * neither restart this attempt nor consume the second firmware-boot budget. */
    assert(wk_cable_platform_recover());
    wk_cable_platform_diagnostic(d,16);assert(!d[1]&&d[2]==5);
    assert(initializations==init_before);
    for(unsigned i=0;i<8;i++)assert(wk_cable_platform_recover());
    now=100;unsigned first_polls=finish_recovery();
    assert(first_polls>=14); /* 14 probe blocks cannot execute in one service pass. */
    wk_cable_platform_diagnostic(d,16);assert(d[1]&&d[2]==3);
    assert(initializations==init_before+1);
    assert(wk_cable_platform_write(2048,body,512));
    available=WK_SETUP_FLASH_BYTES;
    assert(wk_setup_flash_read(NULL,2048,out,512));assert(!memcmp(out,body,512));
    init_before=initializations;before=writes;
    assert(!wk_cable_platform_recover());assert(wk_setup_flash_init());
    for(unsigned i=0;i<8;i++)poll_once();
    assert(initializations==init_before&&writes==before);
    /* An unavailable published volume still forbids recovery. */
    fail_write(body);before=writes;
    assert(!wk_cable_platform_recover());assert(!wk_setup_flash_init());
    for(unsigned i=0;i<8;i++)poll_once();
    assert(initializations==init_before&&writes==before);

    /* Second attempt waits on one busy check per poll and expires across the
     * uint32_t millisecond wrap. The caller continues servicing input. */
    available=0;timeout=true;
    assert(wk_cable_platform_recover());now=UINT32_MAX-8u;
    unsigned timeout_polls=finish_recovery();
    wk_cable_platform_diagnostic(d,16);assert(!d[1]&&d[2]==6);
    assert(timeout_polls<=64);
    assert(initializations==init_before+1);
    timeout=false;init_before=initializations;before=writes;
    assert(!wk_setup_flash_init()); /* Boot entry cannot reset the attempt budget. */
    for(unsigned i=0;i<32;i++) {
        assert(!wk_cable_platform_recover());poll_once();
    }
    assert(initializations==init_before&&writes==before);
    wk_cable_platform_diagnostic(d,16);assert(!d[1]&&d[2]==6);
    assert(input_steps==recovery_polls&&input_steps>first_polls+timeout_polls);
    printf("PSRAM_ADAPTER_PASS writes=%u reads=%u fences=%u recovery_polls=%u input_steps=%u posted_write_model=true fault_telemetry=true recovery_bounded=true publication_protected=true physicalPSRAM=false\n",writes,reads,fences,recovery_polls,input_steps);
}
