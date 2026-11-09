/* CH32V407VET6/WEU6 polling adapter. No WCH fast-interrupt ABI dependency.
 * All USB calls run in one bounded main-loop pass. DMA owns dedicated copies.
 * SDK reset recovery is deferred per controller; see prepare_ch32v407_sdk.py. */
#include "ch32v4x7.h"
#include "usbhs1_dcp.h"
#include "usbhs2_dcp.h"
#include "usb_driver.h"
#include "bridge.h"
#include "descriptors.h"
#include "setup_flash.h"
#include "mt2_glue.h"
#include "wkmt2.h"
extern bool wkmt2_live_abort_usb(usbd_handle_t *);
#include <string.h>

static wk407_bridge bridge;
static wk_setup setup;
static usbd_handle_t *handles[2];
static uint8_t rx[2][8][512] __attribute__((aligned(4)));
static uint8_t tx[2][8][512] __attribute__((aligned(4)));
static bool armed[2][8], busy[2][8];
static uint32_t tx_epoch[2][8], tx_hid_epoch[2][8];
static uint8_t tx_kind[2][8];
static uint32_t setup_epoch[2], setup_tx_epoch[2];
static bool reset_pending[2];
#define LINE_115200_8N1 {0x00,0xc2,0x01,0x00,0,0,8,0}
static uint8_t coding[2][2][8] __attribute__((aligned(4)))={
    {LINE_115200_8N1,LINE_115200_8N1},{LINE_115200_8N1,LINE_115200_8N1}};
static uint8_t class_report[64] __attribute__((aligned(4)));
static uint8_t hid_idle[3], hid_protocol[3]={1,1,1};
static uint64_t ticks;
static uint32_t last_ticks, milliseconds;
static uint8_t setup_lun;
static uint32_t touch_at;

unsigned wk407_port(usbd_handle_t *h){return h==handles[1]?1:0;}
uint32_t wk407_now_ms(void) {
    uint32_t current=(uint32_t)SysTick->CNT;
    ticks+=(uint32_t)(current-last_ticks);last_ticks=current;
    uint32_t per_ms=SystemCoreClock/8000;
    milliseconds+=(uint32_t)(ticks/per_ms);ticks%=per_ms;return milliseconds;
}
void wk407_reset_begin(unsigned p){
    if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();
    reset_pending[p]=true;wk407_connected(&bridge,p,false,wk407_now_ms());
    wk_setup_connected(&setup,p,false,wk407_now_ms());setup_epoch[p]++;
}
static bool setup_report(void *context,unsigned port,const uint8_t *bytes,size_t n) {
    return wk_setup_control(context,port,bytes,n,wk407_now_ms());
}

static void reset_cb(usbd_handle_t *h,uint32_t parameter) {
    (void)parameter;unsigned p=wk407_port(h);
    if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();
    wk407_connected(&bridge,p,false,wk407_now_ms());
    wk_setup_connected(&setup,p,false,wk407_now_ms());setup_epoch[p]++;
    reset_pending[p]=false;
    memset(armed[p],0,sizeof(armed[p]));memset(busy[p],0,sizeof(busy[p]));
    uint16_t packet=usbd_get_speed(h)==USB_SPEED_HIGH?512:64;
    if(p==0) {
        usbd_endp_open(h,0x81,0,8);usbd_endp_open(h,0x83,0,8);
        usbd_endp_open(h,0x82,USBD_ENDP_FEATURE_ZLP,packet);usbd_endp_open(h,2,0,packet);
        usbd_endp_open(h,0x84,USBD_ENDP_FEATURE_ZLP,packet);usbd_endp_open(h,4,0,packet);
        usbd_endp_open(h,0x85,0,packet);usbd_endp_open(h,5,0,packet);
    } else {
        for(unsigned ep=1;ep<=3;ep++)usbd_endp_open(h,(uint8_t)(0x80|ep),0,64);
        usbd_endp_open(h,3,0,64);usbd_endp_open(h,0x84,0,8);
        usbd_endp_open(h,0x85,USBD_ENDP_FEATURE_ZLP,packet);usbd_endp_open(h,5,0,packet);
        usbd_endp_open(h,0x86,0,packet);usbd_endp_open(h,6,0,packet);
        usbd_endp_open(h,0x87,0,64);
    }
}
static void forward_control(void *context,const uint8_t *bytes,size_t n,uint32_t now) {
    wk407_control((wk407_bridge *)context,bytes,n,now);
}
static endp_resp_e data_cb(usbd_handle_t *h,usb_endp_t ep,void *buf,size_t size) {
    unsigned p=wk407_port(h),e=ep&127;
    if(e>=8)return ENDP_RESP_STALL;
    unsigned msc=p?6:5;
    if(e==msc) {
        if(ep&128) {
            if(busy[p][e]&&setup_tx_epoch[p]==setup_epoch[p])wk_setup_msc_done(&setup,p);
            busy[p][e]=false;
        } else {
            armed[p][e]=false;
            if(!wk_setup_msc_out(&setup,p,buf,size,wk407_now_ms())) {
                (void)usbd_endp_set_response(h,(uint8_t)(0x80|e),ENDP_RESP_STALL);
                return ENDP_RESP_STALL;
            }
            if(wk_setup_msc_take_stall(&setup,p))(void)usbd_endp_set_response(h,(uint8_t)(0x80|e),ENDP_RESP_STALL);
        }
        return ENDP_RESP_NAK;
    }
    if(ep&128) {
        if(busy[p][e]&&tx_epoch[p][e]==bridge.epoch){
            if(tx_kind[p][e]==1||tx_kind[p][e]==5){} /* copied and popped at submit */
            else if(tx_kind[p][e]==2 && tx_hid_epoch[p][e]==bridge.hid_epoch)wk407_hid_done(&bridge);
            else if(tx_kind[p][e]==3)wk407_reply_done(&bridge);
            else if(tx_kind[p][e]==4)wk407_clipboard_done(&bridge,p);
        }
        if(p==1&&e==7&&busy[p][e]&&tx_kind[p][e]==8)wkmt2_live_done();
        busy[p][e]=false;
    } else {
        armed[p][e]=false;
        if(p==0&&e==2)wkmt2_profile_control(&bridge,forward_control,buf,size,wk407_now_ms());
        else if(p==1&&e==3)(void)wk407_clipboard(&bridge,1,buf,size);
        else (void)wk407_bulk_accept(&bridge,p,buf,size);
    }
    return ENDP_RESP_NAK;
}
static usb_rst_e interface_setup(usbd_handle_t *h,const usb_req_t *r,void **buf,size_t *size) {
    unsigned p=wk407_port(h),i=r->wIndex;*size=0;
    if(p==1&&i==WKMT2_INTERFACE)return wkmt2_profile_setup(r,buf,size);
    if(i==(p?5:4)) {
        if(r->bmRequestType==0xa1&&r->bRequest==0xfe&&!r->wValue&&r->wLength==1){*buf=&setup_lun;*size=1;return USB_RST_OK;}
        if(r->bmRequestType==0x21&&r->bRequest==0xff&&!r->wValue&&!r->wLength){
            setup_epoch[p]++;wk_setup_msc_reset(&setup,p);
            unsigned ep=p?6:5;uint16_t packet=usbd_get_speed(h)==USB_SPEED_HIGH?512:64;
            usbd_endp_close(h,(uint8_t)(0x80|ep));usbd_endp_close(h,(uint8_t)ep);
            busy[p][ep]=armed[p][ep]=false;
            usbd_endp_open(h,(uint8_t)(0x80|ep),0,packet);usbd_endp_open(h,(uint8_t)ep,0,packet);
            return USB_RST_OK;
        }
        return USB_RST_FAILED;
    }
    if(p==1&&i<3) {
        if(r->bmRequestType==0x81&&r->bRequest==6)return wk407_hid_descriptor(h,r,buf,size);
        if(r->bmRequestType==0x21&&r->bRequest==9&&i==2&&r->wValue==0x0200&&r->wLength==64){*buf=class_report;*size=64;return USB_RST_OK;}
        if(r->bmRequestType==0x21&&r->bRequest==10){hid_idle[i]=r->wValue>>8;return USB_RST_OK;}
        if(r->bmRequestType==0x21&&r->bRequest==11&&r->wValue<=1){hid_protocol[i]=(uint8_t)r->wValue;return USB_RST_OK;}
        if(r->bmRequestType==0xa1&&(r->bRequest==2||r->bRequest==3)){*buf=r->bRequest==2?&hid_idle[i]:&hid_protocol[i];*size=r->wLength?1:0;return USB_RST_OK;}
        return USB_RST_FAILED;
    }
    if((p==0&&(i==0||i==2))||(p==1&&i==3)) {
        unsigned which=p?0:i/2;
        if((r->bmRequestType==0x21&&r->bRequest==0x20)||(r->bmRequestType==0xa1&&r->bRequest==0x21)) {
            if(r->wLength!=7)return USB_RST_FAILED;*buf=coding[p][which];*size=7;return USB_RST_OK;
        }
        if(r->bmRequestType==0x21&&r->bRequest==0x22)return USB_RST_OK;
    }
    return USB_RST_FAILED;
}
static usb_rst_e interface_data(usbd_handle_t *h,const usb_req_t *r,void *buf,size_t size) {
    if(wk407_port(h)==1&&r->wIndex==WKMT2_INTERFACE)return wkmt2_profile_data(r,buf,size);
    if(wk407_port(h)==1&&r->wIndex==2&&r->bRequest==9)
        return wk407_clipboard(&bridge,1,buf,size)?USB_RST_OK:USB_RST_FAILED;
    return USB_RST_OK;
}
static void arm(unsigned p,unsigned ep,unsigned size) {
    if(!armed[p][ep]&&usbd_download(handles[p],(uint8_t)ep,rx[p][ep],size)==USB_RST_OK)armed[p][ep]=true;
}
static void send(unsigned p,unsigned ep,unsigned kind,const void *bytes,unsigned size) {
    if(busy[p][ep]||size>512)return;
    memcpy(tx[p][ep],bytes,size);
    if(usbd_upload(handles[p],(uint8_t)(ep|128),tx[p][ep],size)==USB_RST_OK) {
        busy[p][ep]=true;tx_epoch[p][ep]=bridge.epoch;tx_kind[p][ep]=(uint8_t)kind;tx_hid_epoch[p][ep]=bridge.hid_epoch;
        if(kind==1)wk407_bulk_done(&bridge,p);
        if(kind==5)wk407_urgent_done(&bridge,p);
        if(kind==7)wkmt2_profile_diagnostic_done();
        if(kind==8)wkmt2_profile_input_done();
    }
}
static void service(void) {
    uint32_t now=wk407_now_ms();wk407_tick(&bridge,now);
    /* Configuration and suspend are checked before arming any endpoint. */
    for(unsigned p=0;p<2;p++) {
        bool suspended=p?(USBHS2D->MIS_ST&USBHS_UDMS_SUSPEND):(USBHS1D->MIS_ST&USBHS_UDMS_SUSPEND);
        bool online=usbd_is_enum(handles[p])&&!suspended&&!reset_pending[p];
        if(online!=bridge.online[p]) {
            if(!online){if(p==0)wkmt2_profile_host_reset();else wkmt2_profile_reset();}
            wk407_connected(&bridge,p,online,now);wk_setup_connected(&setup,p,online,now);setup_epoch[p]++;
        }
    }
    if(bridge.online[1]) {
        const wk407_hid_packet *v=wk407_hid_peek(&bridge);
        /* Keep reports ordered across relative/absolute interfaces. */
        if(v&&!busy[1][1]&&!busy[1][2])send(1,v->endpoint,2,v->bytes,v->size);
        if(bridge.clipboard[0].count<WK407_CONTROL_SLOTS&&bridge.urgent[0].count<WK407_CONTROL_SLOTS)arm(1,3,64);
        const wk407_control_packet *c=wk407_urgent_peek(&bridge,1);if(c)send(1,3,5,c->bytes,c->size);
        else if((c=wk407_clipboard_peek(&bridge,1)))send(1,3,4,c->bytes,c->size);
    }
    if(bridge.online[0]) {
        /* 512-byte command packets can contain up to ~30 WK1 lines. */
        if(bridge.reply.count==0&&bridge.hid.count<=WK407_HID_SLOTS-32)arm(0,2,usbd_get_speed(handles[0])==USB_SPEED_HIGH?512:64);
        const wk407_control_packet *c=wk407_reply_peek(&bridge);
        size_t diagnostic_size=0;const uint8_t *diagnostic=wkmt2_profile_diagnostic(&diagnostic_size);
        if(c)send(0,2,3,c->bytes,c->size);
        else if(diagnostic)send(0,2,7,diagnostic,(unsigned)diagnostic_size);
        else if((c=wk407_urgent_peek(&bridge,0)))send(0,2,5,c->bytes,c->size);
        else if((c=wk407_clipboard_peek(&bridge,0)))send(0,2,4,c->bytes,c->size);
    }
    /* Touch never owns the existing mouse/key endpoints or Bulk queues. */
    wkmt2_live_tick(now,bridge.online[0]&&bridge.online[1]&&wkmt2_enabled());
    if(wkmt2_live_abort_pending()>0) {
        if(!busy[1][7]||(!reset_pending[1]&&wkmt2_live_abort_usb(handles[1]))) {
            busy[1][7]=false;tx_kind[1][7]=0;wkmt2_live_aborted();
        }
    }
    if(bridge.online[1]&&!busy[1][7]&&now-touch_at>=4) {
        uint8_t touch[64] __attribute__((aligned(4)));
        int n=wkmt2_live_input(touch,sizeof(touch));bool live=n>0;
        size_t fallback=0;const uint8_t *frame=live?touch:wkmt2_profile_input(&fallback);
        if(!live)n=(int)fallback;
        if(frame&&n>0) {
            /* Target clock is monotonic at transmission, even after cancel. */
            {if(!live){memcpy(touch,frame,(size_t)n);frame=touch;}uint32_t stamp=(now*8)|4u;touch[9]=(uint8_t)stamp;touch[10]=(uint8_t)(stamp>>8);touch[11]=(uint8_t)(stamp>>16);}
            send(1,7,8,frame,(unsigned)n);
            if(busy[1][7]){touch_at=now;if(live)wkmt2_live_submitted();}
        }
    }
    /* At most one 512-byte operation per file direction per pass. */
    for(unsigned p=0;p<2;p++)if(bridge.online[p]) {
        unsigned ep=p?5:4;
        if(wk407_bulk_space(&bridge,p))arm(p,ep,usbd_get_speed(handles[p])==USB_SPEED_HIGH?512:64);
        const wk407_bulk_packet *v=wk407_bulk_peek(&bridge,p);if(v)send(p,ep,1,v->bytes,v->size);
    }
    /* Installation I/O runs after input and file/control service. At most one
     * 512-byte SPI read/check and one staged MSC packet per side per pass. */
    wk_setup_tick(&setup,now);
    for(unsigned p=0;p<2;p++)if(bridge.online[p]) {
        unsigned ep=p?6:5;
        if(wk_setup_msc_wants_out(&setup,p))arm(p,ep,usbd_get_speed(handles[p])==USB_SPEED_HIGH?512:64);
        if(!busy[p][ep]) {
            size_t n=0;const uint8_t *bytes=wk_setup_msc_in(&setup,p,&n);
            /* SDK upload rejects a stalled endpoint until the host's standard
             * CLEAR_FEATURE clears it. Only then can the failed-command CSW go. */
            if(wk_setup_msc_take_stall(&setup,p))(void)usbd_endp_set_response(handles[p],(uint8_t)(0x80|ep),ENDP_RESP_STALL);
            if(bytes){setup_tx_epoch[p]=setup_epoch[p];send(p,ep,6,bytes,(unsigned)n);}
        }
    }
}
int main(void) {
    SystemCoreClockUpdate();
    /* Free-running HCLK/8 counter, no interrupt and no automatic reload. */
    SysTick->CTLR=0;SysTick->CNT=0;SysTick->CMP=UINT32_MAX;SysTick->CTLR=1;
    wk407_init(&bridge);wkmt2_profile_reset();wkmt2_profile_host_reset();wk_setup_flash_init();wk_setup_init(&setup,wk_setup_flash_read,NULL);
    bridge.local_report=setup_report;bridge.local_context=&setup;
    usbhs1_dch_init();usbhs2_dch_init();handles[0]=&usbhs1d_handle;handles[1]=&usbhs2d_handle;
    for(unsigned p=0;p<2;p++) {
        usbd_handle_t *h=handles[p];
        if(usbd_drv_init(h)!=USB_RST_OK||usbd_enable(h)!=USB_RST_OK)for(;;){}
        usbd_register_event_callback(h,USBD_CB_EVENT_RESET,reset_cb);
        usbd_register_req_callback(h,0x80,6,wk407_descriptor,NULL,NULL);
        for(unsigned i=0;i<(p?7:5);i++)usbd_register_itf_callback(h,(uint8_t)i,interface_setup,interface_data,NULL);
        for(unsigned ep=1;ep<=(p?7:6);ep++){
            usbd_register_data_callback(h,(uint8_t)ep,data_cb);usbd_register_data_callback(h,(uint8_t)(ep|128),data_cb);
        }
        usbd_open(h,USB_SPEED_HIGH,USB_FALSE);
    }
    for(;;) {
        /* Service target HID completion first, then command ingress. Reset
         * timers return immediately and leave the other controller running. */
        if(USBHS2D->INT_FG&USBHS2D->INT_EN)usbhs2_dch_interrupt();
        if(USBHS1D->INT_FG&USBHS1D->INT_EN)usbhs1_dch_interrupt();
        service();
    }
}
