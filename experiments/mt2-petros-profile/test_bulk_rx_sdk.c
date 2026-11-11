/* Links the pinned real WCH core; only the port/DMA boundary is simulated.
 * This proves its returned-ACK contract, not physical speed or USB timing.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "usb_driver.h"
#include "device/usbd_driver_private.h"

static usbd_handle_t h;
static void *dma[2][8];
static size_t length[2][8];
static endp_resp_e response[2][8];
static uint8_t receive[2][512],transmit[512],saved[2][512];
static unsigned callbacks[2],opens,closes,toggles,arms;
static endp_resp_e next_response;
static size_t expected_size;
static uint8_t expected_byte;

static usb_rst_e ok(void){return USB_RST_OK;}
static usb_rst_e open_controller(usb_speed_e speed,usb_bool_t sof){(void)speed;(void)sof;return USB_RST_OK;}
static usb_rst_e set_address(uint8_t address){(void)address;return USB_RST_OK;}
static usb_rst_e interrupt_ctrl(usb_bool_t enabled){(void)enabled;return USB_RST_OK;}
static usb_rst_e set_response(usb_endp_t ep,endp_resp_e value){response[ENDP_DIR(ep)!=0][ENDP_NUM(ep)]=value;return USB_RST_OK;}
static usb_rst_e set_buf(usb_endp_t ep,void *buf){dma[ENDP_DIR(ep)!=0][ENDP_NUM(ep)]=buf;return USB_RST_OK;}
static usb_rst_e set_size(usb_endp_t ep,size_t n){length[ENDP_DIR(ep)!=0][ENDP_NUM(ep)]=n;return USB_RST_OK;}
static usb_rst_e set_toggle(usb_endp_t ep,endp_tog_e toggle){(void)ep;(void)toggle;toggles++;return USB_RST_OK;}
static usb_rst_e ep_open(usb_endp_t ep,uint8_t feature,uint16_t size){(void)ep;assert(!feature&&size<=512);opens++;return USB_RST_OK;}
static usb_rst_e ep_close(usb_endp_t ep){(void)ep;closes++;return USB_RST_OK;}
static endp_resp_e received(usbd_handle_t *handle,usb_endp_t ep,void *buf,size_t n){
    unsigned p=ep==4?0:1;assert(handle==&h&&(ep==4||ep==5));
    assert(buf==receive[p]&&n==expected_size);
    /* The real core has already restored the same DMA before calling us. */
    assert(dma[0][ep]==receive[p]&&length[0][ep]==h.endp_params[USB_DIR_OUT][ep].max_size);
    for(size_t i=0;i<n;i++)assert(((uint8_t *)buf)[i]==expected_byte);
    memcpy(saved[p],buf,n);callbacks[p]++;return next_response;
}
static void arm(unsigned p,unsigned packet){
    unsigned ep=p+4;arms++;
    assert(usbd_download(&h,(usb_endp_t)ep,receive[p],packet)==USB_RST_OK);
    assert(response[0][ep]==ENDP_RESP_ACK&&h.endp_params[USB_DIR_OUT][ep].status==ENDP_STA_BUSY);
}
static void packet(unsigned p,size_t n,uint8_t value,endp_resp_e next){
    unsigned ep=p+4;expected_size=n;expected_byte=value;next_response=next;
    assert(response[0][ep]==ENDP_RESP_ACK);memset(dma[0][ep],value,n);
    usbd_event_t event={.e=USBD_EVENT_XFER,.xfer={.ep=(uint8_t)ep,.size=n,.buf=dma[0][ep]}};
    unsigned before=callbacks[p];usbd_event_handle(&h,&event);
    assert(callbacks[p]==before+1&&response[0][ep]==next);
    assert(h.endp_params[USB_DIR_OUT][ep].xfer_offset==0);
    assert(h.endp_params[USB_DIR_OUT][ep].status==(next==ENDP_RESP_ACK?ENDP_STA_BUSY:ENDP_STA_IDLE));
    memset(receive[p],0,n);for(size_t i=0;i<n;i++)assert(saved[p][i]==value);
    /* Receive continuation cannot disturb an unrelated in-flight IN DMA. */
    assert(h.endp_params[USB_DIR_IN][3].status==ENDP_STA_BUSY&&dma[1][3]==transmit&&length[1][3]==512);
}
int main(void){
    h.enable=h.disable=h.close=h.resume=ok;h.open=open_controller;
    h.set_address=set_address;h.interrupt_ctrl=interrupt_ctrl;
    h.endp_open=ep_open;h.endp_close=ep_close;h.set_endp_toggle=set_toggle;
    h.set_endp_buf=set_buf;h.set_endp_size=set_size;h.set_endp_response=set_response;
    assert(usbd_drv_init(&h)==USB_RST_OK);
    assert(usbd_endp_open(&h,0x83,0,512)==USB_RST_OK);
    assert(usbd_upload(&h,0x83,transmit,512)==USB_RST_OK);
    for(unsigned size=64;size<=512;size*=8){
        for(unsigned p=0;p<2;p++){
            assert(usbd_endp_open(&h,(usb_endp_t)(p+4),0,(uint16_t)size)==USB_RST_OK);
            assert(usbd_register_data_callback(&h,(usb_endp_t)(p+4),received)==USB_RST_OK);arm(p,size);
        }
        unsigned arms_before=arms,toggles_before=toggles,opens_before=opens;
        for(unsigned i=0;i<1000;i++)for(unsigned p=0;p<2;p++)packet(p,size,(uint8_t)(i%254+1),ENDP_RESP_ACK);
        /* A short packet and ZLP must also deliver immediately, with no fill wait. */
        packet(0,13,0x3a,ENDP_RESP_ACK);packet(1,0,0,ENDP_RESP_ACK);
        assert(arms==arms_before&&toggles==toggles_before&&opens==opens_before&&closes==0);
        for(unsigned p=0;p<2;p++){
            packet(p,size,0x53,ENDP_RESP_NAK);assert(response[0][p+4]==ENDP_RESP_NAK);
            arm(p,size);packet(p,size,0x54,ENDP_RESP_ACK);
        }
    }
    usbd_event_t reset={.e=USBD_EVENT_RESET,.reset={.link_speed=USB_SPEED_HIGH}};
    usbd_event_handle(&h,&reset);
    for(unsigned p=0;p<2;p++){
        usbd_endp_param_t *param=&h.endp_params[USB_DIR_OUT][p+4];
        assert(param->status==ENDP_STA_IDLE&&!param->xfer_buffer&&!param->xfer_offset&&!param->xfer_length);
    }
    puts("REAL_WCH_CORE_RX_PASS cycles=4000 one_packet_dma=true no_main_rearm=true short_zlp=true backpressure_rearm=true independent_in=true reset=true physical_speed=false");
}
