/* Experimental polling-only continuation of the same one-packet OUT DMA.
 * The real WCH core resets the offset and reuses the buffer before applying
 * our returned ACK. data_cb has already copied this packet into the bounded
 * bridge. Never enlarge the receive, wait for a batch, or rearm inside it.
 * A full queue, reset, suspend or loader reply returns to main-loop rearming.
 */
static bool wk_file_rx_continue(unsigned p,unsigned ep) {
#ifdef WK_BULK_PROBE
    if(p<2&&ep==(p?5u:4u)&&wk_probe_active(p)){
        return wk_probe_space(p)&&!reset_pending[p]&&bridge.online[p]&&usbd_is_enum(handles[p])&&
            !((p?USBHS2D->MIS_ST:USBHS1D->MIS_ST)&USBHS_UDMS_SUSPEND);
    }
#endif
    if(p>1||ep!=(p?5u:4u)||!wk_cable_setup_size())return false;
    if(p==0&&wk_cable_setup_pending())return false;
    for(unsigned i=0;i<2;i++) {
        if(!handles[i]||reset_pending[i]||!bridge.online[i]||!usbd_is_enum(handles[i]))return false;
        if((i?USBHS2D->MIS_ST:USBHS1D->MIS_ST)&USBHS_UDMS_SUSPEND)return false;
    }
    return wk407_bulk_space(&bridge,p);
}
