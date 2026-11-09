// ABI-only shim. Policy, lifecycle and retry decisions live in Rust.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/file.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>

typedef struct { uint64_t entry; uint32_t location; char port[256]; } WKDevice;
static CFTypeRef property(io_registry_entry_t e, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(e, kIOServicePlane, key, kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
}
static int64_t number(io_registry_entry_t e, CFStringRef key) {
    CFTypeRef p = property(e, key); int64_t v = -1;
    if (p && CFGetTypeID(p) == CFNumberGetTypeID()) CFNumberGetValue(p, kCFNumberSInt64Type, &v);
    if (p) CFRelease(p);
    return v;
}
static int string(io_registry_entry_t e, CFStringRef key, char *buf, size_t n) {
    CFTypeRef p = property(e, key);
    int ok = p && CFGetTypeID(p) == CFStringGetTypeID() && CFStringGetCString(p, buf, n, kCFStringEncodingUTF8);
    if (p) CFRelease(p);
    return ok;
}
int wk_devices(WKDevice *out, int capacity) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it)) return -1;
    int count = 0; io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        char serial[128], name[128], port[256];
        int64_t iface = number(e, CFSTR("bInterfaceNumber"));
        if (number(e, CFSTR("idVendor")) == 0x1a86 && number(e, CFSTR("idProduct")) == 0x4070 &&
            (iface == 0 || iface == 1) &&
            string(e, CFSTR("USB Serial Number"), serial, sizeof(serial)) && !strcmp(serial, "CH32V407-DoNotShip") &&
            string(e, CFSTR("USB Product Name"), name, sizeof(name)) && !strcmp(name, "WiredKVM Petros V467 Host") &&
            string(e, CFSTR(kIOCalloutDeviceKey), port, sizeof(port)) && !strncmp(port, "/dev/cu.", 8)) {
            if (count < capacity) {
                memset(&out[count], 0, sizeof(out[count]));
                IORegistryEntryGetRegistryEntryID(e, &out[count].entry);
                out[count].location = (uint32_t)number(e, CFSTR("locationID"));
                strlcpy(out[count].port, port, sizeof(out[count].port));
            }
            count++;
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return count;
}
int wk_console_active(void) {
    uid_t uid = (uid_t)-1; gid_t gid;
    CFStringRef name = SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid);
    if (name) CFRelease(name);
    return uid == getuid();
}
int wk_process(int pid, char *path, int capacity, uint64_t *sec, uint64_t *usec, int *parent) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        info.pbi_uid != getuid() || info.pbi_status == SZOMB ||
        proc_pidpath(pid, path, capacity) <= 0) return 0;
    *sec = info.pbi_start_tvsec; *usec = info.pbi_start_tvusec; *parent = info.pbi_ppid;
    return 1;
}
int wk_lock(int fd) { return flock(fd, LOCK_EX | LOCK_NB); }
