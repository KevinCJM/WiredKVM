/* Experimental ABI/USB adapter only. Production files are never edited.
 * Default emits only the zero-contact probe. WKMT2_LIVE opts into Rust's
 * bounded live ingress; no production configuration enables it implicitly.
 * Target EP7 and interface6 are isolated from existing keyboard/mouse endpoints.
 */
#include "mt2_glue.h"
#include "wkmt2.h"
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static uint8_t control[WKMT2_CONTROL_CAPACITY] __attribute__((aligned(4)));
static uint8_t input[64] __attribute__((aligned(4)));
static size_t input_size;
static uint8_t idle,protocol=1;
static uint32_t resets,feature_gets,feature_sets,get_ids,set_ids,errors,inputs;
static uint8_t line[192],diagnostic[320];
static size_t line_size,diagnostic_size;
static bool passthrough;
static usb_req_t accepted_request;
static bool accepted_request_valid;

static unsigned id_mask(uint8_t id) {
    return id==1?1:id==2?2:id==0xdb?4:id==0x99?8:16;
}
#ifdef WKMT2_LIVE
extern bool wkmt2_live_line(const uint8_t *,size_t,uint32_t);
extern uint32_t wkmt2_live_received(void),wkmt2_live_max_contacts(void);
#endif
void wkmt2_profile_reset(void) {
#ifdef WKMT2_LIVE
    wkmt2_live_reset();
#endif
    wkmt2_reset();input_size=0;idle=0;protocol=1;accepted_request_valid=false;resets++;
    /* USB1 may be receiving a fragmented ordinary command during USB2 reset.
     * Do not reset its line/framing state here. */
}
void wkmt2_profile_host_reset(void){
#ifdef WKMT2_LIVE
    /* Host disappears: expire the current lease on the next service pass. */
    wkmt2_live_tick(UINT32_MAX,0);
#endif
    line_size=diagnostic_size=0;passthrough=false;
}
static usb_rst_e setup_request(const usb_req_t *r,void **buf,size_t *size) {
    *size=0;*buf=NULL;
    if(r->wIndex!=WKMT2_INTERFACE)return USB_RST_FAILED;
    uint8_t id=(uint8_t)r->wValue,type=(uint8_t)(r->wValue>>8);
    if(r->bmRequestType==0x81&&r->bRequest==6) {
        int n=wkmt2_report_descriptor(control,sizeof(control));
        if(n<=0||(size_t)n>sizeof(control)){errors++;return USB_RST_FAILED;}
        if(type==0x22){*buf=control;*size=(size_t)n;}
        else if(type==0x21){
            static uint8_t hid[9];
            const uint8_t value[]={9,0x21,0x11,1,0,1,0x22,(uint8_t)n,(uint8_t)(n>>8)};
            memcpy(hid,value,sizeof(hid));*buf=hid;*size=sizeof(hid);
        } else return USB_RST_FAILED;
        if(*size>r->wLength)*size=r->wLength;
        return USB_RST_OK;
    }
    if(r->bmRequestType==0xa1&&r->bRequest==1&&type==3) {
        feature_gets++;get_ids|=id_mask(id);
        int n=wkmt2_feature_get(id,control,sizeof(control));
        if(n<=0||(size_t)n>sizeof(control)){errors++;return USB_RST_FAILED;}
        *buf=control;*size=(size_t)n;if(*size>r->wLength)*size=r->wLength;
        return USB_RST_OK;
    }
    if(r->bmRequestType==0x21&&r->bRequest==9&&type==3) {
        if(!r->wLength||r->wLength>sizeof(control)){errors++;return USB_RST_FAILED;}
        *buf=control;*size=r->wLength;return USB_RST_OK;
    }
    if(r->bmRequestType==0x21&&r->bRequest==10&&!r->wLength){idle=r->wValue>>8;return USB_RST_OK;}
    if(r->bmRequestType==0x21&&r->bRequest==11&&!r->wLength&&r->wValue<=1){protocol=(uint8_t)r->wValue;return USB_RST_OK;}
    if(r->bmRequestType==0xa1&&(r->bRequest==2||r->bRequest==3)){
        *buf=r->bRequest==2?&idle:&protocol;*size=r->wLength?1:0;return USB_RST_OK;
    }
    return USB_RST_FAILED;
}
usb_rst_e wkmt2_profile_setup(const usb_req_t *r,void **buf,size_t *size) {
    accepted_request_valid=false;
    usb_rst_e result=setup_request(r,buf,size);
    if(result==USB_RST_OK){accepted_request=*r;accepted_request_valid=true;}
    return result;
}
usb_rst_e wkmt2_profile_data(const usb_req_t *r,void *buf,size_t size) {
    if(!accepted_request_valid||r->bmRequestType!=accepted_request.bmRequestType||
       r->bRequest!=accepted_request.bRequest||r->wValue!=accepted_request.wValue||
       r->wIndex!=accepted_request.wIndex||r->wLength!=accepted_request.wLength)
        return USB_RST_FAILED;
    accepted_request_valid=false;
    /* WCH _ctrl_xfer_process calls data completion for IN reads and even
     * zero-data SET_IDLE/SET_PROTOCOL. They must ACK after accepted setup;
     * only a Feature SET_REPORT carries payload to validate here. */
    if(r->bmRequestType!=0x21||r->bRequest!=9||r->wValue>>8!=3)return USB_RST_OK;
    uint8_t id=(uint8_t)r->wValue;feature_sets++;set_ids|=id_mask(id);
    if(size!=r->wLength||!size||size>sizeof(control)){errors++;return USB_RST_FAILED;}
    const uint8_t *p=buf;
    /* Numbered USB HID SET_REPORT includes the Report ID on the wire. */
    if(p[0]!=id){errors++;return USB_RST_FAILED;}
    if(wkmt2_feature_set(id,p+1,size-1)<0){errors++;return USB_RST_FAILED;}
    if(!wkmt2_enabled()){
        input_size=0;
#ifdef WKMT2_LIVE
        wkmt2_live_tick(UINT32_MAX,0);
#endif
    }
    return USB_RST_OK;
}
const uint8_t *wkmt2_profile_input(size_t *size) {
    if(!input_size){int n=wkmt2_input(input,sizeof(input));if(n>0&&(size_t)n<=sizeof(input))input_size=(size_t)n;else if(n<0)errors++;}
    *size=input_size;return input_size?input:NULL;
}
void wkmt2_profile_input_done(void){
#ifdef WKMT2_LIVE
    inputs++; /* Successful EP87 submit, not OS gesture acceptance. */
#else
    if(input_size)inputs++;
#endif
    input_size=0;
}
static void snapshot(void) {
    int n=snprintf((char *)diagnostic,sizeof(diagnostic),
        #ifdef WKMT2_LIVE
#ifdef WKMT2_NATIVE
        "MT2,version=2,enabled=%d,faults=%d,rx=%lu,max_contacts=%lu,resets="
#else
        "MT2,version=1,enabled=%d,faults=%d,rx=%lu,max_contacts=%lu,resets="
#endif
#else
        "MT2,enabled=%d,resets="
#endif
        "%lu,gets=%lu,sets=%lu,get_ids=%lu,set_ids=%lu,errors=%lu,inputs=%lu\n",
        wkmt2_enabled(),
#ifdef WKMT2_LIVE
        wkmt2_live_faults(),(unsigned long)wkmt2_live_received(),(unsigned long)wkmt2_live_max_contacts(),
#endif
        (unsigned long)resets,(unsigned long)feature_gets,(unsigned long)feature_sets,
        (unsigned long)get_ids,(unsigned long)set_ids,(unsigned long)errors,(unsigned long)inputs);
    diagnostic_size=n>0&&(size_t)n<sizeof(diagnostic)?(size_t)n:0;
}
void wkmt2_profile_control(void *context,wkmt2_forward_fn forward,const uint8_t *bytes,size_t n,uint32_t now) {
    for(size_t i=0;i<n;i++) {
        uint8_t c=bytes[i];
        if(passthrough){forward(context,&c,1,now);if(c=='\n')passthrough=false;continue;}
        if(line_size==sizeof(line)){forward(context,line,line_size,now);line_size=0;passthrough=true;forward(context,&c,1,now);if(c=='\n')passthrough=false;continue;}
        line[line_size++]=c;
        if(c=='\n') {
            if((line_size==5&&!memcmp(line,"MT2?\n",5))||(line_size==6&&!memcmp(line,"MT2?\r\n",6)))snapshot();
#ifdef WKMT2_LIVE
            else if(wkmt2_live_line(line,line_size,now)){}
#endif
            else forward(context,line,line_size,now);
            line_size=0;
        }
    }
}
const uint8_t *wkmt2_profile_diagnostic(size_t *size){*size=diagnostic_size;return diagnostic_size?diagnostic:NULL;}
void wkmt2_profile_diagnostic_done(void){diagnostic_size=0;}
