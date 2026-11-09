/* Experimental hardware boundary; not a general SDK abort API.
 * CH32V407RM V1.3: 22.2.1.8/.10/.34. DONE/NAK_ACT are write-zero-clear;
 * DONE drives the transfer interrupt. Do not reopen or reset DATA toggle.
 * The caller retains its DMA buffer and busy flag until this returns true.
 */
#include "single_port_abort.h"
#include "ch32v4x7.h"
#include "ch32v4x7_usb.h"

/* Test register models implement write-zero-clear and a completion racing the
 * read/write. Production builds use the actual volatile peripheral register. */
#ifndef WKAP_EP82_CTRL_READ
#define WKAP_EP82_CTRL_READ() (USBHS2D->UEP2_TX_CTRL)
#define WKAP_EP82_CTRL_WRITE(v) (USBHS2D->UEP2_TX_CTRL=(v))
#endif

bool wkap_abort_ep82(usbd_handle_t *h) {
    /* A reset owns endpoint reinitialization. Do not race its settling period. */
    if(USBHS2D->INT_FG & USBHS_UDIF_BUS_RST)return false;

    /* Preserve a completion arriving between read and write: a plain RMW
     * would write a stale zero to DONE and erase the hardware event. In auto
     * toggle mode the toggle field is hardware-owned and is not reconfigured.
     */
    WKAP_EP82_CTRL_WRITE((WKAP_EP82_CTRL_READ() & ~USBHS_UEP_T_RES_MASK)
        | USBHS_UEP_T_RES_NAK | USBHS_UEP_T_DONE | USBHS_UEP_T_NAK_ACT);
#if defined(__riscv)
    __asm volatile("fence iorw,iorw" ::: "memory");
#endif

    /* No spin wait: the ordinary polling loop services pending completions.
     * NAK prevents a fresh data transaction. An older transaction must finish
     * before ownership can pass to a new report. Never clear its DONE here.
     */
    if(!(USBHS2D->MIS_ST & USBHS_UDMS_SIE_FREE))return false;
    if(WKAP_EP82_CTRL_READ() & USBHS_UEP_T_DONE)return false;
    if(USBHS2D->INT_FG & USBHS_UDIF_BUS_RST)return false;
    return usbd_endp_set_response(h,0x82,ENDP_RESP_NAK)==USB_RST_OK;
}
