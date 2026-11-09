/* Synthetic flash and BOT only; no device, mounted filesystem or real input. */
#include "setup_msc.h"
#include "bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static uint8_t flash[4096+16384], before[sizeof(flash)];
static unsigned reads,max_read,checks;static uint32_t tag;
#define CHECK(x) do { assert(x);checks++; } while(0)
static uint32_t crc(const uint8_t *p,size_t n) { uint32_t v=~0u;while(n--){v^=*p++;for(unsigned j=0;j<8;j++)v=(v>>1)^((v&1)?0xedb88320u:0);}return ~v; }
static void le(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(i*8));}
static uint32_t getle(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void be(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[3-i]=(uint8_t)(v>>(i*8));}
static bool read_flash(void *context,uint32_t at,void *p,size_t n){(void)context;reads++;if(n>max_read)max_read=(unsigned)n;if(at>sizeof(flash)||n>sizeof(flash)-at)return false;memcpy(p,flash+at,n);return true;}
static void fixture(wk_setup *s){
    memset(flash,0,sizeof(flash));for(unsigned i=4096;i<sizeof(flash);i++)flash[i]=(uint8_t)(i*37u+i/256);
    memcpy(flash,"WKDUAL01",8);le(flash+8,1);le(flash+12,sizeof(flash)-4096);le(flash+16,crc(flash+4096,sizeof(flash)-4096));le(flash+20,crc(flash,20));
    memcpy(before,flash,sizeof(flash));wk_setup_init(s,read_flash,NULL);
    for(unsigned i=0;i<32;i++)wk_setup_tick(s,i);
    CHECK(s->valid&&!s->validating);CHECK(max_read<=512);
    wk_setup_connected(s,0,true,0);wk_setup_connected(s,1,true,0);
}
static void cbw(uint8_t *b,uint8_t opcode,uint32_t n,bool in){memset(b,0,31);le(b,0x43425355);le(b+4,++tag);le(b+8,n);b[12]=in?128:0;b[14]=16;b[15]=opcode;}
static unsigned transact(wk_setup *s,unsigned port,uint8_t *b,uint8_t *out,unsigned capacity,unsigned expected_status) {
    CHECK(wk_setup_msc_out(s,port,b,31,2000));unsigned got=0;
    for(unsigned limit=0;limit<100;limit++) {
        size_t n=0;const uint8_t *p=wk_setup_msc_in(s,port,&n);CHECK(p&&n&&n<=512);
        if(n==13&&getle(p)==0x53425355) {CHECK(getle(p+4)==tag);CHECK(p[12]==expected_status);wk_setup_msc_done(s,port);return got;}
        CHECK(got+n<=capacity);memcpy(out+got,p,n);got+=(unsigned)n;wk_setup_msc_done(s,port);
    }
    CHECK(false);return 0;
}
static void lease(uint8_t *b,unsigned port,bool hide,uint32_t sequence){memset(b,0,64);memcpy(b,"WKI1",4);b[4]=1;b[5]=(uint8_t)port;b[6]=hide?2:1;le(b+8,sequence);le(b+60,crc(b,60));}
static bool local(void *context,unsigned p,const uint8_t *b,size_t n){return wk_setup_control(context,p,b,n,2000);}
int main(void) {
    wk_setup s;uint8_t b[64],out[16384];fixture(&s);
    /* A newly uploaded image must not wipe an outstanding SCSI reply. */
    s.valid=false;s.validating=false;
    cbw(b,0x12,36,true);CHECK(wk_setup_msc_out(&s,1,b,31,2000));
    wk_setup_port pending=s.ports[1];wk_setup_refresh(&s);
    CHECK(!memcmp(&pending,&s.ports[1],sizeof(pending))&&s.validating);
    for(unsigned n=0;n<32;n++)wk_setup_tick(&s,n);
    CHECK(s.valid);wk_setup_msc_reset(&s,1);
    CHECK(!wk_setup_ready(&s,0,1499));CHECK(wk_setup_ready(&s,0,1500));CHECK(wk_setup_ready(&s,1,1500));
    for(unsigned p=0;p<2;p++) {
        cbw(b,0x12,36,true);b[19]=36;CHECK(transact(&s,p,b,out,sizeof(out),0)==36);CHECK(out[1]==128&&!memcmp(out+8,"WiredKVM",8));
        cbw(b,0x25,8,true);CHECK(transact(&s,p,b,out,sizeof(out),0)==8);CHECK(out[3]==31&&out[6]==2);
        cbw(b,0x28,16384,true);b[22]=0;b[23]=32;CHECK(transact(&s,p,b,out,sizeof(out),0)==16384);CHECK(!memcmp(out,flash+4096,16384));
        cbw(b,0x28,512,true);be(b+17,32);b[23]=1;CHECK(transact(&s,p,b,out,sizeof(out),1)==0);
        cbw(b,0x03,18,true);b[19]=18;CHECK(transact(&s,p,b,out,sizeof(out),0)==18);CHECK(out[2]==5&&out[12]==0x21);
        cbw(b,0x1a,4,true);b[19]=4;CHECK(transact(&s,p,b,out,sizeof(out),0)==4);CHECK(out[2]&128);
        cbw(b,0x2a,1024,false);CHECK(wk_setup_msc_out(&s,p,b,31,2000));memset(out,0xa5,512);
        CHECK(wk_setup_msc_out(&s,p,out,512,2000));CHECK(wk_setup_msc_out(&s,p,out,512,2000));
        size_t n=0;const uint8_t *csw=wk_setup_msc_in(&s,p,&n);CHECK(n==13&&csw[12]==1);wk_setup_msc_done(&s,p);
        cbw(b,0x03,18,true);b[19]=18;CHECK(transact(&s,p,b,out,sizeof(out),0)==18);CHECK(out[2]==7&&out[12]==0x27);
    }
    CHECK(!memcmp(before,flash,sizeof(flash)));
    /* One side can install and suppress its own medium without a peer app. */
    fixture(&s);wk_setup_connected(&s,1,false,0);lease(b,0,false,1);CHECK(wk_setup_control(&s,0,b,64,500));
    wk_setup_tick(&s,500);CHECK(!wk_setup_ready(&s,0,2000));
    CHECK(!wk_setup_control(&s,1,b,64,501));CHECK(!wk_setup_control(&s,0,b,64,502));
    b[20]^=1;CHECK(!wk_setup_control(&s,0,b,64,502));wk_setup_tick(&s,4501);CHECK(wk_setup_ready(&s,0,4501));
    lease(b,0,false,2);CHECK(wk_setup_control(&s,0,b,64,4502));wk_setup_tick(&s,4502);CHECK(wk_setup_ready(&s,0,4502));
    cbw(b,0x1e,0,false);b[19]=1;CHECK(transact(&s,0,b,out,sizeof(out),0)==0);
    lease(b,0,true,3);CHECK(wk_setup_control(&s,0,b,64,4503));wk_setup_tick(&s,4503);CHECK(wk_setup_ready(&s,0,4503));
    cbw(b,0x1e,0,false);CHECK(transact(&s,0,b,out,sizeof(out),0)==0);wk_setup_tick(&s,4504);CHECK(!wk_setup_ready(&s,0,4504));
    wk_setup_connected(&s,0,true,5000);CHECK(wk_setup_ready(&s,0,6500));
    cbw(b,0x1b,0,false);b[19]=2;CHECK(transact(&s,0,b,out,sizeof(out),0)==0);wk_setup_tick(&s,12000);CHECK(!wk_setup_ready(&s,0,12000));
    wk_setup_connected(&s,0,true,13000);CHECK(wk_setup_ready(&s,0,14500));
    memset(b,0,31);CHECK(!wk_setup_msc_out(&s,0,b,31,14500));CHECK(!wk_setup_msc_wants_out(&s,0));wk_setup_msc_reset(&s,0);CHECK(wk_setup_msc_wants_out(&s,0));
    /* Setup presence is local, consumes no peer control queue, preserves HID. */
    fixture(&s);static wk407_bridge bridge;wk407_init(&bridge);wk407_connected(&bridge,0,true,2000);
    bridge.local_report=local;bridge.local_context=&s;lease(b,0,false,10);
    CHECK(wk407_clipboard(&bridge,0,b,64));CHECK(!bridge.clipboard[1].count&&!bridge.online[1]);
    flash[4097]^=1;wk_setup_init(&s,read_flash,NULL);for(unsigned i=0;i<32;i++)wk_setup_tick(&s,i);CHECK(!s.valid);
    memcpy(flash,before,sizeof(flash));flash[20]^=1;wk_setup_init(&s,read_flash,NULL);CHECK(!s.validating&&!s.valid);
    /* Truncated/random CBWs must never read beyond their 31-byte input. */
    fixture(&s);uint32_t random=7;
    for(unsigned k=0;k<20000;k++) {
        for(unsigned j=0;j<31;j++){random^=random<<13;random^=random>>17;random^=random<<5;b[j]=(uint8_t)random;}
        (void)wk_setup_msc_out(&s,k&1,b,k%32,2000);wk_setup_msc_reset(&s,k&1);
    }
    static const uint8_t commands[]={0,0x12,3,0x1a,0x5a,0x25,0x23,0x9e,0x28,0xa8,0x88,0x1b,0x1e,0x2a};
    for(unsigned k=0;k<5000;k++) {
        unsigned port=k&1;cbw(b,commands[k%(sizeof(commands))],(k%9)*64,(k&2)!=0);
        for(unsigned j=16;j<31;j++){random^=random<<13;random^=random>>17;random^=random<<5;b[j]=(uint8_t)random;}
        b[14]=(uint8_t)(1+k%16);(void)wk_setup_msc_out(&s,port,b,31,2000);
        size_t n=0;const uint8_t *reply=wk_setup_msc_in(&s,port,&n);
        if(reply){CHECK(n<=512);wk_setup_msc_done(&s,port);}
        wk_setup_msc_reset(&s,port);
    }
    CHECK(!memcmp(flash,before,sizeof(flash)));
    printf("SETUP_MSC_PASS checks=%u invalid_cbw_fuzz=20000 scsi_fuzz=5000 fixed_state_bytes=%zu max_flash_read=%u independent_roles=true readonly=true physicalUSB=false\n",checks,sizeof(s),max_read);
}
