/* Real Rust Upload/C ABI + real C PSRAM, MSC and input bridge.
 * Only registers, memory bus and elapsed time are modeled; no device I/O.
 * Each scenario runs in its own process: USB resets do not reset C statics. */
#include "ch32v4x7_psram.h"
#include "ch32v4x7_pwr.h"
#include "setup_flash.h"
#include "setup_ram.h"
#include "setup_msc.h"
#include "bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { CELL=512, BODY=476, QUERY=0, BEGIN=1, DATA=2, FINISH=3, RECOVER=6 };
enum { ACCEPTED=0, SEALED=1, BUSY=2, INVALID=3, UNAVAILABLE=4, STALE=5, STORAGE=7 };
#define IMAGE_BYTES (2u*1024u*1024u)
#define ASSET_BYTES (WK_SETUP_IMAGE_OFFSET+IMAGE_BYTES)
TestPSRAM test_psram;
TestEXTEN test_exten;
uint32_t SystemCoreClock=200000000;
static uint32_t memory[WK_SETUP_FLASH_BYTES/4],modes[16],writes,reads,resets,asset_crc;
static uint8_t asset[ASSET_BYTES];
static uint32_t posted_at,posted_word,cache_at,cache_word,now,input_steps,input_reports;
static bool posted,cached,inject;
static wk407_bridge bridge;
extern int32_t wk_cable_platform_ready(void);
extern int32_t wk_cable_platform_recover(void);
extern int32_t wk_cable_platform_write(uint32_t,const uint8_t *,size_t);

void RCC_HBPeriphClockCmd(unsigned p,FunctionalState state){assert(p==1&&state==ENABLE);}
void PWR_VDD18LevelConfig(uint32_t level){assert(level==PWR_VDD18_Level1);EXTEN->EXTEN_CTR=level;}
void PSRAMDeInit(void){
    memset(&test_psram,0,sizeof(test_psram));PSRAM->CMD1_CFG=0xffc040;
    modes[2]=0x88;posted=cached=false;resets++;
}
void PSRAMInit(PSRAMInitTypeDef *p){
    assert(EXTEN->EXTEN_CTR==PWR_VDD18_Level1);
    PSRAM->CTLR=p->PSRAM_cfifo|p->PSRAM_cap_cfg|p->PSRAM_exti_lpmd;
    PSRAM->TIMING=p->PSRAMTimingStruct->PSRAM_trc|(p->PSRAMTimingStruct->PSRAM_tcph<<16)|(p->PSRAMTimingStruct->PSRAM_txlpd<<24);
}
void PSRAMSetData(uint16_t d){PSRAM->DATA=d;}
uint16_t PSRAMGetData(void){return (uint16_t)PSRAM->DATA;}
void PSRAM_Set_MR_ADDR(uint8_t d){PSRAM->ADDR=(PSRAM->ADDR&~0xf0000u)|(uint32_t)d<<16;}
void PSRAM_Set_CMD(uint8_t d){PSRAM->ADDR=(PSRAM->ADDR&~0xff00u)|(uint32_t)d<<8;}
void PSRAM_Set_Busy(FunctionalState s){if(s)PSRAM->ADDR|=1;else PSRAM->ADDR&=~1u;}
void PSRAM_Set_MW(FunctionalState s){
    unsigned mr=(PSRAM->ADDR>>16)&15;
    if(s)modes[mr]=PSRAM->DATA;else PSRAM->DATA=modes[mr];
    PSRAM->ADDR&=~1u;
}
void PSRAMSetWrLatency(uint32_t n){PSRAM->LATENCY=(PSRAM->LATENCY&255)|(n<<8);}
void PSRAMSetRdLatency(uint32_t n){PSRAM->LATENCY=(PSRAM->LATENCY&0xff00)|n;}
static void flush(void){if(posted){memory[posted_at/4]=posted_word;posted=false;}}
void wk_ram_model_store(uint32_t at,uint32_t value){
    assert(!(at&3)&&at<WK_SETUP_FLASH_BYTES);flush();
    posted=true;posted_at=at;posted_word=value;writes++;
    if(PSRAM->CTLR&PSRAM_CFIFO_WRADD)cached=false;
}
void wk_ram_model_fence(void){flush();}
uint32_t wk_ram_model_load(uint32_t at){
    assert(!(at&3)&&at<WK_SETUP_FLASH_BYTES);reads++;
    if(cached&&cache_at==at)return cache_word;
    cache_at=at;cache_word=memory[at/4]^(inject?1u:0u);cached=true;return cache_word;
}
void wk_cable_forward(const uint8_t *p,size_t n){assert(n==CELL);assert(wk407_bulk_accept(&bridge,0,p,n));}
static uint32_t crc32(const uint8_t *p,size_t n){
    uint32_t c=UINT32_MAX;
    while(n--){c^=*p++;for(unsigned j=0;j<8;j++)c=(c>>1)^((c&1)?0xedb88320u:0);}
    return ~c;
}
static void little(uint8_t *p,uint64_t value,unsigned n){for(unsigned i=0;i<n;i++)p[i]=(uint8_t)(value>>(i*8));}
static uint32_t le32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void command(char kind,int a,int b){
    char line[96];unsigned seq=++input_steps%65536;
    int n=snprintf(line,sizeof(line),"WK1,%u,%c,%d,%d",seq,kind,a,b);
    uint8_t crc=wk_crc8((const uint8_t *)line,(size_t)n);
    n+=snprintf(line+n,sizeof(line)-(size_t)n,",%02x\n",crc);
    wk407_control(&bridge,(const uint8_t *)line,(size_t)n,now);
    const wk407_control_packet *r=wk407_reply_peek(&bridge);
    assert(r&&!memcmp(r->bytes,"ACK,",4));wk407_reply_done(&bridge);
    assert(wk407_hid_peek(&bridge));
    while(wk407_hid_peek(&bridge)){input_reports++;wk407_hid_done(&bridge);}
}
static void service(void){
    /* Same ordering rule as real main: input service precedes RAM/MSC work. */
    now++;wk407_tick(&bridge,now);
    command('A',(int)(now%32768),17);command('K',0,(now&1)?4:0);
    unsigned w=writes,r=reads;
    wk_cable_platform_poll(now);
    assert(writes-w<=128&&reads-r<=128);
}
static unsigned exchange(unsigned operation,uint64_t session,uint32_t offset,const uint8_t *body,size_t n){
    assert(n<=BODY);uint8_t cell[CELL]={0},ack[CELL];
    memcpy(cell,"WKIM",4);cell[4]=1;cell[5]=(uint8_t)operation;
    little(cell+8,session,8);little(cell+16,offset,4);
    bool envelope=operation==BEGIN||operation==DATA||operation==FINISH;
    little(cell+20,envelope?ASSET_BYTES:0,4);little(cell+24,envelope?asset_crc:0,4);
    little(cell+28,n,2);if(n)memcpy(cell+32,body,n);little(cell+508,crc32(cell,508),4);
    assert(!wk_cable_setup_pending());
    /* Exercise the production ABI's partial-cell assembly as well. */
    wk_cable_setup_input(cell,37);wk_cable_setup_input(cell+37,CELL-37);
    assert(wk_cable_setup_ack(ack,sizeof(ack))==CELL);assert(!memcmp(ack,"WKIA",4));
    assert(le32(ack+508)==crc32(ack,508));wk_cable_setup_ack_submitted();
    return ack[5];
}
static void setup(void){
    wk407_init(&bridge);wk407_connected(&bridge,0,true,0);wk407_connected(&bridge,1,true,0);
    assert(wk_setup_flash_init());assert(resets==1);
    for(unsigned i=0;i<ASSET_BYTES;i++)asset[i]=(uint8_t)(i*71u+(i>>10)*13u+39u);
    memcpy(asset,"WKDUAL01",8);little(asset+8,1,4);little(asset+12,IMAGE_BYTES,4);
    little(asset+16,crc32(asset+WK_SETUP_IMAGE_OFFSET,IMAGE_BYTES),4);little(asset+20,crc32(asset,20),4);
    asset_crc=crc32(asset,ASSET_BYTES);
}
static void fail_upload(void){
    assert(exchange(BEGIN,19,0,NULL,0)==ACCEPTED);
    assert(exchange(DATA,19,0,asset,BODY)==ACCEPTED);
    inject=true;assert(exchange(DATA,19,BODY,asset+BODY,BODY)==STORAGE);
    assert(!wk_cable_platform_ready()&&!wk_cable_setup_size());
    unsigned w=writes;assert(exchange(QUERY,0,0,NULL,0)==UNAVAILABLE);
    assert(exchange(DATA,19,BODY,asset+BODY,BODY)==UNAVAILABLE&&writes==w);
}
static void recover_once(bool succeeds){
    unsigned before=resets;
    assert(exchange(RECOVER,0,0,NULL,0)==BUSY);
    assert(resets==before); /* The command only schedules cooperative work. */
    assert(exchange(RECOVER,0,0,NULL,0)==BUSY&&resets==before);
    assert(exchange(BEGIN,20,0,NULL,0)==UNAVAILABLE);
    wk_cable_setup_reset();wk_cable_setup_peer_reset();
    inject=!succeeds;
    uint32_t status[16];unsigned steps=0,reported=input_reports;
    do{service();wk_cable_platform_diagnostic(status,16);assert(++steps<100);}while(status[2]==5);
    assert(resets==before+1&&input_reports>reported);
    assert((wk_cable_platform_ready()!=0)==succeeds);
}
static void complete_upload(void){
    /* Old session cannot continue after recovery and no partial image is exposed. */
    assert(exchange(DATA,19,BODY,asset+BODY,BODY)==STALE);
    assert(exchange(BEGIN,41,0,NULL,0)==ACCEPTED);
    unsigned w=writes,before=resets;
    assert(exchange(RECOVER,0,0,NULL,0)==BUSY&&writes==w&&resets==before);
    for(uint32_t offset=0;offset<ASSET_BYTES;){
        size_t n=ASSET_BYTES-offset;if(n>BODY)n=BODY;
        assert(exchange(DATA,41,offset,asset+offset,n)==ACCEPTED);offset+=(uint32_t)n;service();
    }
    assert(exchange(FINISH,41,ASSET_BYTES,NULL,0)==SEALED);
    assert(wk_cable_setup_size()==ASSET_BYTES);
    assert(wk_cable_setup_changed()==ASSET_BYTES&&!wk_cable_setup_changed());
    assert(!memcmp(memory,asset,ASSET_BYTES));
}
static void final_crc(bool corrupt){
    wk_setup msc;wk_setup_init(&msc,wk_setup_flash_read,NULL);
    wk_setup_connected(&msc,1,true,0);assert(msc.validating&&!msc.valid);
    if(corrupt){memory[(WK_SETUP_IMAGE_OFFSET+1024)/4]^=0x01000000u;cached=false;}
    unsigned steps=0;
    while(msc.validating){service();wk_setup_tick(&msc,now);assert(++steps<=IMAGE_BYTES/CELL);}
    assert(msc.valid==!corrupt);assert(wk_setup_ready(&msc,1,now+1500)==!corrupt);
    unsigned w=writes,before=resets;
    assert(exchange(RECOVER,0,0,NULL,0)==BUSY);
    assert(!wk_cable_platform_recover());assert(wk_setup_flash_init());
    for(unsigned i=0;i<20;i++)service();
    assert(writes==w&&resets==before&&wk_cable_setup_size()==ASSET_BYTES);
    wk_cable_setup_reset();wk_cable_setup_peer_reset();
    assert(wk_cable_setup_size()==ASSET_BYTES&&exchange(QUERY,0,0,NULL,0)==SEALED);
}
int main(int argc,char **argv){
    assert(argc==2);setup();fail_upload();
    unsigned w=writes,before=resets;
    assert(exchange(RECOVER,1,0,NULL,0)==INVALID&&writes==w&&resets==before);
    if(!strcmp(argv[1],"exhausted")){
        recover_once(false);recover_once(false);inject=false;
        wk_cable_setup_reset();wk_cable_setup_peer_reset();
        w=writes;before=resets;
        for(unsigned i=0;i<8;i++){assert(exchange(RECOVER,0,0,NULL,0)==UNAVAILABLE);service();}
        assert(writes==w&&resets==before&&resets==3&&!wk_cable_platform_ready());
        uint32_t status[16];wk_cable_platform_diagnostic(status,16);assert(status[2]==6);
    }else{
        bool corrupt=!strcmp(argv[1],"physical-crc");assert(corrupt||!strcmp(argv[1],"recover"));
        recover_once(true);assert(exchange(QUERY,0,0,NULL,0)==ACCEPTED);
        w=writes;before=resets;assert(exchange(RECOVER,0,0,NULL,0)==ACCEPTED&&writes==w&&resets==before);
        complete_upload();final_crc(corrupt);
    }
    printf("PSRAM_RECOVERY_INTEGRATION_PASS scenario=%s inputSteps=%u reports=%u resets=%u physicalUSB=false physicalPSRAM=false\n",argv[1],input_steps,input_reports,resets);
}
