#include <assert.h>
#include <stdio.h>
#include <string.h>
#define main firmware_entry
#include "GENERATED_MAIN"
#undef main
int mock_speed=2;uint32_t SystemCoreClock=8000;
mock_systick mock_tick;mock_usb mock_usb1,mock_usb2;
usbd_handle_t usbhs1d_handle={true,0},usbhs2d_handle={true,1};
static uint8_t ctrl87;
static unsigned packets[2][8],touch_size,touch_down,touch_release,touch_zero;
#ifdef WKMT2_NATIVE
typedef struct __attribute__((packed)){signed short x:13; signed short y:13;unsigned char finger:3,state:3;unsigned char major,minor,size,pressure;unsigned char id:4,reserved:1,orientation:3;} native_finger;
_Static_assert(sizeof(native_finger)==9,"Independent C packed ABI");
#endif
static uint8_t touch_bytes[64];
#ifdef WK_BULK_RX_TEST
static unsigned downloads[2][8],download_bytes[2][8];
int usbd_download(usbd_handle_t *h,uint8_t ep,void *b,unsigned n){
    assert(b==rx[h->port][ep]&&n<=512);
    if(ep==(h->port?5u:4u))assert(n==(mock_speed==USB_SPEED_HIGH?512u:64u));
    downloads[h->port][ep]++;download_bytes[h->port][ep]=n;return USB_RST_OK;
}
#endif
#ifdef WK_BULK_BATCH_TEST
static unsigned endpoint_flags[2][256],file_size[2],file_uploads[2];
static uint8_t file_copy[2][16384];
static const void *file_dma[2];
static bool fail_file_upload;
#endif
#ifdef WK_RAM_SETUP
static uint8_t ram[WK_SETUP_FLASH_BYTES],program_ack[512];
static unsigned program_acks;
bool wk_setup_flash_init(void){return true;}
int32_t wk_cable_platform_ready(void){return 1;}
void wk_cable_platform_diagnostic(uint32_t *out,size_t n){for(size_t i=0;i<n;i++)out[i]=(uint32_t)i;}
int32_t wk_cable_platform_write(uint32_t offset,const uint8_t *b,size_t n){assert(offset+n<=sizeof(ram));memcpy(ram+offset,b,n);return 1;}
bool wk_setup_flash_read(void *ctx,uint32_t at,void *out,size_t n){(void)ctx;uint32_t size=wk_cable_setup_size();if(at>size||n>size-at)return false;memcpy(out,ram+at,n);return true;}
#endif
uint8_t mock_ep87_read(void){return ctrl87;}
void mock_ep87_write(uint8_t v){ctrl87=(ctrl87&v&0xc0)|(ctrl87&0x0c)|(v&3);}
void usbd_endp_close(usbd_handle_t *h,unsigned ep){(void)h;(void)ep;assert(0);}
int usbd_endp_open(usbd_handle_t *h,unsigned ep,unsigned flags,unsigned n){
#ifdef WK_BULK_BATCH_TEST
    endpoint_flags[h->port][ep]=flags;
    if(flags&USBD_ENDP_FEATURE_BURST)assert(mock_speed==USB_SPEED_HIGH&&n==512&&ep==(h->port?0x85u:0x84u));
#endif
    (void)h;(void)ep;(void)flags;(void)n;return 0;}
int usbd_endp_set_response(usbd_handle_t *h,uint8_t ep,int response){
    if(h->port==1&&ep==0x87){assert(response==ENDP_RESP_NAK&&!(ctrl87&128));}return 0;
}
int usbd_upload(usbd_handle_t *h,uint8_t ep,const void *b,unsigned n){
#ifdef WK_BULK_BATCH_TEST
    if(ep==(h->port?0x85:0x84)) {
        if(fail_file_upload){fail_file_upload=false;return -1;}
        unsigned limit=4096;
#ifdef WK_BULK_PROBE_TEST
        if(wk_probe_active(h->port)&&(wk_probe_ports[h->port].mode==2||wk_probe_ports[h->port].mode==5))limit=sizeof(wk_probe_ports[h->port].dma);
#endif
        assert(n>0&&n<=limit&&(n%512==0
#ifdef WK_BULK_PROBE_TEST
            ||(n==64&&!memcmp(b,"WKBR",4))
#endif
        ));
        if(mock_speed!=USB_SPEED_HIGH)assert(n<=512);
        memcpy(file_copy[h->port],b,n);file_dma[h->port]=b;file_size[h->port]=n;file_uploads[h->port]++;
    } else assert(n<=512);
#endif
    const unsigned e=ep&127;assert(!busy[h->port][e]);packets[h->port][e]++;
#ifdef WK_RAM_SETUP
    if(h->port==0&&ep==0x84&&n==512&&!memcmp(b,"WKIA",4)){memcpy(program_ack,b,n);program_acks++;}
#endif
    if(h->port==1&&ep==0x87){assert(n>=12&&n<=57);
#ifdef WKMT2_NATIVE
        const uint8_t *raw=b;assert((raw[9]&7)==4);
        for(unsigned offset=12;offset<n;offset+=9){const native_finger *f=(const void *)(raw+offset);assert(f->finger>=1&&f->finger<=5&&f->id>=1);assert(f->state==0||f->state==3||f->state==4||f->state==7);}
#endif
memcpy(touch_bytes,b,n);touch_size=n;ctrl87=(ctrl87&~3)|2;
        if(n==12)touch_zero++;else if(((const uint8_t *)b)[15]&0x40)touch_release++;else touch_down++;}
    return 0;
}
static void complete(unsigned p,unsigned e){if(busy[p][e]){
#ifdef WK_BULK_BATCH_TEST
    if(e==(p?5u:4u))assert(!memcmp(file_dma[p],file_copy[p],file_size[p]));
#endif
    if(p==1&&e==7){ctrl87^=4;ctrl87|=128;}
    data_cb(handles[p],(uint8_t)(e|128),NULL,0);
    if(p==1&&e==7)ctrl87&=~131;
}}
static void pass(unsigned delta,bool touches){mock_tick.CNT+=delta;service();for(unsigned p=0;p<2;p++)for(unsigned e=1;e<8;e++)if(touches||p!=1||e!=7)complete(p,e);}
static void line(const char *s){for(size_t i=0;i<strlen(s);i++)data_cb(handles[0],2,(void *)(s+i),1);}
static void wk(unsigned seq,char kind,int a,int b){char body[80],row[96];int n=snprintf(body,sizeof(body),"WK1,%u,%c,%d,%d",seq,kind,a,b);snprintf(row,sizeof(row),"%s,%02X\n",body,wk_crc8((const uint8_t *)body,(size_t)n));line(row);}
static void gesture(unsigned epoch,unsigned count){uint8_t b[64]={2,0,0,0,0,0,0,1,0x31,0,0,0x88};
    for(unsigned i=0;i<count;i++){b[12+9*i+3]=0x80;b[12+9*i+4]=72;b[12+9*i+5]=48;b[12+9*i+6]=31;b[12+9*i+7]=64;b[12+9*i+8]=(uint8_t)(0x80|i);}
#ifdef WKMT2_NATIVE
    b[9]=4;b[10]=0;b[11]=0;
    for(unsigned i=0;i<count;i++){b[15+9*i]=(uint8_t)(0x80|((i+2)<<2));b[20+9*i]=(uint8_t)(0x80|(i+1));}
#endif
    char row[192];int n=snprintf(row,sizeof(row),"MT2D,%u,",epoch);for(unsigned i=0;i<12+9*count;i++)n+=snprintf(row+n,sizeof(row)-(size_t)n,"%02x",b[i]);row[n++]='\n';row[n]=0;line(row);
}
#ifdef WK_RAM_SETUP
static uint32_t image_crc(const uint8_t *b,size_t n){uint32_t v=~0u;while(n--){v^=*b++;for(unsigned i=0;i<8;i++)v=(v>>1)^((v&1)?0xedb88320u:0);}return ~v;}
static void put32(uint8_t *b,uint32_t n){for(unsigned i=0;i<4;i++)b[i]=(uint8_t)(n>>(i*8));}
static void program_cell(uint8_t op,uint32_t at,const uint8_t *b,unsigned n,uint32_t size,uint32_t checksum){
    uint8_t cell[512]={0};memcpy(cell,"WKIM",4);cell[4]=1;cell[5]=op;cell[8]=91;
    put32(cell+16,at);put32(cell+20,size);put32(cell+24,checksum);cell[28]=(uint8_t)n;cell[29]=(uint8_t)(n>>8);
    if(n)memcpy(cell+32,b,n);put32(cell+508,image_crc(cell,508));unsigned before=program_acks;
    for(unsigned p=0;p<512;){unsigned bytes=512-p;if(bytes>73)bytes=73;data_cb(handles[0],4,cell+p,bytes);p+=bytes;}
    pass(4,true);assert(program_acks==before+1&&image_crc(program_ack,508)==(uint32_t)(program_ack[508]|(uint32_t)program_ack[509]<<8|(uint32_t)program_ack[510]<<16|(uint32_t)program_ack[511]<<24));
    assert(program_ack[5]==(op==3?1:0));
}
static void program_test(const uint8_t *pressure){
    static uint8_t asset[4096+16384];memset(asset,0x95,sizeof(asset));memcpy(asset,"WKDUAL01",8);
    put32(asset+8,1);put32(asset+12,sizeof(asset)-4096);put32(asset+16,image_crc(asset+4096,sizeof(asset)-4096));put32(asset+20,image_crc(asset,20));
    uint32_t checksum=image_crc(asset,sizeof(asset));unsigned touch=packets[1][7],keys=packets[1][1],files=packets[1][5];
    program_cell(1,0,NULL,0,sizeof(asset),checksum);assert(!wk_cable_setup_size());
    for(unsigned at=0;at<sizeof(asset);){unsigned n=sizeof(asset)-at;if(n>476)n=476;
        for(unsigned p=0;p<2;p++)for(unsigned i=0;i<WK407_BULK_SLOTS&&wk407_bulk_space(&bridge,p);i++)assert(wk407_bulk_accept(&bridge,p,pressure,512));
        wk(10000+at,'T',4,(at/476)&1);gesture(2,4);program_cell(2,at,asset+at,n,sizeof(asset),checksum);at+=n;assert(!setup.valid);}
    program_cell(3,sizeof(asset),NULL,0,sizeof(asset),checksum);
    wk(62000,'T',4,0);
    for(unsigned i=0;i<40;i++)pass(1,true);
    assert(setup.valid&&wk_cable_setup_size()==sizeof(asset)&&!memcmp(asset,ram,sizeof(asset)));
    assert(packets[1][7]>touch+10&&packets[1][1]>keys&&packets[1][5]>files);
    puts("RAM_SETUP_MAIN_PASS readonly_image_published=true interleaved_touch_keys_bulk=true physicalPSRAM=false");
}
#endif
#ifdef WK_BULK_BATCH_TEST
static void batch_control(unsigned p,unsigned kind,unsigned origin,unsigned generation,unsigned id) {
    uint8_t control[64]={0};memcpy(control,"WKB5",4);control[4]=(uint8_t)kind;control[5]=(uint8_t)origin;
    control[8]=1;memset(control+16,(int)id,16);control[32]=(uint8_t)generation;
    uint32_t crc=~0u;for(unsigned i=0;i<60;i++){crc^=control[i];for(unsigned bit=0;bit<8;bit++)crc=(crc>>1)^((crc&1)?0xedb88320u:0);}
    crc=~crc;for(unsigned i=0;i<4;i++)control[60+i]=(uint8_t)(crc>>(8*i));
    assert(wk407_clipboard(&bridge,p,control,sizeof(control)));
}
static void batch_test(const uint8_t *cell) {
    uint8_t row[512],expected[13][512];
    for(unsigned p=0;p<2;p++) {
        unsigned ep=p?5:4;complete(p,ep);
        wk407_bulk_queue *q=&bridge.bulk[p];q->head=WK407_BULK_SLOTS-3;q->count=0;
        for(unsigned i=0;i<13;i++){
            memcpy(row,cell,512);memset(row+64,(int)(i+1),448);memcpy(expected[i],row,512);
            assert(wk407_bulk_accept(&bridge,1-p,row,512));
        }
        fail_file_upload=true;unsigned before=file_uploads[p];send_file_batch(p,ep);
        assert(!busy[p][ep]&&q->count==13&&file_uploads[p]==before);
        send_file_batch(p,ep);assert(busy[p][ep]&&file_size[p]==4096&&q->count==5);
        assert(!memcmp(file_copy[p],expected,4096));
        /* Reuse all popped ring slots while DMA retains its independent copy. */
        while(wk407_bulk_space(&bridge,1-p))assert(wk407_bulk_accept(&bridge,1-p,cell,512));
        send_file_batch(p,ep);assert(file_uploads[p]==before+1);
        complete(p,ep);assert(q->count==WK407_BULK_SLOTS);
        q->head=q->count=0;
        assert(wk407_bulk_accept(&bridge,1-p,expected[0],512));
        send_file_batch(p,ep);assert(file_size[p]==512&&q->count==0);complete(p,ep);
        mock_speed=1;
        for(unsigned i=0;i<3;i++)assert(wk407_bulk_accept(&bridge,1-p,cell,512));
        send_file_batch(p,ep);assert(file_size[p]==512&&q->count==2);complete(p,ep);
        mock_speed=USB_SPEED_HIGH;q->head=q->count=0;
        unsigned origin=1-p,old_id=0x51+p,new_id=0x61+p;
        bridge.transactions[origin][0].generation=1;bridge.stream_generation[origin]=1;
        memset(bridge.transactions[origin][0].id,(int)old_id,16);
        memcpy(row,cell,512);memset(row+20,(int)old_id,16);
        for(unsigned i=0;i<13;i++)assert(wk407_bulk_accept(&bridge,origin,row,512));
        send_file_batch(p,ep);assert(file_size[p]==4096&&q->count==5);
        batch_control(p,3,origin,1,old_id);assert(q->count==0&&busy[p][ep]);
        assert(wk407_bulk_accept(&bridge,origin,row,512)&&q->count==0);
        batch_control(p,2,origin,2,new_id);memset(row+20,(int)new_id,16);
        assert(wk407_bulk_accept(&bridge,origin,row,512)&&q->count==1);
        complete(p,ep);assert(q->count==1); /* old DMA completion cannot pop the new ID */
        send_file_batch(p,ep);assert(file_size[p]==512&&q->count==0&&!memcmp(file_copy[p],row,512));complete(p,ep);
        memset(bridge.transactions[origin],0,sizeof(bridge.transactions[origin]));
        bridge.transactions[origin][0].used=true;memcpy(bridge.transactions[origin][0].id,cell+20,16);bridge.stream_generation[origin]=0;
        while(wk407_urgent_peek(&bridge,origin))wk407_urgent_done(&bridge,origin);
    }
    puts("BULK_BATCH_PASS max_in=4096 no_fill_wait=true full_speed=512 failed_submit_retains_queue=true ring_wrap=true dma_immutable=true cancel_purges_queued_old_id=true stale_dma_retains_new_id=true");
}
static void stalled_batch_test(const uint8_t *cell) {
    unsigned keys=packets[1][1],touches=packets[1][7];
    for(unsigned i=0;i<200;i++) {
        for(unsigned p=0;p<2;p++)while(wk407_bulk_space(&bridge,p))assert(wk407_bulk_accept(&bridge,p,cell,512));
        wk(7000+i,'T',4,(int)(i&1));gesture(1,i&1?4:2);
        mock_tick.CNT+=4;service();
        /* Both file IN transfers remain owned by DMA for the entire run. */
        complete(1,1);complete(1,2);complete(1,3);complete(1,7);complete(0,2);
        for(unsigned p=0;p<2;p++)assert(!memcmp(file_dma[p],file_copy[p],file_size[p]));
    }
    assert(packets[1][1]>=keys+190&&packets[1][7]>=touches+190);
    for(unsigned p=0;p<2;p++){complete(p,p?5:4);bridge.bulk[p].head=bridge.bulk[p].count=0;}
    wk(7300,'T',4,0);pass(4,true);
    puts("BULK_STALL_INPUT_PASS blocked_file_ms=800 keyboard_and_two_four_finger_progress=true no_device_access=true");
}
#endif
#ifdef WK_BULK_RX_TEST
static void continuous_rx_test(const uint8_t *cell) {
    for(unsigned p=0;p<2;p++) {
        unsigned ep=p?5:4;wk407_bulk_queue *q=&bridge.bulk[1-p];
        complete(1-p,p?4:5);q->head=WK407_BULK_SLOTS-3;q->count=0;
        bridge.cell_size[p]=0;unsigned before=downloads[p][ep];
        for(unsigned i=0;i<WK407_BULK_SLOTS;i++) {
            memcpy(rx[p][ep],cell,512);memset(rx[p][ep]+80,(int)(i+1),432);
            endp_resp_e response=data_cb(handles[p],(uint8_t)ep,rx[p][ep],512);
            assert(response==(i+1<WK407_BULK_SLOTS?ENDP_RESP_ACK:ENDP_RESP_NAK));
            assert(armed[p][ep]==(i+1<WK407_BULK_SLOTS));
        }
        assert(downloads[p][ep]==before&&q->count==WK407_BULK_SLOTS);
        memset(rx[p][ep],0,512); /* all receive storage is immediately reusable */
        for(unsigned i=0;i<WK407_BULK_SLOTS;i++) {
            const wk407_bulk_packet *v=&q->item[(q->head+i)%WK407_BULK_SLOTS];
            assert(v->size==512&&!memcmp(v->bytes,cell,80));
            for(unsigned j=80;j<512;j++)assert(v->bytes[j]==(uint8_t)(i+1));
        }
        pass(1,true);pass(1,true); /* drain, then explicit one-packet rearm */
        assert(armed[p][ep]&&downloads[p][ep]==before+1&&download_bytes[p][ep]==512);
        for(unsigned i=0;i<2;i++) {
            reset_pending[i]=true;assert(!wk_file_rx_continue(p,ep));reset_pending[i]=false;
            handles[i]->enumerated=false;assert(!wk_file_rx_continue(p,ep));handles[i]->enumerated=true;
            bridge.online[i]=false;assert(!wk_file_rx_continue(p,ep));bridge.online[i]=true;
            mock_usb *reg=i?&mock_usb2:&mock_usb1;uint8_t saved=reg->MIS_ST;
            reg->MIS_ST|=USBHS_UDMS_SUSPEND;assert(!wk_file_rx_continue(p,ep));reg->MIS_ST=saved;
        }
        assert(wk_file_rx_continue(p,ep));
        for(unsigned e=0;e<8;e++)if(e!=ep)assert(!wk_file_rx_continue(p,e));
        q->head=q->count=0;
    }
    /* Full-speed uses eight 64-byte fragments per cell. A final complete cell
     * must enqueue immediately, without a short packet or a 4 KiB fill wait. */
    mock_speed=1;
    for(unsigned p=0;p<2;p++) {
        unsigned ep=p?5:4;wk407_bulk_queue *q=&bridge.bulk[1-p];
        complete(1-p,p?4:5);q->head=q->count=0;bridge.cell_size[p]=0;
        armed[p][ep]=false;arm(p,ep,64);unsigned before=downloads[p][ep];
        for(unsigned i=0;i<4;i++)for(unsigned at=0;at<512;at+=64) {
            memcpy(rx[p][ep],cell+at,64);
            assert(data_cb(handles[p],(uint8_t)ep,rx[p][ep],64)==ENDP_RESP_ACK);
        }
        assert(q->count==4&&bridge.cell_size[p]==0&&downloads[p][ep]==before&&download_bytes[p][ep]==64);
        for(unsigned i=0;i<6;i++)pass(1,true);assert(q->count==0);
    }
    mock_speed=USB_SPEED_HIGH;
    assert(!wk_file_rx_continue(2,4));
    uint8_t query[512]={0};memcpy(query,"WKIM",4);query[4]=1;
    put32(query+508,image_crc(query,508));
    assert(data_cb(handles[0],4,query,512)==ENDP_RESP_NAK);
    assert(wk_cable_setup_pending()&&!armed[0][4]&&!wk_file_rx_continue(0,4));
    pass(1,true);pass(1,true);assert(!wk_cable_setup_pending()&&armed[0][4]);
    unsigned keys=packets[1][1],touches=packets[1][7];
    for(unsigned i=0;i<200;i++) {
        for(unsigned p=0;p<2;p++)for(unsigned n=0;n<8;n++) {
            unsigned ep=p?5:4;assert(wk_file_rx_continue(p,ep));
            assert(data_cb(handles[p],(uint8_t)ep,(void *)cell,512)==ENDP_RESP_ACK);
        }
        wk(63000+i,'T',4,(int)(i&1));gesture(2,i&1?4:2);pass(4,true);
    }
    assert(packets[1][1]>=keys+190&&packets[1][7]>=touches+190);
    /* Cancel a queued old ID after callback continuation; a new ID must not
     * wait for a cancelled queue, or be popped by an old DMA completion. */
    for(unsigned p=0;p<2;p++) {
        unsigned ep=p?5:4,peer=1-p;wk407_bulk_queue *q=&bridge.bulk[peer];
        for(unsigned i=0;i<20;i++)pass(1,true);q->head=q->count=0;
        bridge.transactions[p][0].generation=1;bridge.stream_generation[p]=1;
        for(unsigned i=0;i<10;i++)assert(data_cb(handles[p],(uint8_t)ep,(void *)cell,512)==ENDP_RESP_ACK);
        send_file_batch(peer,peer?5:4);assert(busy[peer][peer?5:4]&&q->count==2);
        batch_control(peer,3,p,1,0x11);assert(q->count==0);
        assert(data_cb(handles[p],(uint8_t)ep,(void *)cell,512)==ENDP_RESP_ACK&&q->count==0);
        batch_control(peer,2,p,2,0x71+p);uint8_t next[512];memcpy(next,cell,512);memset(next+20,(int)(0x71+p),16);
        assert(data_cb(handles[p],(uint8_t)ep,next,512)==ENDP_RESP_ACK&&q->count==1);
        complete(peer,peer?5:4);assert(q->count==1);send_file_batch(peer,peer?5:4);
        assert(file_size[peer]==512&&!memcmp(file_copy[peer],next,512));complete(peer,peer?5:4);
    }
    puts("BULK_RX_PASS bounded_one_packet=true full_queue_nak=true main_loop_rearm=true dma_copied=true loader_reply_nak=true reset_suspend_guards=true input_progress=true cancel_new_id=true physical_speed_verified=false");
}
#endif
#ifdef WK_BULK_PROFILE_TEST
static void bulk_profile_test(void) {
    for(unsigned p=0;p<2;p++) {
        const wk_bulk_profile_port *v=&wk_bulk_profile_ports[p];
        assert(v->tx_bytes>512&&v->tx_batches>0&&v->completed>0);
        assert(v->completed<=v->tx_batches&&v->multi>0&&v->submit_failed>0);
        assert(v->queue_max>0&&v->queue_max<=WK407_BULK_SLOTS);
    }
    uint32_t rx=wk_bulk_profile_ports[0].rx_packets;
    uint32_t loops=wk_bulk_profile_loops;
    line("MT2?\n");pass(1,true);
    assert(wk_bulk_profile_ports[0].rx_packets==rx&&wk_bulk_profile_loops==loops+1);
    uint8_t fragment[64]={0};
    for(unsigned p=0;p<2;p++) {
        uint32_t packets_before=wk_bulk_profile_ports[p].rx_packets,bytes_before=wk_bulk_profile_ports[p].rx_bytes;
        data_cb(handles[p],(uint8_t)(p?5:4),fragment,sizeof(fragment));
        assert(wk_bulk_profile_ports[p].rx_packets==packets_before+1&&wk_bulk_profile_ports[p].rx_bytes==bytes_before+64);
    }
    uint8_t out[512];const uint8_t prefix[]="MT2,version=2,enabled=1,faults=0\n";
    size_t n=wk_bulk_profile_line(prefix,sizeof(prefix)-1,out,sizeof(out),25000000,72000);
    assert(n>sizeof(prefix)&&n<sizeof(out)&&out[n-1]=='\n');out[n]=0;
    assert(!memcmp(prefix,out,sizeof(prefix)-2)&&strstr((char *)out,",bp=1,")&&strstr((char *)out,",bp1="));
    n=wk_bulk_profile_line(prefix,sizeof(prefix)-1,out,sizeof(prefix)-1,25000000,72000);
    assert(n==sizeof(prefix)-1&&!memcmp(out,prefix,n));
    /* Counter wrap is intentional and does not touch the input/bridge state. */
    uint8_t buttons=bridge.buttons;uint32_t epoch=bridge.epoch;
    wk_bulk_profile_ports[0].rx_bytes=UINT32_MAX-511;
    rx=wk_bulk_profile_ports[0].rx_packets;wk_bulk_profile_rx(0,512);
    assert(wk_bulk_profile_ports[0].rx_bytes==0&&wk_bulk_profile_ports[0].rx_packets==rx+1);
    wk_bulk_profile_last=UINT32_MAX-9;wk_bulk_profile_gap=0;
    wk_bulk_profile_loop(5);assert(wk_bulk_profile_gap==15);
    assert(bridge.buttons==buttons&&bridge.epoch==epoch);
    const uint8_t longest[]="MT2,version=2,enabled=1,faults=-2147483648,rx=4294967295,max_contacts=4294967295,resets=4294967295,gets=4294967295,sets=4294967295,get_ids=4294967295,set_ids=4294967295,errors=4294967295,inputs=4294967295\n";
    memset(wk_bulk_profile_ports,255,sizeof(wk_bulk_profile_ports));wk_bulk_profile_loops=wk_bulk_profile_gap=UINT32_MAX;
    n=wk_bulk_profile_line(longest,sizeof(longest)-1,out,sizeof(out),UINT32_MAX,UINT32_MAX);
    assert(n>sizeof(longest)&&n<sizeof(out)&&out[n-1]=='\n');out[n]=0;
    assert(strstr((char *)out,",bp=1,")&&strstr((char *)out,",bp1=ffffffff:"));
    puts("BULK_PROFILE_PASS numeric_only=true bounded_record=true counter_wrap=true control_not_counted_as_file=true no_extra_usb_transaction=true physical_measurement=false");
}
#endif
#ifdef WK_BULK_PROBE_TEST
static void raw_probe_command(unsigned p,unsigned op,uint64_t total){
    uint8_t c[64]={0};memcpy(c,"WKBP",4);c[4]=1;c[5]=(uint8_t)op;wk_probe_put(c+8,711,8);wk_probe_put(c+16,total,8);wk_probe_put(c+60,wk_probe_crc(c,60),4);
    data_cb(handles[p],p?5:4,c,64);pass(1,true);pass(1,true);assert(wk_probe_ports[p].phase==2);
}
static void raw_probe_input_test(const uint8_t *pressure){
    for(unsigned i=0;i<100;i++)pass(1,true);
    /* The independent profiling fixture deliberately left a 64-byte noise
     * fragment. Model a fresh file-session boundary without erasing the image. */
    wk_cable_setup_peer_reset();bridge.cell_size[0]=bridge.cell_size[1]=0;
    /* An older loader ACK is still owned by IN DMA when a new query arrives.
     * Do not arm OUT over the new, unsent acknowledgement. */
    uint8_t query[512]={0};memcpy(query,"WKIM",4);query[4]=1;put32(query+508,image_crc(query,508));
    data_cb(handles[0],4,query,512);service();assert(busy[0][4]&&!wk_cable_setup_pending());
    service();assert(armed[0][4]);data_cb(handles[0],4,query,512);assert(wk_cable_setup_pending()&&!armed[0][4]);
    service();assert(wk_cable_setup_pending()&&!armed[0][4]);complete(0,4);pass(1,true);pass(1,true);
    assert(!wk_cable_setup_pending());
    /* Deliberately put a fully valid diagnostic command INSIDE an ordinary
     * file body and split USB exactly there. It must remain byte-for-byte data. */
    uint8_t ordinary[512];memcpy(ordinary,pressure,512);
    memset(ordinary+64,0,64);memcpy(ordinary+64,"WKBP",4);ordinary[68]=1;ordinary[69]=2;
    wk_probe_put(ordinary+72,711,8);wk_probe_put(ordinary+80,8192,8);wk_probe_put(ordinary+124,wk_probe_crc(ordinary+64,60),4);
    for(unsigned p=0;p<2;p++){
        bridge.stream_session[p]=1;bridge.transactions[p][0].used=true;memcpy(bridge.transactions[p][0].id,ordinary+20,16);
    }
    for(unsigned p=0;p<2;p++){
        unsigned ep=p?5:4;data_cb(handles[p],ep,ordinary,64);data_cb(handles[p],ep,ordinary+64,64);data_cb(handles[p],ep,ordinary+128,384);
        assert(!wk_probe_active(p));const wk407_bulk_packet *v=wk407_bulk_peek(&bridge,1-p);
        assert(v&&v->size==512&&!memcmp(v->bytes,ordinary,512));wk407_bulk_done(&bridge,1-p);
    }
    line("MT2B,3\n");for(unsigned i=0;i<10;i++)pass(1,true);
    unsigned keys=packets[1][1],touches=packets[1][7];uint8_t bytes[512];memset(bytes,0xa5,sizeof(bytes));
    raw_probe_command(0,1,512*1000);
    for(unsigned i=0;i<1000;i++){
        assert(armed[0][4]);data_cb(handles[0],4,bytes,512);
        wk(40000+i*2,'T',4,1);pass(1,true);wk(40001+i*2,'T',4,0);pass(1,true);gesture(3,i%2?4:2);pass(4,true);
    }
    pass(1,true);assert(!wk_probe_active(0)&&wk_probe_ports[0].received==512*1000);
    raw_probe_command(1,2,512*1000);
    for(unsigned i=0;i<1000&&wk_probe_active(1);i++){
        wk(45000+i*2,'T',4,1);pass(1,true);wk(45001+i*2,'T',4,0);pass(1,true);gesture(3,i%2?4:2);pass(4,true);
    }
    assert(!wk_probe_active(1)&&wk_probe_ports[1].sent==512*1000);
    /* Exercise the actual generated service loop, including the first short
     * packet and queue wrap, rather than calling only the standalone core. */
    for(unsigned src=0;src<2;src++){
        unsigned dst=1-src;const unsigned total=65536;
        for(unsigned p=0;p<2;p++){assert(!busy[p][p?5:4]);wk_probe_reset(p);}
        raw_probe_command(dst,5,total);raw_probe_command(src,4,total);
        unsigned accepted=0;
        for(unsigned tries=0;tries<1000&&(wk_probe_active(src)||wk_probe_active(dst));tries++){
            if(accepted<total&&wk_probe_space(src)){
                unsigned n=accepted?512:128;if(n>total-accepted)n=total-accepted;
                assert(armed[src][src?5:4]);data_cb(handles[src],src?5:4,bytes,n);accepted+=n;
            }
            unsigned before=file_uploads[dst];pass(1,true);
            if(file_uploads[dst]!=before&&file_size[dst]>=512){for(unsigned i=0;i<file_size[dst];i++)assert(file_copy[dst][i]==0xa5);}
        }
        assert(accepted==total&&wk_probe_ports[src].received==total&&wk_probe_ports[dst].sent==total);
        assert(!wk_probe_active(src)&&!wk_probe_active(dst));
    }
    puts("BULK_PROBE_RELAY_MAIN_PASS short_first_packet=128 bidirectional=true physicalUSB=false");
    printf("BULK_PROBE_INPUT_COUNTS keyboard=%u touch=%u\n",packets[1][1]-keys,packets[1][7]-touches);
    assert(packets[1][1]>keys+500&&packets[1][7]>touches+100);
    puts("BULK_PROBE_INPUT_PASS real_generated_callbacks=true keyboard_two_four_fingers_progress=true no_filesystem=true physicalUSB=false");
}
#endif
int main(void){
    handles[0]=&usbhs1d_handle;handles[1]=&usbhs2d_handle;mock_usb2.MIS_ST=USBHS_UDMS_SIE_FREE;
    wk407_init(&bridge);
#ifdef WK_RAM_SETUP
    wk_setup_init(&setup,wk_setup_flash_read,NULL);
#else
    wk_setup_init(&setup,NULL,NULL);
#endif
    wkmt2_profile_reset();
#ifdef WK_BULK_BATCH_TEST
    for(mock_speed=1;mock_speed<=USB_SPEED_HIGH;mock_speed++) {
        reset_cb(handles[0],0);reset_cb(handles[1],0);
        for(unsigned p=0;p<2;p++)for(unsigned ep=1;ep<8;ep++) {
            unsigned flags=endpoint_flags[p][ep|128];
            assert(((flags&USBD_ENDP_FEATURE_BURST)!=0)==(mock_speed==USB_SPEED_HIGH&&ep==(p?5u:4u)));
        }
    }
    mock_speed=USB_SPEED_HIGH;
#endif
#ifdef WK_RAM_SETUP
    usbhs2d_handle.enumerated=false;pass(1,true);assert(armed[0][4]);
    usbhs2d_handle.enumerated=true;pass(1,true);
#endif
    void *identity;size_t identity_len;usb_req_t identity_request={.wValue=0x0302,.wLength=128};
    assert(!wk407_descriptor(handles[0],&identity_request,&identity,&identity_len));
    const char *expected="WiredKVM Petros V467 Host";const uint16_t *u=identity;
    assert(identity_len==(strlen(expected)+1)*2);for(unsigned i=0;i<strlen(expected);i++)assert(u[i+1]==(uint8_t)expected[i]);

    for(unsigned i=0;i<20;i++)pass(1,true);
    void *buf;size_t len;usb_req_t r={0x21,9,0x0302,6,2};
    assert(interface_setup(handles[1],&r,&buf,&len)==USB_RST_OK&&len==2);memcpy(buf,(uint8_t[]){2,1},2);
    assert(interface_data(handles[1],&r,buf,len)==USB_RST_OK);
    for(unsigned i=0;i<10;i++)pass(1,true);
    line("MT2B,1\n");gesture(1,4);pass(4,false);assert(busy[1][7]&&touch_size==48);
    complete(1,7);gesture(1,2);pass(4,true);assert(touch_size==30); /* catches submit-vs-completion bug */
    // Fill both file directions to their limits. Keyboard/mouse and touch have
    // separate capacity and still advance in the real main-loop scheduling.
    unsigned before=packets[1][1];
    // Pre-grant both stream sessions; use admitted binary cells. Random bytes
    // are discarded by the parser, so space alone cannot bound a refill loop.
    uint8_t pressure[512]={0};memcpy(pressure,"WKS5",4);pressure[5]=2;
    pressure[8]=1;pressure[12]=1;memset(pressure+20,0x11,16);
    pressure[44]=0xb0;pressure[45]=1;
    for(unsigned p=0;p<2;p++){
        bridge.stream_session[p]=1;bridge.transactions[p][0].used=true;
        memcpy(bridge.transactions[p][0].id,pressure+20,16);
    }
#ifdef WK_BULK_BATCH_TEST
    batch_test(pressure);
#endif
    for(unsigned i=0;i<1000;i++){
        for(unsigned p=0;p<2;p++){
            for(unsigned refill=0;refill<WK407_BULK_SLOTS&&wk407_bulk_space(&bridge,p);refill++){
                unsigned queued=bridge.bulk[1-p].count;
                bool accepted=wk407_bulk_accept(&bridge,p,pressure,sizeof(pressure));
                assert(accepted&&bridge.bulk[1-p].count==queued+1);
            }
            assert(bridge.bulk[1-p].count==WK407_BULK_SLOTS);
        }
        wk(i*3+1,'P',0,0);pass(1,true);wk(i*3+2,'T',4,1-i%2);pass(1,true);wk(i*3+3,'A',1000+i,1000);gesture(1,i%2?4:2);pass(4,true);}
    assert(packets[1][1]>before+100&&packets[1][7]>100&&packets[0][4]>=1000&&packets[1][5]>=1000);
    assert(bridge.buttons==0&&bridge.keys[0]==0);
#ifdef WK_BULK_BATCH_TEST
    stalled_batch_test(pressure);
#endif
    // End while SIE owns an old report. New epoch waits for only its release,
    // not a file queue. A racing completion cannot pop the release head.
    gesture(1,4);pass(4,false);assert(busy[1][7]);mock_usb2.MIS_ST=0;
    line("MT2E,1\n");line("MT2B,2\n");pass(1,false);assert(busy[1][7]&&wkmt2_live_abort_pending());
    complete(1,7);assert(!wkmt2_live_abort_pending());mock_usb2.MIS_ST=8;
    unsigned release_before=touch_release,zero_before=touch_zero;
    for(unsigned i=0;i<12;i++)pass(1,true);
    assert(touch_release>release_before&&touch_zero>zero_before);
    gesture(1,2);unsigned old=touch_down;pass(4,true);assert(touch_down==old);
    gesture(2,4);pass(4,true);assert(touch_down==old+1);
#ifdef WK_RAM_SETUP
    #ifdef WK_BULK_RX_TEST
    assert(!wk_file_rx_continue(0,4)&&!wk_file_rx_continue(1,5));
    #endif
    program_test(pressure);
    #ifdef WK_BULK_RX_TEST
    continuous_rx_test(pressure);
    #endif
#endif
    // Long idle and mid-gesture loss, including host reset, release only touch.
    for(unsigned i=0;i<200;i++)pass(1,true);assert(wkmt2_live_faults()>0);
#ifdef WK_BULK_PROFILE_TEST
    bulk_profile_test();
#endif
#ifdef WK_BULK_PROBE_TEST
    raw_probe_input_test(pressure);
#endif
    puts("LIVE_MAIN_RUST_C_CALLBACK_PASS stress=1000 continuous_bulk_both_directions=true stale_epoch_rejected=true no_device_access=true");
}
