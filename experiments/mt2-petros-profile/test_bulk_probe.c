#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "bridge.h"
typedef struct {unsigned port;} usbd_handle_t;
static usbd_handle_t a={0},b={1},*handles[2]={&a,&b};
static wk407_bridge bridge;
static bool busy[2][8];static uint32_t tx_epoch[2][8];static uint8_t tx_kind[2][8];
static const void *dma[2];static unsigned dma_size[2],fail_upload,normal_count;
static uint8_t normal[4096],dma_copy[2][16384];
static bool normal_boundary=true;
static bool loader_pending;
static bool wk_cable_setup_at_boundary(void){return normal_boundary;}
static uint32_t wk_cable_setup_size(void){return 4096;}
static int32_t wk_cable_setup_pending(void){return loader_pending;}
#define USB_SPEED_HIGH 2
#define USB_RST_OK 0
static int speed=2;
static int usbd_get_speed(usbd_handle_t *h){(void)h;return speed;}
static int usbd_upload(usbd_handle_t *h,uint8_t ep,const void *p,unsigned n){
    unsigned i=h->port;assert(ep==(i?0x85:0x84));assert(!busy[i][ep&127]);assert(n<=sizeof(dma_copy[i]));
    if(fail_upload){fail_upload--;return -1;}dma[i]=p;dma_size[i]=n;memcpy(dma_copy[i],p,n);return 0;
}
static void wk_cable_setup_input(const uint8_t *p,size_t n){assert(normal_count+n<=sizeof(normal));memcpy(normal+normal_count,p,n);normal_count+=(unsigned)n;}
/* Rename only the local shim: actual bridge code is still separately linked. */
#include "bulk_probe.h"
static unsigned tick=1;
static void done(unsigned p){unsigned e=p?5:4;assert(busy[p][e]&&wk_probe_current(p));assert(!memcmp(dma[p],dma_copy[p],dma_size[p]));wk_probe_done(p,tx_kind[p][e],++tick);busy[p][e]=false;}
static void service(unsigned p){wk_probe_service(p,p?5:4,++tick);}
static void reset(void){for(unsigned p=0;p<2;p++){busy[p][p?5:4]=false;wk_probe_reset(p);}normal_count=0;normal_boundary=true;}
static void command(unsigned p,unsigned op,uint64_t nonce,uint64_t total,unsigned fragment){
    uint8_t c[64]={0};memcpy(c,"WKBP",4);c[4]=1;c[5]=(uint8_t)op;wk_probe_put(c+8,nonce,8);wk_probe_put(c+16,total,8);wk_probe_put(c+60,wk_probe_crc(c,60),4);
    for(unsigned at=0;at<64;){unsigned n=64-at;if(n>fragment)n=fragment;assert(wk_probe_input(p,c+at,n,++tick));at+=n;}
}
static void begin(unsigned p,unsigned op,uint64_t n,unsigned fragment){command(p,op,91,n,fragment);service(p);assert(dma_size[p]==64&&dma_copy[p][5]==1);done(p);assert(wk_probe_ports[p].phase==2);}
int main(void){
    wk407_init(&bridge);
    bridge.online[0]=bridge.online[1]=true;assert(!wk_probe_idle_arm(0)&&!wk_probe_idle_arm(1));
    bridge.online[1]=false;assert(wk_probe_idle_arm(0));loader_pending=true;assert(!wk_probe_idle_arm(0));loader_pending=false;
    for(unsigned part=1;part<=64;part++){
        reset();begin(0,1,8192,part);uint8_t data[512];memset(data,0xa5,512);
        for(unsigned i=0;i<16;i++)assert(wk_probe_input(0,data,512,++tick));
        service(0);assert(dma_copy[0][5]==2&&wk_probe_u64(dma_copy[0]+24)==8192);done(0);assert(!wk_probe_active(0));
        reset();begin(1,2,16384,part);
        unsigned bytes=0;
        while(bytes<16384){service(1);assert(dma_size[1]<=sizeof(wk_probe_ports[1].dma));for(unsigned j=0;j<dma_size[1];j++)assert(dma_copy[1][j]==0xa5);bytes+=dma_size[1];done(1);}
        service(1);assert(bytes==16384&&dma_copy[1][5]==2&&wk_probe_u64(dma_copy[1]+32)==16384);done(1);
    }
    for(unsigned direction=0;direction<2;direction++){
        reset();unsigned src=direction,dst=1-direction;begin(dst,5,32768,7);begin(src,4,32768,13);
        uint8_t cell[512];memset(cell,0xa5,512);unsigned accepted=0,delivered=0;
        while(delivered<32768){
            while(accepted<32768&&wk_probe_space(src)){assert(wk_probe_input(src,cell,512,++tick));accepted+=512;}
            assert(wk_probe_ports[dst].count<=WK_PROBE_SLOTS);service(dst);assert(dma_size[dst]<=sizeof(wk_probe_ports[dst].dma));delivered+=dma_size[dst];
            /* Firmware may receive more while this private DMA is in flight. */
            while(accepted<32768&&wk_probe_space(src)){assert(wk_probe_input(src,cell,512,++tick));accepted+=512;}done(dst);
        }
        service(dst);assert(dma_copy[dst][5]==2);done(dst);service(src);assert(dma_copy[src][5]==2);done(src);
        assert(!wk_probe_active(src)&&!wk_probe_active(dst));
    }
    for(unsigned split=1;split<=512;split++){
        reset();begin(1,5,8192,64);begin(0,4,8192,64);uint8_t cell[512];memset(cell,0xa5,sizeof(cell));unsigned n=0;
        while(n<8192){
            unsigned part=8192-n;if(part>split)part=split;
            if(wk_probe_space(0)){assert(wk_probe_input(0,cell,part,++tick));n+=part;}
            service(1);if(busy[1][5])done(1);
        }
        while(wk_probe_ports[1].sent<8192){service(1);if(busy[1][5])done(1);}
        service(1);done(1);service(0);done(0);assert(!wk_probe_active(0)&&!wk_probe_active(1));
    }
    reset();begin(0,2,8192,64);fail_upload=1;service(0);assert(!busy[0][4]&&!wk_probe_ports[0].sent);service(0);done(0);assert(wk_probe_ports[0].sent==(sizeof(wk_probe_ports[0].dma)<8192?sizeof(wk_probe_ports[0].dma):8192));
    wk_probe_service(0,4,tick+5001);assert(dma_copy[0][5]==3);done(0);assert(!wk_probe_active(0));
    reset();command(0,1,91,513,64);assert(!wk_probe_active(0));command(0,1,91,(uint64_t)WK_PROBE_MAX+512,64);assert(!wk_probe_active(0));
    uint8_t invalid[64]={0};memcpy(invalid,"WKBP",4);assert(wk_probe_input(0,invalid,64,++tick));assert(!wk_probe_active(0));
    /* Normal complete cells stay on the original fast path; split prefixes
     * are replayed exactly, rather than eaten by diagnostic recognition. */
    reset();uint8_t normal_cell[512]={0};memcpy(normal_cell,"WKS5",4);assert(!wk_probe_input(0,normal_cell,512,++tick));
    assert(wk_probe_input(0,(const uint8_t *)"W",1,++tick));assert(wk_probe_input(0,(const uint8_t *)"KS5",3,++tick));assert(normal_count==4&&!memcmp(normal,"WKS5",4));
    uint8_t query[64]={0};memcpy(query,"WKBP",4);query[4]=1;query[5]=7;query[6]=1;query[7]=2;wk_probe_put(query+60,wk_probe_crc(query,60),4);
    reset();normal_boundary=false;assert(!wk_probe_input(0,query,64,++tick)&&!wk_probe_active(0));normal_boundary=true;
    uint8_t noise[512];memset(noise,0x71,sizeof(noise));memcpy(noise,"WKBP",4);assert(wk_probe_input(0,noise,sizeof(noise),++tick));assert(normal_count==512&&!memcmp(normal,noise,512));
    reset();begin(0,2,8192,64);service(0);uint8_t saved[WK_PROBE_DMA_BYTES];memcpy(saved,dma[0],sizeof(saved));wk_probe_reset(0);assert(!memcmp(saved,dma[0],sizeof(saved)));
    for(unsigned split=1;split<=64;split++){
        reset();begin(1,2,8192,64);service(1);memcpy(saved,dma[1],sizeof(saved));
        command(1,6,91,0,split);assert(wk_probe_ports[1].phase==3&&!memcmp(saved,dma[1],sizeof(saved)));done(1);
        service(1);assert(dma_copy[1][5]==3);done(1);assert(!wk_probe_active(1));
    }
    reset();begin(0,2,8192,64);service(0);wk_probe_reset(1);bridge.epoch++;assert(wk_probe_current(0));done(0);assert(wk_probe_ports[0].sent==(sizeof(wk_probe_ports[0].dma)<8192?sizeof(wk_probe_ports[0].dma):8192));
    reset();
    assert(wk_probe_input(0,query,64,++tick));service(0);assert(dma_size[0]==64&&dma_copy[0][5]==4&&dma_copy[0][6]==2&&dma_copy[0][7]==1&&wk_probe_u64(dma_copy[0]+16)==16384);done(0);
    puts("BULK_PROBE_PASS command_splits=64 local_source_sink=true relay_both_directions=true immutable_dma=true bounded_queue=true timeout=true reset=true normal_passthrough=true physicalUSB=false");
}
