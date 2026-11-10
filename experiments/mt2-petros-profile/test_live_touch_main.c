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
#ifdef WK_BULK_BATCH_TEST
static unsigned endpoint_flags[2][256],file_size[2],file_uploads[2];
static uint8_t file_copy[2][4096];
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
        assert(n>0&&n<=4096&&n%512==0);
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
    program_test(pressure);
#endif
    // Long idle and mid-gesture loss, including host reset, release only touch.
    for(unsigned i=0;i<200;i++)pass(1,true);assert(wkmt2_live_faults()>0);
    puts("LIVE_MAIN_RUST_C_CALLBACK_PASS stress=1000 continuous_bulk_both_directions=true stale_epoch_rejected=true no_device_access=true");
}
