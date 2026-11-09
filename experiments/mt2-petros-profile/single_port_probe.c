/* EP0 validation and fixed-report ABI only. Lease/sequence/state is Rust.
 * No arbitrary input, allocator, waits, USB I/O, clipboard or bridge mutation. */
#include "single_port_probe.h"
#include <string.h>

extern void wkap_core_reset(void);
extern int wkap_core_stage(const uint8_t *,size_t);
extern int wkap_core_poll(uint32_t,uint32_t);
extern void wkap_core_quiescing(int);
extern int wkap_core_prepare(uint8_t *);
extern int wkap_core_submitted(uint32_t *,uint32_t *);
extern void wkap_core_complete(uint32_t,uint32_t);
extern void wkap_core_status(uint32_t,uint8_t *);
static uint8_t feature[64] __attribute__((aligned(4)));
static uint8_t report[8] __attribute__((aligned(4)));
static usb_req_t accepted;
static bool accepted_valid;

void wkap_profile_cancel_setup(void){accepted_valid=false;}
void wkap_profile_quiescing(bool active){wkap_core_quiescing(active);}
void wkap_profile_reset(void){accepted_valid=false;wkap_core_reset();}
usb_rst_e wkap_profile_setup(const usb_req_t *r,void **buf,size_t *size,uint32_t now) {
    accepted_valid=false;*buf=NULL;*size=0;
    if(r->wIndex!=WKAP_INTERFACE||r->wValue!=0x0300||r->wLength!=64)return USB_RST_FAILED;
    if(r->bmRequestType==0xa1&&r->bRequest==1)wkap_core_status(now,feature);
    else if(r->bmRequestType==0x21&&r->bRequest==9)memset(feature,0,sizeof(feature));
    else return USB_RST_FAILED;
    accepted=*r;accepted_valid=true;*buf=feature;*size=64;return USB_RST_OK;
}
usb_rst_e wkap_profile_data(const usb_req_t *r,void *buf,size_t size) {
    bool matched=accepted_valid&&r->bmRequestType==accepted.bmRequestType&&r->bRequest==accepted.bRequest&&
        r->wValue==accepted.wValue&&r->wIndex==accepted.wIndex&&r->wLength==accepted.wLength;
    accepted_valid=false;
    if(!matched||size!=64||buf!=feature)return USB_RST_FAILED;
    if(r->bmRequestType==0xa1)return USB_RST_OK; /* WCH calls IN completion too. */
    return wkap_core_stage(feature,64)?USB_RST_OK:USB_RST_FAILED;
}
unsigned wkap_profile_guards(const wk407_bridge *b,bool host_enum,bool target_online,bool normal_busy) {
    unsigned flags=(host_enum?WKAP_HOST_ENUM:0)|(target_online?WKAP_TARGET_ONLINE:0);
    if(normal_busy||b->hid.count)flags|=WKAP_NORMAL_BUSY;
    bool held=b->buttons||b->modifiers||b->fn_down||b->release_pending;
    for(unsigned i=0;i<6;i++)held|=b->keys[i]!=0;
    if(held)flags|=WKAP_HELD_INPUT;
    return flags;
}
bool wkap_profile_poll(uint32_t now,unsigned guards){return wkap_core_poll(now,guards)!=0;}
const uint8_t *wkap_profile_input(size_t *size){*size=0;if(!wkap_core_prepare(report))return NULL;*size=sizeof(report);return report;}
bool wkap_profile_submitted(uint32_t *epoch,uint32_t *seq){return wkap_core_submitted(epoch,seq)!=0;}
void wkap_profile_done(uint32_t epoch,uint32_t seq){wkap_core_complete(epoch,seq);}
