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
uint8_t mock_ep87_read(void){return ctrl87;}
void mock_ep87_write(uint8_t v){ctrl87=(ctrl87&v&0xc0)|(ctrl87&0x0c)|(v&3);}
void usbd_endp_close(usbd_handle_t *h,unsigned ep){(void)h;(void)ep;assert(0);}
int usbd_endp_open(usbd_handle_t *h,unsigned ep,unsigned flags,unsigned n){(void)h;(void)ep;(void)flags;(void)n;return 0;}
int usbd_endp_set_response(usbd_handle_t *h,uint8_t ep,int response){
    if(h->port==1&&ep==0x87){assert(response==ENDP_RESP_NAK&&!(ctrl87&128));}return 0;
}
int usbd_upload(usbd_handle_t *h,uint8_t ep,const void *b,unsigned n){
    const unsigned e=ep&127;assert(!busy[h->port][e]);packets[h->port][e]++;
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
int main(void){
    handles[0]=&usbhs1d_handle;handles[1]=&usbhs2d_handle;mock_usb2.MIS_ST=USBHS_UDMS_SIE_FREE;
    wk407_init(&bridge);wk_setup_init(&setup,NULL,NULL);wkmt2_profile_reset();
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
    // Long idle and mid-gesture loss, including host reset, release only touch.
    for(unsigned i=0;i<200;i++)pass(1,true);assert(wkmt2_live_faults()>0);
    puts("LIVE_MAIN_RUST_C_CALLBACK_PASS stress=1000 continuous_bulk_both_directions=true stale_epoch_rejected=true no_device_access=true");
}
