#include "usb_driver.h"
#include "ch32v4x7.h"
#include "ch32v4x7_usb.h"
#include <stdbool.h>
/* Same WCH V4X7 W0C ownership rule as reviewed EP82; EP87 is independent.
 * Keep DONE/NAK_ACT, DATA toggle and DMA until the old interrupt is retired. */
#ifndef WKMT2_EP87_CTRL_READ
#define WKMT2_EP87_CTRL_READ() (USBHS2D->UEP7_TX_CTRL)
#define WKMT2_EP87_CTRL_WRITE(v) (USBHS2D->UEP7_TX_CTRL=(v))
#endif
bool wkmt2_live_abort_usb(usbd_handle_t *h){
    if(USBHS2D->INT_FG&USBHS_UDIF_BUS_RST)return false;
    WKMT2_EP87_CTRL_WRITE((WKMT2_EP87_CTRL_READ()&~USBHS_UEP_T_RES_MASK)|USBHS_UEP_T_RES_NAK | USBHS_UEP_T_DONE | USBHS_UEP_T_NAK_ACT);
#if defined(__riscv)
    __asm volatile("fence iorw,iorw" ::: "memory");
#endif
    if(!(USBHS2D->MIS_ST&USBHS_UDMS_SIE_FREE)||WKMT2_EP87_CTRL_READ()&USBHS_UEP_T_DONE||USBHS2D->INT_FG&USBHS_UDIF_BUS_RST)return false;
    return usbd_endp_set_response(h,0x87,ENDP_RESP_NAK)==USB_RST_OK;
}
