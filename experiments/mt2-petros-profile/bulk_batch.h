/* Polling USB adapter only. Include after send() in generated main.c.
 * One owner, one bounded copy, no fill delay and no shared input capacity.
 * A successful submit gives DMA its own immutable copy before queue removal. */
#define WK_FILE_BATCH_CELLS 8u
static uint8_t file_tx[2][WK_FILE_BATCH_CELLS*WK407_BULK_PACKET]
    __attribute__((aligned(4)));

static void send_file_batch(unsigned p,unsigned ep) {
    if(busy[p][ep])return;
    wk407_bulk_queue *q=&bridge.bulk[p];
    unsigned count=q->count;
    unsigned limit=usbd_get_speed(handles[p])==USB_SPEED_HIGH?WK_FILE_BATCH_CELLS:1u;
    if(count>limit)count=limit;
    if(!count)return;
    for(unsigned i=0;i<count;i++) {
        const wk407_bulk_packet *v=&q->item[(q->head+i)%WK407_BULK_SLOTS];
        /* Ordinary admitted cells are exactly 512 bytes. Preserve the legacy
         * single-packet path if another producer ever supplies a short one. */
        if(v->size!=WK407_BULK_PACKET) {
            if(!i){send(p,ep,1,v->bytes,v->size);return;}
            count=i;break;
        }
        memcpy(file_tx[p]+i*WK407_BULK_PACKET,v->bytes,WK407_BULK_PACKET);
    }
    if(usbd_upload(handles[p],(uint8_t)(ep|128),file_tx[p],count*WK407_BULK_PACKET)!=USB_RST_OK)return;
    busy[p][ep]=true;tx_epoch[p][ep]=bridge.epoch;tx_kind[p][ep]=1;
    tx_hid_epoch[p][ep]=bridge.hid_epoch;
    for(unsigned i=0;i<count;i++)wk407_bulk_done(&bridge,p);
}
