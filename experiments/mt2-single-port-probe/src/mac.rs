//! macOS FFI is used only after explicit --execute. No event taps or clipboard.
use std::{
    ffi::{c_char, c_void, CString},
    ptr,
};
use wk_mt2_single_port_probe::*;
type Ref = *const c_void;
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(x: Ref);
    fn CFGetTypeID(x: Ref) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetLength(x: Ref) -> isize;
    fn CFStringGetMaximumSizeForEncoding(n: isize, e: u32) -> isize;
    fn CFStringGetCString(x: Ref, b: *mut c_char, n: isize, e: u32) -> bool;
    fn CFStringCreateWithCString(a: Ref, s: *const c_char, e: u32) -> Ref;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberGetValue(x: Ref, t: isize, v: *mut c_void) -> bool;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(x: Ref) -> bool;
    fn CFDataGetTypeID() -> usize;
    fn CFDataGetLength(x: Ref) -> isize;
    fn CFDataGetBytePtr(x: Ref) -> *const u8;
    fn CFDataCreate(a: Ref, p: *const u8, n: isize) -> Ref;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(x: Ref) -> isize;
    fn CFArrayGetValueAtIndex(x: Ref, i: isize) -> Ref;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetCount(x: Ref) -> isize;
    fn CFDictionaryGetKeysAndValues(x: Ref, k: *mut Ref, v: *mut Ref);
    fn CFPropertyListCreateWithData(a: Ref, d: Ref, o: usize, f: *mut isize, e: *mut Ref) -> Ref;
    fn CFSetGetCount(x: Ref) -> isize;
    fn CFSetGetValues(x: Ref, v: *mut Ref);
}
#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOHIDManagerCreate(a: Ref, options: u32) -> Ref;
    fn IOHIDManagerSetDeviceMatching(m: Ref, d: Ref);
    fn IOHIDManagerOpen(m: Ref, o: u32) -> i32;
    fn IOHIDManagerClose(m: Ref, o: u32) -> i32;
    fn IOHIDManagerCopyDevices(m: Ref) -> Ref;
    fn IOHIDDeviceGetProperty(d: Ref, k: Ref) -> Ref;
    fn IOHIDDeviceOpen(d: Ref, o: u32) -> i32;
    fn IOHIDDeviceClose(d: Ref, o: u32) -> i32;
    fn IOHIDDeviceSetReport(d: Ref, t: u32, id: isize, b: *const u8, n: isize) -> i32;
    fn IOHIDDeviceGetReport(d: Ref, t: u32, id: isize, b: *mut u8, n: *mut isize) -> i32;
}
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Size {
    w: f64,
    h: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Rect {
    p: Point,
    s: Size,
}
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGGetActiveDisplayList(max: u32, ids: *mut u32, n: *mut u32) -> i32;
    fn CGMainDisplayID() -> u32;
    fn CGDisplayIsBuiltin(d: u32) -> u32;
    fn CGDisplayBounds(d: u32) -> Rect;
    fn CGEventCreate(source: Ref) -> Ref;
    fn CGEventGetLocation(e: Ref) -> Point;
    fn CGWarpMouseCursorPosition(p: Point) -> i32;
    fn CGEventSourceButtonState(source: i32, button: u32) -> bool;
}
struct Owned(Ref);
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) }
        }
    }
}
fn string(s: &str) -> Owned {
    let s = CString::new(s).unwrap();
    Owned(unsafe { CFStringCreateWithCString(ptr::null(), s.as_ptr(), 0x08000100) })
}
unsafe fn value(x: Ref, depth: usize) -> Result<Value> {
    require(depth < 80, "Property nesting too deep")?;
    if x.is_null() {
        return Ok(Value::Null);
    }
    let t = CFGetTypeID(x);
    if t == CFStringGetTypeID() {
        let n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(x), 0x08000100) + 1;
        require(
            (1..=16 * 1024 * 1024).contains(&n),
            "Property string too long",
        )?;
        let mut b = vec![0u8; n as usize];
        require(
            CFStringGetCString(x, b.as_mut_ptr().cast(), n, 0x08000100),
            "Invalid property string",
        )?;
        b.truncate(b.iter().position(|c| *c == 0).unwrap_or(b.len()));
        return Ok(Value::Text(
            String::from_utf8(b).map_err(|_| "Invalid UTF8")?,
        ));
    }
    if t == CFBooleanGetTypeID() {
        return Ok(Value::Bool(CFBooleanGetValue(x)));
    }
    if t == CFNumberGetTypeID() {
        let mut n = 0i64;
        require(
            CFNumberGetValue(x, 4, (&mut n as *mut i64).cast()),
            "Unsupported numeric property",
        )?;
        return Ok(Value::Int(n));
    }
    if t == CFDataGetTypeID() {
        let n = CFDataGetLength(x);
        require(
            (0..=16 * 1024 * 1024).contains(&n),
            "Property data too long",
        )?;
        return Ok(Value::Bytes(if n == 0 {
            vec![]
        } else {
            std::slice::from_raw_parts(CFDataGetBytePtr(x), n as usize).to_vec()
        }));
    }
    if t == CFArrayGetTypeID() {
        let n = CFArrayGetCount(x);
        require((0..=100000).contains(&n), "Property array too long")?;
        let mut a = vec![];
        for i in 0..n {
            a.push(value(CFArrayGetValueAtIndex(x, i), depth + 1)?)
        }
        return Ok(Value::List(a));
    }
    if t == CFDictionaryGetTypeID() {
        let n = CFDictionaryGetCount(x);
        require((0..=100000).contains(&n), "Property dict too long")?;
        let mut keys = vec![ptr::null(); n as usize];
        let mut vals = keys.clone();
        CFDictionaryGetKeysAndValues(x, keys.as_mut_ptr(), vals.as_mut_ptr());
        let mut d = std::collections::BTreeMap::new();
        for (k, v) in keys.into_iter().zip(vals) {
            let k = value(k, depth + 1)?;
            let k = k.text().ok_or("Nonstring property key")?.to_owned();
            d.insert(k, value(v, depth + 1)?);
        }
        return Ok(Value::Dict(d));
    }
    Err("Unsupported plist object".into())
}
fn plist_ref(bytes: &[u8]) -> Result<Owned> {
    unsafe {
        let d = Owned(CFDataCreate(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
        ));
        let mut err = ptr::null();
        let p = CFPropertyListCreateWithData(ptr::null(), d.0, 0, ptr::null_mut(), &mut err);
        let _e = Owned(err);
        require(!p.is_null(), "Cannot parse property list")?;
        Ok(Owned(p))
    }
}
pub fn parse_plist(bytes: &[u8]) -> Result<Value> {
    let p = plist_ref(bytes)?;
    unsafe { value(p.0, 0) }
}
pub struct Hid {
    manager: Owned,
    devices: Owned,
    device: Ref,
    opened: bool,
}
impl Hid {
    pub fn open(identity: &Identity) -> Result<Self> {
        unsafe {
            let manager = Owned(IOHIDManagerCreate(ptr::null(), 0));
            require(!manager.0.is_null(), "Cannot create HID manager")?;
            let xml=format!("<plist version=\"1.0\"><dict><key>VendorID</key><integer>1452</integer><key>ProductID</key><integer>613</integer><key>PrimaryUsagePage</key><integer>65376</integer><key>PrimaryUsage</key><integer>97</integer><key>LocationID</key><integer>{}</integer></dict></plist>",identity.location);
            let matching = plist_ref(xml.as_bytes())?;
            IOHIDManagerSetDeviceMatching(manager.0, matching.0);
            require(
                IOHIDManagerOpen(manager.0, 0) == 0,
                "Cannot open vendor HID manager (non-exclusive)",
            )?;
            let devices = Owned(IOHIDManagerCopyDevices(manager.0));
            require(
                !devices.0.is_null() && CFSetGetCount(devices.0) == 1,
                "Need exactly one vendor HID device",
            )?;
            let mut device = ptr::null();
            CFSetGetValues(devices.0, &mut device);
            let mut h = Self {
                manager,
                devices,
                device,
                opened: false,
            };
            for (k, v) in [
                ("VendorID", Value::Int(1452)),
                ("ProductID", Value::Int(613)),
                ("PrimaryUsagePage", Value::Int(65376)),
                ("PrimaryUsage", Value::Int(97)),
                ("LocationID", Value::Int(identity.location as i64)),
                ("Manufacturer", Value::Text("WiredKVM Prototype".into())),
                ("SerialNumber", Value::Text(SERIAL.into())),
                ("ReportDescriptor", Value::Bytes(vendor_descriptor())),
            ] {
                require(
                    h.property(k)? == v,
                    "Vendor HID identity or descriptor changed",
                )?;
            }
            require(
                IOHIDDeviceOpen(h.device, 0) == 0,
                "Cannot open vendor HID without seizing",
            )?;
            h.opened = true;
            Ok(h)
        }
    }
    fn property(&self, key: &str) -> Result<Value> {
        let key = string(key);
        unsafe { value(IOHIDDeviceGetProperty(self.device, key.0), 0) }
    }
    pub fn set(&self, b: &[u8; 64]) -> Result<()> {
        unsafe {
            require(
                IOHIDDeviceSetReport(self.device, 2, 0, b.as_ptr(), 64) == 0,
                "Feature SET failed",
            )
        }
    }
    pub fn status(&self) -> Result<Status> {
        let mut b = [0u8; 64];
        let mut n = 64isize;
        unsafe {
            require(
                IOHIDDeviceGetReport(self.device, 2, 0, b.as_mut_ptr(), &mut n) == 0,
                "Feature GET failed",
            )?;
        }
        require(n == 64, "Short Feature status")?;
        Status::parse(&b)
    }
}
impl Drop for Hid {
    fn drop(&mut self) {
        unsafe {
            if self.opened {
                IOHIDDeviceClose(self.device, 0);
            }
            IOHIDManagerClose(self.manager.0, 0);
        }
        let _ = &self.devices;
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Layout {
    pub id: u32,
    pub width: f64,
    pub height: f64,
}
pub fn layout() -> Result<Layout> {
    unsafe {
        let mut ids = [0u32; 16];
        let mut n = 0;
        require(
            CGGetActiveDisplayList(16, ids.as_mut_ptr(), &mut n) == 0
                && n == 1
                && ids[0] == CGMainDisplayID()
                && CGDisplayIsBuiltin(ids[0]) != 0,
            "Only Book built-in display may be active",
        )?;
        let r = CGDisplayBounds(ids[0]);
        require(
            r.p.x == 0.
                && r.p.y == 0.
                && (640.0..=10000.0).contains(&r.s.w)
                && (400.0..=10000.0).contains(&r.s.h),
            "Unexpected screen bounds",
        )?;
        Ok(Layout {
            id: ids[0],
            width: r.s.w,
            height: r.s.h,
        })
    }
}
pub fn position() -> Result<Point> {
    unsafe {
        let e = Owned(CGEventCreate(ptr::null()));
        require(!e.0.is_null(), "Cannot read cursor")?;
        let p = CGEventGetLocation(e.0);
        require(p.x.is_finite() && p.y.is_finite(), "Invalid cursor")?;
        Ok(p)
    }
}
pub fn buttons_up() -> Result<()> {
    unsafe {
        require(
            !(0..32).any(|i| CGEventSourceButtonState(0, i)),
            "A pointer button is held",
        )
    }
}
pub struct Restore {
    pub before: Point,
    layout: Layout,
    armed: bool,
}
impl Restore {
    pub fn new() -> Result<Self> {
        Ok(Self {
            before: position()?,
            layout: layout()?,
            armed: true,
        })
    }
    pub fn restore(&mut self) -> Result<()> {
        if !self.armed {
            return Ok(());
        }
        require(
            layout()? == self.layout,
            "Display changed; cursor restoration was not injected",
        )?;
        buttons_up()?;
        unsafe {
            require(
                CGWarpMouseCursorPosition(self.before) == 0,
                "Cursor restore failed",
            )?;
        }
        let p = position()?;
        require(
            position_pass((self.before.x, self.before.y), (p.x, p.y)),
            "Cursor restore verification failed",
        )?;
        self.armed = false;
        Ok(())
    }
}
impl Drop for Restore {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.restore();
        }
    }
}
