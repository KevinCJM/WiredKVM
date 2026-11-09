#include "ch32v407_sim.h"
#include "bridge.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef struct { wk407_bridge b; size_t read_offset[2], read_size[2];uint8_t inflight[2][512];uint16_t sequence; } simulator;
void *wk407_sim_create(void) {
    simulator *s=calloc(1,sizeof(*s));if(!s)return NULL;wk407_init(&s->b);
    wk407_connected(&s->b,0,true,0);wk407_connected(&s->b,1,true,0);
    while(wk407_hid_peek(&s->b))wk407_hid_done(&s->b);return s;
}
void wk407_sim_destroy(void *s){free(s);}
size_t wk407_sim_write(void *v,unsigned source,const void *data,size_t size) {
    simulator *s=v;const uint8_t *p=data;size_t total=0;
    while(total<size){size_t n=size-total;if(n>512)n=512;if(!wk407_bulk_accept(&s->b,source,p+total,n))break;total+=n;}
    return total;
}
size_t wk407_sim_read(void *v,unsigned d,void *data,size_t size) {
    simulator *s=v;uint8_t *p=data;size_t total=0;if(d>1)return 0;
    while(total<size){
        if(!s->read_size[d]){const wk407_bulk_packet *b=wk407_bulk_peek(&s->b,d);if(!b)break;
            memcpy(s->inflight[d],b->bytes,b->size);s->read_size[d]=b->size;s->read_offset[d]=0;wk407_bulk_done(&s->b,d);}
        size_t n=s->read_size[d]-s->read_offset[d];if(n>size-total)n=size-total;
        memcpy(p+total,s->inflight[d]+s->read_offset[d],n);total+=n;s->read_offset[d]+=n;
        if(s->read_offset[d]==s->read_size[d]){s->read_size[d]=s->read_offset[d]=0;}}

    return total;
}
void wk407_sim_connect(void *v,unsigned p,int online,uint32_t now){simulator *s=v;wk407_connected(&s->b,p,online!=0,now);s->read_size[0]=s->read_size[1]=s->read_offset[0]=s->read_offset[1]=0;}
unsigned wk407_sim_hid_probe(void *v,uint32_t now) {
    simulator *s=v;char line[96];uint16_t seq=++s->sequence;
    int n=snprintf(line,sizeof(line),"WK1,%u,A,%u,%u",seq,now%32768,(now*7)%32768);
    uint8_t crc=wk_crc8((const uint8_t*)line,(size_t)n);n+=snprintf(line+n,sizeof(line)-(size_t)n,",%02X\n",crc);
    wk407_control(&s->b,(const uint8_t*)line,(size_t)n,now);
    const wk407_control_packet *reply=wk407_reply_peek(&s->b);
    unsigned ok=reply&&reply->size>=4&&!memcmp(reply->bytes,"ACK,",4);wk407_reply_done(&s->b);
    bool found=false;while(wk407_hid_peek(&s->b)){const wk407_hid_packet *p=wk407_hid_peek(&s->b);if(p->bytes[0]==3)found=true;wk407_hid_done(&s->b);}
    wk407_tick(&s->b,now);return ok&&found;
}
unsigned wk407_sim_peak(void *v){return ((simulator*)v)->b.bulk_high_water;}
size_t wk407_sim_size(void){return sizeof(wk407_bridge);}
/* Deliver the same priority control path used by the firmware, then consume its
 * routed copy. Simulator clients deliver the decoded report to the peer. */
int wk407_sim_control(void *v,unsigned source,const void *report) {
    simulator *s=v;if(source>1)return 0;
    if(!wk407_clipboard(&s->b,source,report,64))return 0;
    const wk407_control_packet *p=wk407_urgent_peek(&s->b,1-source);
    if(p)wk407_urgent_done(&s->b,1-source);
    return 1;
}
