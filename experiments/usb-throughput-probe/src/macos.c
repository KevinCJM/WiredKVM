/* ABI only. Opens exactly one verified FILE interface, never control/HID. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
static CFTypeRef property(io_registry_entry_t e,CFStringRef key){return IORegistryEntrySearchCFProperty(e,kIOServicePlane,key,kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);}
static int64_t number(io_registry_entry_t e,CFStringRef key){CFTypeRef v=property(e,key);int64_t n=-1;if(v&&CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberSInt64Type,&n);if(v)CFRelease(v);return n;}
static int text(io_registry_entry_t e,CFStringRef key,char *s,size_t n){CFTypeRef v=property(e,key);int ok=v&&CFGetTypeID(v)==CFStringGetTypeID()&&CFStringGetCString(v,s,n,kCFStringEncodingUTF8);if(v)CFRelease(v);return ok;}
static uint64_t find(unsigned role,const char *wanted,char *out,size_t n){
    io_iterator_t it=0;if(role>1||IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching(kIOSerialBSDServiceValue),&it))return 0;
    unsigned count=0;uint64_t found=0;io_registry_entry_t e;
    while((e=IOIteratorNext(it))){
        char serial[128],name[128],path[256];int64_t iface=number(e,CFSTR("bInterfaceNumber"));
        bool match=role?(number(e,CFSTR("idVendor"))==0x05ac&&number(e,CFSTR("idProduct"))==0x0265&&number(e,CFSTR("bcdDevice"))==0x026e&&(iface==3||iface==4)):
            (number(e,CFSTR("idVendor"))==0x1a86&&number(e,CFSTR("idProduct"))==0x4070&&(iface==2||iface==3)&&text(e,CFSTR("USB Product Name"),name,sizeof(name))&&!strcmp(name,"WiredKVM Petros V467 Host"));
        if(match&&text(e,CFSTR("USB Serial Number"),serial,sizeof(serial))&&!strcmp(serial,"CH32V407-DoNotShip")&&text(e,CFSTR(kIOCalloutDeviceKey),path,sizeof(path))&&!strncmp(path,"/dev/cu.",8)&&(!wanted||!strcmp(path,wanted))){
            count++;IORegistryEntryGetRegistryEntryID(e,&found);if(out)strlcpy(out,path,n);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);return count==1?found:0;
}
int wk_probe_open(unsigned role){
    char path[256];uint64_t before=find(role,NULL,path,sizeof(path));if(!before)return -1;
    int fd=open(path,O_RDWR|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return -1;
    struct stat st;struct termios config;
    if(fstat(fd,&st)||!S_ISCHR(st.st_mode)||flock(fd,LOCK_EX|LOCK_NB)||ioctl(fd,TIOCEXCL)||tcgetattr(fd,&config))goto fail;
    cfmakeraw(&config);config.c_cflag|=CLOCAL|CREAD;config.c_cflag&=~(CCTS_OFLOW|CRTS_IFLOW);config.c_cc[VMIN]=1;config.c_cc[VTIME]=0;
    /* Only this exclusively owned diagnostic file function is flushed. A
     * previous failed runner may leave raw test bytes in its TTY input queue;
     * this does not claim to reset a still-active firmware benchmark. */
    if(tcsetattr(fd,TCSANOW,&config)||tcflush(fd,TCIOFLUSH)||find(role,path,NULL,0)!=before)goto fail;
    return fd;
fail:close(fd);return -1;
}
int wk_probe_wait(int fd,int writing,int milliseconds){
    struct pollfd event={.fd=fd,.events=writing?POLLOUT:POLLIN,.revents=0};
    int result;do{result=poll(&event,1,milliseconds);}while(result<0&&errno==EINTR);
    if(result<=0)return result;
    if(event.revents&POLLNVAL){errno=EBADF;return -1;}
    /* Let read/write expose EOF or the precise endpoint error after HUP. */
    return 1;
}
