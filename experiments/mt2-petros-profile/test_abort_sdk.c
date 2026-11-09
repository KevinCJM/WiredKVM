/* Real WCH usbd_upload/endp_set_response/event_handle are linked, not mocked.
 * The model replaces only port register/DMA operations. This is not a bus or
 * silicon emulator. main-loop ownership is separately tested by test_profile.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "usb_driver.h"
#include "device/usbd_driver_private.h"
#include "single_port_abort.h"
#include "ch32v4x7.h"
#include "ch32v4x7_usb.h"

model_registers model;
static usbd_handle_t h;
static uint8_t ctrl[8], bytes_probe[8]={3,0,0,64,0,64,0,0};
static uint8_t bytes_normal[8]={3,0,9,0,9,0,0,0}, bytes_bulk[512];
static void *dma[8];
static size_t length[8];
static unsigned opens,closes,toggle_sets,probe_done,normal_done,bulk_done,writes;
static unsigned kind;
static int race;

uint8_t model_ctrl_read(void) {
    uint8_t value=ctrl[2];
    if(race) {
        assert((ctrl[2]&3)==2);
        race=0;ctrl[2]^=4;ctrl[2]|=USBHS_UEP_T_DONE;
        model.MIS_ST|=USBHS_UDMS_SIE_FREE;
    }
    return value;
}
void model_ctrl_write(uint8_t value) {
    writes++;
    ctrl[2]=(ctrl[2]&value&0xc0)|(ctrl[2]&0x0c)|(value&3);
}
static usb_rst_e set_response(usb_endp_t ep,endp_resp_e response) {
    unsigned n=ENDP_NUM(ep);
    ctrl[n]=(ctrl[n]&~3)|(response==ENDP_RESP_ACK?2:response==ENDP_RESP_STALL?1:0);
    return USB_RST_OK;
}
static usb_rst_e set_buf(usb_endp_t ep,void *buf) {dma[ENDP_NUM(ep)]=buf;return USB_RST_OK;}
static usb_rst_e set_size(usb_endp_t ep,size_t size) {length[ENDP_NUM(ep)]=size;return USB_RST_OK;}
static usb_rst_e set_toggle(usb_endp_t ep,endp_tog_e toggle) {
    toggle_sets++;ctrl[ENDP_NUM(ep)]=(ctrl[ENDP_NUM(ep)]&~12)|((unsigned)toggle<<2);return USB_RST_OK;
}
static usb_rst_e ep_open(usb_endp_t ep,uint8_t feature,uint16_t size) {(void)ep;(void)feature;(void)size;opens++;return USB_RST_OK;}
static usb_rst_e ep_close(usb_endp_t ep) {(void)ep;closes++;return USB_RST_OK;}
static usb_rst_e ok(void) {return USB_RST_OK;}
static usb_rst_e open_controller(usb_speed_e speed,usb_bool_t sof) {(void)speed;(void)sof;return USB_RST_OK;}
static usb_rst_e set_address(uint8_t address) {(void)address;return USB_RST_OK;}
static usb_rst_e interrupt_ctrl(usb_bool_t enabled) {(void)enabled;return USB_RST_OK;}
static endp_resp_e completed(usbd_handle_t *handle,usb_endp_t ep,void *buf,size_t size) {
    assert(handle==&h);
    if(ep==0x83) {assert(buf==bytes_bulk&&size==512);bulk_done++;}
    else {
        assert(ep==0x82&&size==8);
        if(kind==9) {assert(buf==bytes_probe);probe_done++;}
        else {assert(kind==2&&buf==bytes_normal);normal_done++;}
    }
    return ENDP_RESP_NAK;
}
static void setup(void) {
    h.enable=h.disable=h.close=h.resume=ok;h.open=open_controller;
    h.set_address=set_address;h.interrupt_ctrl=interrupt_ctrl;
    h.endp_open=ep_open;h.endp_close=ep_close;h.set_endp_toggle=set_toggle;
    h.set_endp_buf=set_buf;h.set_endp_size=set_size;h.set_endp_response=set_response;
    assert(usbd_drv_init(&h)==USB_RST_OK);
    assert(usbd_endp_open(&h,0x82,0,64)==USB_RST_OK);
    assert(usbd_endp_open(&h,0x83,0,512)==USB_RST_OK);
    assert(usbd_register_data_callback(&h,0x82,completed)==USB_RST_OK);
    assert(usbd_register_data_callback(&h,0x83,completed)==USB_RST_OK);
    model.MIS_ST=USBHS_UDMS_SIE_FREE;
}
static void upload_probe(void) {
    kind=9;assert(usbd_upload(&h,0x82,bytes_probe,8)==USB_RST_OK);
    assert(h.endp_params[USB_DIR_IN][2].status==ENDP_STA_BUSY);
    assert(dma[2]==bytes_probe&&length[2]==8);
}
static void complete(unsigned ep) {
    /* Matches the real port's order: real core/callback, then W0C DONE. */
    if(!(ctrl[ep]&USBHS_UEP_T_DONE)) {
        assert((ctrl[ep]&3)==2);ctrl[ep]^=4;ctrl[ep]|=USBHS_UEP_T_DONE;
    }
    usbd_event_t event={.e=USBD_EVENT_XFER,.xfer={.ep=(uint8_t)(ep|128),.size=length[ep],.buf=dma[ep]}};
    usbd_event_handle(&h,&event);
    assert(h.endp_params[USB_DIR_IN][ep].status==ENDP_STA_IDLE);
    assert(ctrl[ep]&USBHS_UEP_T_DONE); /* core is not the port IRQ acknowledgement */
    ctrl[ep]&=~USBHS_UEP_T_DONE;
}
static void upload_and_complete_normal(void) {
    assert(!(ctrl[2]&USBHS_UEP_T_DONE));
    kind=2;assert(usbd_upload(&h,0x82,bytes_normal,8)==USB_RST_OK);
    assert(dma[2]==bytes_normal&&length[2]==8);complete(2);
}
int main(void) {
    setup();unsigned original_opens=opens,original_toggle_sets=toggle_sets;
    assert(usbd_upload(&h,0x83,bytes_bulk,512)==USB_RST_OK);
    /* Real SDK BUSY -> cancellation -> IDLE -> new upload, both DATA toggles. */
    for(unsigned i=0;i<1000;i++) {
        upload_probe();uint8_t toggle=ctrl[2]&4;unsigned before=normal_done;
        assert(wkap_abort_ep82(&h));
        assert(h.endp_params[USB_DIR_IN][2].status==ENDP_STA_IDLE);
        assert((ctrl[2]&4)==toggle&&probe_done==0);
        upload_and_complete_normal();assert(normal_done==before+1);
        assert((ctrl[2]&4)!=toggle);
        assert(h.endp_params[USB_DIR_IN][3].status==ENDP_STA_BUSY);
        assert(dma[3]==bytes_bulk&&length[3]==512&&(ctrl[3]&3)==2);
    }
    /* Busy SIE retains both SDK and adapter ownership; no new DMA admitted. */
    upload_probe();model.MIS_ST=0;
    for(unsigned i=0;i<1000;i++)assert(!wkap_abort_ep82(&h));
    assert(usbd_upload(&h,0x82,bytes_normal,8)==USB_RST_ENDP_BUSY);
    assert(dma[2]==bytes_probe);
    model.MIS_ST=USBHS_UDMS_SIE_FREE;assert(wkap_abort_ep82(&h));
    upload_and_complete_normal();
    /* An ACK completion racing the NAK write must survive the W0C register. */
    upload_probe();race=1;model.MIS_ST=0;unsigned before=probe_done;
    assert(!wkap_abort_ep82(&h));assert(!race&&(ctrl[2]&USBHS_UEP_T_DONE));
    assert(h.endp_params[USB_DIR_IN][2].status==ENDP_STA_BUSY);
    assert(usbd_upload(&h,0x82,bytes_normal,8)==USB_RST_ENDP_BUSY);
    assert(!wkap_abort_ep82(&h));complete(2);assert(probe_done==before+1);
    upload_and_complete_normal();assert(probe_done==before+1);
    /* Reset settling must not write a control register or release the SDK. */
    upload_probe();model.INT_FG=USBHS_UDIF_BUS_RST;before=writes;
    assert(!wkap_abort_ep82(&h));assert(writes==before);
    assert(h.endp_params[USB_DIR_IN][2].status==ENDP_STA_BUSY);
    model.INT_FG=0;assert(wkap_abort_ep82(&h));upload_and_complete_normal();
    assert(opens==original_opens&&toggle_sets==original_toggle_sets&&closes==0);
    complete(3);assert(bulk_done==1);
    printf("REAL_WCH_CORE_ABORT_PASS cycles=1000 normal=%u probe=%u bulk=%u\n",normal_done,probe_done,bulk_done);
    return 0;
}
