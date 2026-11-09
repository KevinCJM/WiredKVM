#include "descriptors.h"
#include "wkmt2.h"
#include <string.h>
/* Development identities only. Commercial release needs an authorized VID/PID.
 * Host CDC #0: commands; CDC #1: files. Target: HID + vendor HID + file CDC.
 * Independent read-only MSC bootstraps both computers before apps exist. */
static const uint8_t relative[] = {
    0x05,1,0x09,6,0xa1,1,0x85,1,0x05,7,0x19,0xe0,0x29,0xe7,0x15,0,0x25,1,
    0x75,1,0x95,8,0x81,2,0x75,8,0x95,1,0x81,1,0x15,0,0x26,0xff,0,0x19,0,0x29,0xff,0x95,6,0x81,0,0xc0,
    0x05,1,0x09,1,0xa1,1,0x85,2,0x09,1,0xa1,0,0x05,9,0x19,1,0x29,5,0x15,0,0x25,1,
    0x75,1,0x95,5,0x81,2,0x95,3,0x81,1,0x05,1,0x09,0x30,0x09,0x31,0x09,0x38,
    0x15,0x81,0x25,0x7f,0x75,8,0x95,3,0x81,6,0x05,0x0c,0x0a,0x38,2,0x95,1,0x81,6,0xc0,0xc0,
    0x05,0x0c,0x09,1,0xa1,1,0x85,4,0x15,0,0x26,0xff,3,0x19,0,0x2a,0xff,3,0x75,16,0x95,1,0x81,0,0xc0
};
static const uint8_t absolute[] = {
    0x05,1,0x09,1,0xa1,1,0x85,3,0x09,2,0xa1,2,0x05,9,0x19,1,0x29,5,0x15,0,0x25,1,
    0x75,1,0x95,5,0x81,2,0x95,3,0x81,1,0x05,1,0x09,0x30,0x09,0x31,0x15,0,0x26,0xff,0x7f,
    0x75,16,0x95,2,0x81,2,0x09,0x38,0x15,0x81,0x25,0x7f,0x75,8,0x95,1,0x81,6,
    0x05,0x0c,0x0a,0x38,2,0x81,6,0xc0,0xc0
};
static const uint8_t clipboard[] = {0x06,0x60,0xff,0x09,0x61,0xa1,1,0x15,0,0x26,0xff,0,0x75,8,0x95,64,0x09,0x62,0x81,2,0x95,64,0x09,0x63,0x91,2,0xc0};
static const uint8_t *reports[]={relative,absolute,clipboard};
static const unsigned report_sizes[]={sizeof(relative),sizeof(absolute),sizeof(clipboard)};
#define LO(n) ((n)&255)
#define HI(n) (((n)>>8)&255)
#define CDC(itf,notif,ep,packet,str) \
 8,11,itf,2,2,2,1,str, 9,4,itf,0,1,2,2,1,str, \
 5,0x24,0,0x10,1, 5,0x24,1,0,(itf)+1, 4,0x24,2,2, 5,0x24,6,itf,(itf)+1, \
 7,5,0x80|notif,3,8,0,9, 9,4,(itf)+1,0,2,10,0,0,str, \
 7,5,ep,2,LO(packet),HI(packet),0, 7,5,0x80|ep,2,LO(packet),HI(packet),0
#define HID(itf,ep,len,interval) 9,4,itf,0,1,3,0,0,0, 9,0x21,0x11,1,0,1,0x22,LO(len),HI(len), 7,5,0x80|ep,3,64,0,interval
#define CLIP(interval) 9,4,2,0,2,3,0,0,0, 9,0x21,0x11,1,0,1,0x22,sizeof(clipboard),0, 7,5,0x83,3,64,0,interval, 7,5,3,3,64,0,interval
#define MSC(itf,ep,packet) 9,4,itf,0,2,8,6,0x50,6,7,5,ep,2,LO(packet),HI(packet),0,7,5,0x80|ep,2,LO(packet),HI(packet),0
#define HOST(packet) 9,2,164,0,5,1,0,0x80,50, CDC(0,1,2,packet,4),CDC(2,3,4,packet,5),MSC(4,5,packet)
#define TARGET(packet,interval) 9,2,205,0,7,1,0,0x80,50,HID(0,1,sizeof(relative),interval),HID(1,2,sizeof(absolute),interval),CLIP(interval),CDC(3,4,5,packet,5),MSC(5,6,packet),HID(6,7,WKMT2_REPORT_DESCRIPTOR_SIZE,interval)
static const uint8_t host_hs[]={HOST(512)},host_fs[]={HOST(64)};
static const uint8_t target_hs[]={TARGET(512,4)},target_fs[]={TARGET(64,1)};
_Static_assert(sizeof(host_hs)==164,"host config length");
_Static_assert(sizeof(target_hs)==205,"target config length");
static uint8_t devices[2][18]={
 {18,1,0,2,0xef,2,1,64,0x86,0x1a,0x70,0x40,0,2,1,2,3,1},
 {18,1,0,2,0xef,2,1,64,0xac,0x05,0x65,0x02,0x6d,2,1,2,3,1}};
static const uint8_t qualifier[]={10,6,0,2,0xef,2,1,64,1,0};
static uint8_t other[2][205];
static uint16_t strings[2][64];
usb_rst_e wk407_descriptor(usbd_handle_t *h,const usb_req_t *r,void **buf,size_t *size) {
    unsigned p=wk407_port(h),type=r->wValue>>8,index=r->wValue&255;
    bool hs=usbd_get_speed(h)==USB_SPEED_HIGH;
    *buf=NULL;*size=0;
    if(type==1){*buf=devices[p];*size=18;}
    else if(type==2||type==7){
        bool high=type==7?!hs:hs;const uint8_t *c=p?(high?target_hs:target_fs):(high?host_hs:host_fs);
        *size=p?sizeof(target_hs):sizeof(host_hs);
        if(type==7){memcpy(other[p],c,*size);other[p][1]=7;*buf=other[p];}else *buf=(void*)c;
    } else if(type==6){*buf=(void*)qualifier;*size=sizeof(qualifier);}
    else if(type==3){
        const char *list[]={"","WiredKVM Prototype",p?"WiredKVM CH32 Target":"WiredKVM Petros V467 Host","CH32V407-DoNotShip", "WiredKVM Control","WiredKVM Files","WiredKVM Setup"};
        if(index>=7)return USB_RST_FAILED;
        unsigned n=index?(unsigned)strlen(list[index]):1;
        strings[p][0]=(uint16_t)(0x0300|((n+1)*2));
        for(unsigned i=0;i<n;i++)strings[p][i+1]=index?(uint8_t)list[index][i]:0x0409;
        *buf=strings[p];*size=(n+1)*2;
    }
    if(*size>r->wLength)*size=r->wLength;
    return *buf?USB_RST_OK:USB_RST_FAILED;
}
usb_rst_e wk407_hid_descriptor(usbd_handle_t *h,const usb_req_t *r,void **buf,size_t *size) {
    if(wk407_port(h)!=1||r->wIndex>=3)return USB_RST_FAILED;
    static uint8_t hid_desc[3][9];unsigned i=r->wIndex;
    if(r->wValue>>8==0x22){*buf=(void*)reports[i];*size=report_sizes[i];}
    else if(r->wValue>>8==0x21){uint8_t d[]={9,0x21,0x11,1,0,1,0x22,LO(report_sizes[i]),HI(report_sizes[i])};memcpy(hid_desc[i],d,9);*buf=hid_desc[i];*size=9;}
    else return USB_RST_FAILED;
    if(*size>r->wLength)*size=r->wLength;return USB_RST_OK;
}
