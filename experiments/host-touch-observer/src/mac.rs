use super::{Duration, Mode};
use std::ffi::{c_char, c_int, c_void, CStr};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    Mutex, OnceLock,
};
use std::time::Instant;
use wk_host_touch_observer::{decode, eligible_builtin, Stats, MAX_CONTACTS, RECORD_BYTES};

type DeviceRef = *const c_void;
type Callback = extern "C" fn(DeviceRef, *const u8, usize, f64, usize) -> c_int;
type Create = unsafe extern "C" fn() -> *const c_void;
type BuiltIn = unsafe extern "C" fn(DeviceRef) -> u8;
type GetService = unsafe extern "C" fn(DeviceRef) -> u32;
type Register = unsafe extern "C" fn(DeviceRef, Callback);
type Start = unsafe extern "C" fn(DeviceRef, c_int) -> c_int;
type Stop = unsafe extern "C" fn(DeviceRef) -> c_int;
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> DeviceRef;
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringCreateWithCString(
        allocator: *const c_void,
        s: *const c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFStringGetCString(
        s: *const c_void,
        buffer: *mut c_char,
        size: isize,
        encoding: u32,
    ) -> bool;
    fn CFRunLoopRunInMode(mode: *const c_void, seconds: f64, return_after: bool) -> i32;
    static kCFRunLoopDefaultMode: *const c_void;
}
#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IORegistryEntryGetRegistryEntryID(service: u32, id: *mut u64) -> i32;
    fn IORegistryEntryGetParentEntry(service: u32, plane: *const c_char, parent: *mut u32) -> i32;
    fn IOObjectConformsTo(service: u32, class: *const c_char) -> u32;
    fn IOObjectRetain(service: u32) -> i32;
    fn IOObjectRelease(service: u32) -> i32;
    fn CFNumberGetValue(value: *const c_void, kind: i32, out: *mut i64) -> bool;
    fn CFNumberGetTypeID() -> usize;
    fn IORegistryEntryGetName(service: u32, name: *mut c_char) -> i32;
    fn IORegistryEntryCreateCFProperty(
        service: u32,
        key: *const c_void,
        allocator: *const c_void,
        options: u32,
    ) -> *const c_void;
}
extern "C" {
    fn dlopen(path: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    fn signal(number: c_int, handler: extern "C" fn(c_int)) -> usize;
}
struct Library {
    handle: *mut c_void,
    create: Create,
    built_in: BuiltIn,
    running: BuiltIn,
    service: GetService,
    register: Register,
    unregister: Register,
    start: Start,
    stop: Stop,
}
impl Library {
    unsafe fn symbol<T: Copy>(handle: *mut c_void, name: &[u8]) -> Result<T, String> {
        let p = dlsym(handle, name.as_ptr().cast());
        if p.is_null() || std::mem::size_of::<T>() != std::mem::size_of_val(&p) {
            return Err(format!(
                "Unavailable private symbol: {}",
                String::from_utf8_lossy(&name[..name.len() - 1])
            ));
        }
        Ok(std::mem::transmute_copy(&p))
    }
    unsafe fn load() -> Result<Self, String> {
        let handle = dlopen(
            b"/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport\0"
                .as_ptr()
                .cast(),
            2,
        );
        if handle.is_null() {
            return Err("MultitouchSupport unavailable".into());
        }
        // Retain the framework until process exit; late framework callbacks
        // must never point into an unloaded image during teardown.
        Ok(Self {
            handle,
            create: Self::symbol(handle, b"MTDeviceCreateList\0")?,
            built_in: Self::symbol(handle, b"MTDeviceIsBuiltIn\0")?,
            running: Self::symbol(handle, b"MTDeviceIsRunning\0")?,
            service: Self::symbol(handle, b"MTDeviceGetService\0")?,
            register: Self::symbol(handle, b"MTRegisterContactFrameCallback\0")?,
            unregister: Self::symbol(handle, b"MTUnregisterContactFrameCallback\0")?,
            start: Self::symbol(handle, b"MTDeviceStart\0")?,
            stop: Self::symbol(handle, b"MTDeviceStop\0")?,
        })
    }
}
unsafe fn string_property(service: u32, key: &[u8]) -> String {
    let key = CFStringCreateWithCString(std::ptr::null(), key.as_ptr().cast(), 0x08000100);
    if key.is_null() {
        return String::new();
    }
    let value = IORegistryEntryCreateCFProperty(service, key, std::ptr::null(), 0);
    CFRelease(key);
    if value.is_null() {
        return String::new();
    }
    let mut text = [0i8; 512];
    let valid = CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringGetCString(value, text.as_mut_ptr(), text.len() as isize, 0x08000100);
    CFRelease(value);
    if valid {
        CStr::from_ptr(text.as_ptr()).to_string_lossy().into_owned()
    } else {
        String::new()
    }
}
struct Device {
    value: DeviceRef,
    id: u64,
    name: String,
    product: String,
    transport: String,
    built_in: bool,
    usb_target: bool,
}
impl Device {
    fn eligible(&self) -> bool {
        eligible_builtin(self.built_in, self.id, &self.product, &self.transport)
    }
}
struct Devices {
    array: *const c_void,
    items: Vec<Device>,
}
impl Drop for Devices {
    fn drop(&mut self) {
        unsafe { CFRelease(self.array) }
    }
}
unsafe fn devices(lib: &Library) -> Result<Devices, String> {
    let array = (lib.create)();
    if array.is_null() {
        return Err("No multitouch device list".into());
    }
    let n = CFArrayGetCount(array);
    if !(0..=32).contains(&n) {
        CFRelease(array);
        return Err("Unexpected multitouch device count".into());
    }
    let mut out = Devices {
        array,
        items: Vec::new(),
    };
    for i in 0..n {
        let value = CFArrayGetValueAtIndex(array, i);
        if value.is_null() {
            continue;
        }
        let service = (lib.service)(value);
        let mut id = 0;
        let mut name = [0i8; 128];
        if service == 0
            || IORegistryEntryGetRegistryEntryID(service, &mut id) != 0
            || IORegistryEntryGetName(service, name.as_mut_ptr()) != 0
        {
            continue;
        }
        name[127] = 0;
        out.items.push(Device {
            value,
            id,
            name: CStr::from_ptr(name.as_ptr()).to_string_lossy().into_owned(),
            product: string_property(service, b"Product\0"),
            transport: string_property(service, b"Transport\0"),
            built_in: (lib.built_in)(value) != 0,
            usb_target: usb_target(service),
        });
    }
    Ok(out)
}
unsafe fn number_property(service: u32, key: &[u8]) -> i64 {
    let name = CFStringCreateWithCString(std::ptr::null(), key.as_ptr().cast(), 0x08000100);
    if name.is_null() {
        return -1;
    }
    let value = IORegistryEntryCreateCFProperty(service, name, std::ptr::null(), 0);
    CFRelease(name);
    if value.is_null() {
        return -1;
    }
    let mut out = -1;
    if CFGetTypeID(value) == CFNumberGetTypeID() {
        CFNumberGetValue(value, 4, &mut out);
    }
    CFRelease(value);
    out
}
unsafe fn usb_target(service: u32) -> bool {
    if IOObjectRetain(service) != 0 {
        return false;
    }
    let mut node = service;
    for _ in 0..12 {
        if IOObjectConformsTo(node, b"IOUSBHostDevice\0".as_ptr().cast()) != 0 {
            let matched = number_property(node, b"idVendor\0") == 0x05ac
                && number_property(node, b"idProduct\0") == 0x0265
                && string_property(node, b"USB Serial Number\0") == "CH32V407-DoNotShip";
            IOObjectRelease(node);
            return matched;
        }
        let mut parent = 0;
        let result =
            IORegistryEntryGetParentEntry(node, b"IOService\0".as_ptr().cast(), &mut parent);
        IOObjectRelease(node);
        if result != 0 {
            return false;
        }
        node = parent;
    }
    IOObjectRelease(node);
    false
}
fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
struct Observed {
    stats: Stats,
    invalid: u64,
}
static OBSERVED: OnceLock<Mutex<Observed>> = OnceLock::new();
static SELECTED: AtomicUsize = AtomicUsize::new(0);
static DROPPED: AtomicU64 = AtomicU64::new(0);
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn interrupted(_: c_int) {
    STOP.store(true, Ordering::Relaxed);
}
extern "C" fn contact_frame(
    device: DeviceRef,
    bytes: *const u8,
    count: usize,
    time: f64,
    frame: usize,
) -> c_int {
    if SELECTED.load(Ordering::Acquire) != device as usize || device.is_null() {
        return 0;
    }
    if let Some(sender) = STREAM.get() {
        if count > MAX_CONTACTS || (count != 0 && bytes.is_null()) {
            STREAM_FAULT.store(true, Ordering::Release);
            return 0;
        }
        let records = if count == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(bytes, count * RECORD_BYTES) }
        };
        match decode(records, count, time, frame) {
            Ok(f) => {
                if sender.try_send(f).is_err() {
                    STREAM_FAULT.store(true, Ordering::Release);
                }
            }
            Err(_) => STREAM_FAULT.store(true, Ordering::Release),
        }
        return 0;
    }
    let Some(store) = OBSERVED.get() else {
        return 0;
    };
    let Ok(mut data) = store.try_lock() else {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return 0;
    };
    if count > MAX_CONTACTS || (count != 0 && bytes.is_null()) {
        data.invalid += 1;
        return 0;
    }
    // Experimental 96-byte ABI, opt-in and OS-gated below. Never retain Apple's buffer.
    let records = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, count * RECORD_BYTES) }
    };
    match decode(records, count, time, frame) {
        Ok(f) => data.stats.note(&f),
        Err(_) => data.invalid += 1,
    }
    0
}
pub(super) fn run(mode: Mode) -> Result<String, String> {
    let lib = unsafe { Library::load()? };
    let list = unsafe { devices(&lib)? };
    let _keep_loaded = lib.handle;
    if mode == Mode::Inspect {
        let entries=list.items.iter().map(|d|format!("{{\"registry_id\":{},\"name\":{},\"product\":{},\"transport\":{},\"built_in\":{},\"eligible\":{},\"usb_target\":{}}}",d.id,quote(&d.name),quote(&d.product),quote(&d.transport),d.built_in,d.eligible(),d.usb_target)).collect::<Vec<_>>().join(",");
        return Ok(format!("{{\"mode\":\"inspect\",\"callbacks_started\":false,\"input_injected\":false,\"devices\":[{entries}]}}"));
    }
    let seconds = match mode {
        Mode::Observe(s) => s,
        Mode::Stream => 0,
        Mode::ObserveUsbTarget(seconds, _) => seconds,
        _ => return Err("Invalid mode".into()),
    };
    let stream = mode == Mode::Stream;
    let receiver = if stream {
        let (tx, rx) = std::sync::mpsc::sync_channel(128);
        STREAM.set(tx).map_err(|_| "Stream already started")?;
        Some(rx)
    } else {
        None
    };
    let os = std::process::Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .map_err(|e| e.to_string())?;
    if !os.status.success() || os.stdout != b"15.6.1\n" {
        return Err(
            "Experimental raw ABI is restricted to macOS 15.6.1; no capture started".into(),
        );
    }
    let target_id = if let Mode::ObserveUsbTarget(_, id) = mode {
        Some(id)
    } else {
        None
    };
    let eligible = list
        .items
        .iter()
        .filter(|d| {
            if let Some(id) = target_id {
                d.id == id && d.usb_target && !d.built_in
            } else {
                d.eligible()
            }
        })
        .collect::<Vec<_>>();
    if eligible.len() != 1 {
        return Err(
            "Need exactly one verified device for this observation mode; no capture started".into(),
        );
    }
    let device = eligible[0];
    if unsafe { (lib.running)(device.value) } != 0 {
        return Err("This device handle is already running; no capture started".into());
    }
    OBSERVED.get_or_init(|| {
        Mutex::new(Observed {
            stats: Stats::default(),
            invalid: 0,
        })
    });
    SELECTED.store(device.value as usize, Ordering::Release);
    unsafe {
        signal(2, interrupted);
        signal(15, interrupted);
        (lib.register)(device.value, contact_frame);
    }
    let started = unsafe { (lib.start)(device.value, 0) };
    if started != 0 {
        SELECTED.store(0, Ordering::Release);
        unsafe {
            if (lib.running)(device.value) != 0 {
                (lib.stop)(device.value);
            }
            (lib.unregister)(device.value, contact_frame);
        }
        if unsafe { (lib.running)(device.value) } != 0 {
            std::mem::forget(list);
        }
        return Err(format!("MTDeviceStart failed: {started}"));
    }
    if let Mode::ObserveUsbTarget(_, id) = mode {
        eprintln!("USB_TARGET_OBSERVER_READY {}", id);
    }
    let until = Instant::now() + Duration::from_secs(seconds);
    let stream_result = if let Some(rx) = receiver {
        stream_loop(rx, || unsafe { (lib.running)(device.value) != 0 })
    } else {
        while Instant::now() < until && !STOP.load(Ordering::Relaxed) {
            unsafe {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
        }
        Ok(())
    };
    SELECTED.store(0, Ordering::Release);
    let stopped = unsafe { (lib.stop)(device.value) };
    unsafe {
        (lib.unregister)(device.value, contact_frame);
    }
    if stopped != 0 || unsafe { (lib.running)(device.value) } != 0 {
        std::mem::forget(list);
        return Err(format!(
            "MTDeviceStop failed: {stopped}; retained device until process exit"
        ));
    }
    stream_result?;
    if stream {
        return Ok("H STOPPED".into());
    }
    let data = OBSERVED
        .get()
        .unwrap()
        .lock()
        .map_err(|_| "Observation lock poisoned")?;
    Ok(format!("{{\"mode\":\"observe\",\"registry_id\":{},\"seconds\":{},\"frames\":{},\"invalid_frames\":{},\"dropped_callbacks\":{},\"moving_frames\":{},\"max_touching\":{},\"four_touch_frames\":{},\"four_record_frames\":{},\"state_counts\":{:?},\"timestamp_regressions\":{},\"max_gap_seconds\":{},\"input_injected\":false,\"target_access\":false,\"capture_stopped\":true}}",
        device.id,seconds,data.stats.frames,data.invalid,DROPPED.load(Ordering::Relaxed),data.stats.moving_frames,data.stats.max_touching,data.stats.four_touch_frames,data.stats.four_record_frames,data.stats.state_counts,data.stats.timestamp_regressions,data.stats.max_gap_seconds))
}

static STREAM: OnceLock<std::sync::mpsc::SyncSender<wk_host_touch_observer::Frame>> =
    OnceLock::new();
static STREAM_FAULT: AtomicBool = AtomicBool::new(false);
fn stream_loop(
    rx: std::sync::mpsc::Receiver<wk_host_touch_observer::Frame>,
    running: impl Fn() -> bool,
) -> Result<(), String> {
    use std::io::{Read, Write};
    extern "C" {
        fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    }
    // macOS O_NONBLOCK. Only this process's inherited control pipe is changed.
    let flags = unsafe { fcntl(0, 3) };
    if flags < 0 || unsafe { fcntl(0, 4, flags | 4) } < 0 {
        return Err("Cannot make control pipe nonblocking".into());
    }
    let mut mapper = wk_host_touch_observer::forward::Mapper::default();
    let mut pending = String::new();
    let mut last = None;
    let mut last_sent = Instant::now();
    let mut out = std::io::stdout();
    writeln!(out, "H READY").map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())?;
    let emit = |rows: Vec<String>, out: &mut std::io::Stdout| -> Result<(), String> {
        for row in rows {
            writeln!(out, "{row}").map_err(|e| e.to_string())?;
        }
        out.flush().map_err(|e| e.to_string())
    };
    let result = (|| {
        while !STOP.load(Ordering::Relaxed) {
            unsafe {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
            }
            let mut b = [0u8; 512];
            match std::io::stdin().read(&mut b) {
                Ok(0) => break,
                Ok(n) => {
                    pending.push_str(
                        std::str::from_utf8(&b[..n]).map_err(|_| "Bad control encoding")?,
                    );
                    if pending.len() > 1024 {
                        return Err("Control overflow".into());
                    }
                    while let Some(i) = pending.find('\n') {
                        let command = pending[..i].to_string();
                        pending.drain(..=i);
                        emit(mapper.disable(), &mut out)?;
                        last = None;
                        if let Some(epoch) = command
                            .strip_prefix("ON ")
                            .and_then(|s| s.parse::<u32>().ok())
                            .filter(|n| *n != 0)
                        {
                            // Drain pre-handoff frames; never replay a Book gesture.
                            while rx.try_recv().is_ok() {}
                            mapper.enable(epoch);
                            writeln!(out, "H B {epoch}").map_err(|e| e.to_string())?;
                        } else if command != "OFF" {
                            return Err("Invalid stream command".into());
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
                Err(e) => return Err(e.to_string()),
            }
            if STREAM_FAULT.swap(false, Ordering::AcqRel) {
                emit(mapper.disable(), &mut out)?;
                while rx.try_recv().is_ok() {}
                last = None;
                writeln!(out, "H FAULT").map_err(|e| e.to_string())?;
            }
            // Bounded drain. Queue overflow triggers explicit release, never a
            // silently lost terminal callback. No I/O happens in Apple's callback.
            for _ in 0..128 {
                match rx.try_recv() {
                    Ok(f) => {
                        emit(mapper.sample(&f), &mut out)?;
                        last = Some(f);
                        last_sent = Instant::now();
                    }
                    Err(_) => break,
                }
            }
            // The API need not callback while fingers rest. Keep that snapshot
            // leased; callback silence alone is not evidence of a lost device.
            // Queue overflow, framework stop, EOF and parent handoff revoke it.
            if !running() {
                return Err("Raw trackpad handle stopped".into());
            }
            if last_sent.elapsed() >= Duration::from_millis(16) {
                if let Some(f) = last.as_ref() {
                    emit(mapper.sample(f), &mut out)?;
                }
                last_sent = Instant::now();
            }
        }
        Ok(())
    })();
    let _ = emit(mapper.disable(), &mut out);
    let _ = unsafe { fcntl(0, 4, flags) };
    result
}
