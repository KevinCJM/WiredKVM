/* OS ABI only; protocol, bounded windows and deadlines are owned by Rust. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
static CFTypeRef prop(io_registry_entry_t e,CFStringRef key) {
    return IORegistryEntrySearchCFProperty(e,kIOServicePlane,key,kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
}
static int64_t number(io_registry_entry_t e,CFStringRef key) {
    CFTypeRef v=prop(e,key);int64_t n=-1;
    if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberSInt64Type,&n);
    if(v)CFRelease(v);return n;
}
static int text(io_registry_entry_t e,CFStringRef key,char *out,size_t n) {
    CFTypeRef v=prop(e,key);int ok=v&&CFGetTypeID(v)==CFStringGetTypeID()&&CFStringGetCString(v,out,n,kCFStringEncodingUTF8);
    if(v)CFRelease(v);return ok;
}
static uint64_t find(const char *wanted,char *path,size_t capacity) {
    io_iterator_t it=0;if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching(kIOSerialBSDServiceValue),&it))return 0;
    io_registry_entry_t e;uint64_t found=0;unsigned count=0;
    while((e=IOIteratorNext(it))) {
        char serial[128],name[128],candidate[256];int64_t iface=number(e,CFSTR("bInterfaceNumber"));
        if(number(e,CFSTR("idVendor"))==0x1a86&&number(e,CFSTR("idProduct"))==0x4070&&(iface==2||iface==3)&&
           text(e,CFSTR("USB Serial Number"),serial,sizeof(serial))&&!strcmp(serial,"CH32V407-DoNotShip")&&
           text(e,CFSTR("USB Product Name"),name,sizeof(name))&&!strcmp(name,"WiredKVM Petros V467 Host")&&
           text(e,CFSTR(kIOCalloutDeviceKey),candidate,sizeof(candidate))&&!strncmp(candidate,"/dev/cu.",8)&&
           (!wanted||!strcmp(wanted,candidate))) {
            count++;IORegistryEntryGetRegistryEntryID(e,&found);if(path)strlcpy(path,candidate,capacity);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);return count==1?found:0;
}
int wk_image_path(char *out,size_t capacity){return find(NULL,out,capacity)?1:0;}
int wk_image_open(const char *path) {
    uint64_t before=find(path,NULL,0);if(!before)return -1;
    int fd=open(path,O_RDWR|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return -1;
    struct stat st;struct termios config;
    if(fstat(fd,&st)||!S_ISCHR(st.st_mode)||flock(fd,LOCK_EX|LOCK_NB)||ioctl(fd,TIOCEXCL)||tcgetattr(fd,&config))goto fail;
    cfmakeraw(&config);config.c_cflag|=CLOCAL|CREAD;config.c_cflag&=~(CCTS_OFLOW|CRTS_IFLOW);
    config.c_cc[VMIN]=0;config.c_cc[VTIME]=0;
    if(tcsetattr(fd,TCSANOW,&config)||find(path,NULL,0)!=before)goto fail;
    return fd;
fail:close(fd);return -1;
}
