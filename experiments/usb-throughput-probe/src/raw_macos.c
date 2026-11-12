/* Opt-in FILE-interface comparison. No device seizure, reset, configuration
 * change, HID/control access, driver install or kernel extension. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { IOUSBInterfaceInterface942 **interface; UInt8 input,output; } raw_port;
static CFTypeRef prop(io_registry_entry_t e,CFStringRef key) {
    return IORegistryEntrySearchCFProperty(e,kIOServicePlane,key,kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
}
static int64_t num(io_registry_entry_t e,CFStringRef key) {
    CFTypeRef v=prop(e,key);int64_t n=-1;
    if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberSInt64Type,&n);
    if(v)CFRelease(v);return n;
}
static int str(io_registry_entry_t e,CFStringRef key,const char *wanted) {
    char s[160];CFTypeRef v=prop(e,key);
    int ok=v&&CFGetTypeID(v)==CFStringGetTypeID()&&CFStringGetCString(v,s,sizeof(s),kCFStringEncodingUTF8)&&!strcmp(s,wanted);
    if(v)CFRelease(v);return ok;
}
void wk_probe_raw_close(void *opaque) {
    raw_port *p=opaque;if(!p)return;
    if(p->interface){(*p->interface)->USBInterfaceClose(p->interface);(*p->interface)->Release(p->interface);}
    free(p);
}
void *wk_probe_raw_open(unsigned role) {
    if(role>1){errno=EINVAL;return NULL;}
    io_iterator_t it=0;io_registry_entry_t e,found=0;unsigned count=0;
    if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&it)){errno=ENODEV;return NULL;}
    while((e=IOIteratorNext(it))){
        int match=num(e,CFSTR("bInterfaceClass"))==10&&num(e,CFSTR("bInterfaceNumber"))==(role?4:3)&&
            num(e,CFSTR("idVendor"))==(role?0x05ac:0x1a86)&&num(e,CFSTR("idProduct"))==(role?0x0265:0x4070)&&
            str(e,CFSTR("USB Serial Number"),"CH32V407-DoNotShip")&&
            (role?num(e,CFSTR("bcdDevice"))==0x026e:str(e,CFSTR("USB Product Name"),"WiredKVM Petros V467 Host"));
        if(match){count++;if(!found){IOObjectRetain(e);found=e;}}IOObjectRelease(e);
    }
    IOObjectRelease(it);
    if(count!=1){if(found)IOObjectRelease(found);errno=count?EBUSY:ENODEV;return NULL;}
    IOCFPlugInInterface **plugin=NULL;SInt32 score=0;
    IOReturn status=IOCreatePlugInInterfaceForService(found,kIOUSBInterfaceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);
    IOObjectRelease(found);
    if(status||!plugin){errno=EACCES;return NULL;}
    IOUSBInterfaceInterface942 **interface=NULL;
    HRESULT query=(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942),(LPVOID*)&interface);
    IODestroyPlugInInterface(plugin);
    if(query||!interface){errno=ENOTSUP;return NULL;}
    /* Never use USBInterfaceOpenSeize. A claimed interface is a clean refusal. */
    status=(*interface)->USBInterfaceOpen(interface);
    if(status){(*interface)->Release(interface);errno=status==kIOReturnExclusiveAccess?EBUSY:EACCES;return NULL;}
    raw_port *p=calloc(1,sizeof(*p));
    if(!p){(*interface)->USBInterfaceClose(interface);(*interface)->Release(interface);errno=ENOMEM;return NULL;}
    p->interface=interface;UInt8 number=0,cls=0,endpoints=0;
    if((*interface)->GetInterfaceNumber(interface,&number)||number!=(role?4:3)||
       (*interface)->GetInterfaceClass(interface,&cls)||cls!=10||
       (*interface)->GetNumEndpoints(interface,&endpoints)||endpoints!=2)goto mismatch;
    for(UInt8 i=1;i<=endpoints;i++){
        UInt8 direction=0,endpoint=0,kind=0,interval=0;UInt16 packet=0;
        if((*interface)->GetPipeProperties(interface,i,&direction,&endpoint,&kind,&packet,&interval)||
           endpoint!=(role?5:4)||kind!=kUSBBulk||packet!=512)goto mismatch;
        if(direction==kUSBIn){if(p->input)goto mismatch;p->input=i;}
        else if(direction==kUSBOut){if(p->output)goto mismatch;p->output=i;}
        else goto mismatch;
    }
    if(!p->input||!p->output)goto mismatch;
    return p;
mismatch:wk_probe_raw_close(p);errno=ENODEV;return NULL;
}
int64_t wk_probe_raw_read(void *opaque,void *bytes,uint32_t size,uint32_t ms) {
    raw_port *p=opaque;if(!p||!size||size>65536||!ms||ms>70000){errno=EINVAL;return -1;}
    UInt32 actual=size;
    IOReturn status=(*p->interface)->ReadPipeTO(p->interface,p->input,bytes,&actual,ms,ms);
    if(status){errno=status==kIOUSBTransactionTimeout?ETIMEDOUT:EIO;return -1;}
    if(actual>size){errno=EIO;return -1;}return actual;
}
int64_t wk_probe_raw_write(void *opaque,const void *bytes,uint32_t size,uint32_t ms) {
    raw_port *p=opaque;if(!p||!size||size>65536||!ms||ms>70000){errno=EINVAL;return -1;}
    IOReturn status=(*p->interface)->WritePipeTO(p->interface,p->output,(void*)bytes,size,ms,ms);
    if(status){errno=status==kIOUSBTransactionTimeout?ETIMEDOUT:EIO;return -1;}return size;
}
