//! Opt-in, freestanding C boundary for the isolated stage-1 profile.
//! Only enum/handshake/one zero-contact report; no scrolling capability.

use crate::{fixture, Encoder, Error, FeatureMachine};
use core::sync::atomic::{AtomicU32, Ordering};

const ENABLED: u32 = 1 << 24;
const IDLE_PENDING: u32 = 1 << 25;
const E_ARGUMENT: i32 = -1;
const E_CAPACITY: i32 = -2;
const E_UNSUPPORTED: i32 = -3;
const E_PAYLOAD: i32 = -4;

/// Independently instantiable state for offline tests. No unsafe globals,
/// lock, allocation, IRQ masking, timer, I/O, or background work.
pub struct FfiCore {
    // selected[7:0], config99[23:8], enabled[24], zero-frame-pending[25].
    state: AtomicU32,
    timestamp: AtomicU32,
}

impl Default for FfiCore {
    fn default() -> Self {
        Self::new()
    }
}

impl FfiCore {
    pub const fn new() -> Self {
        Self {
            state: AtomicU32::new(0x99),
            timestamp: AtomicU32::new(0),
        }
    }

    pub fn reset(&self) {
        self.state.store(0x99, Ordering::Release);
        self.timestamp.store(0, Ordering::Release);
    }

    pub fn enabled(&self) -> bool {
        self.state.load(Ordering::Acquire) & ENABLED != 0
    }

    fn machine(&self) -> FeatureMachine<'static> {
        let state = self.state.load(Ordering::Acquire);
        FeatureMachine {
            property_capture: &fixture::PROPERTY_DB,
            selected: state as u8,
            config_99: [(state >> 8) as u8, (state >> 16) as u8],
            enabled: state & ENABLED != 0,
        }
    }

    pub fn get(&self, report_id: u8, dst: &mut [u8]) -> Result<usize, Error> {
        let report = self.machine().get(report_id, dst.len())?;
        let bytes = report.as_bytes();
        dst[..bytes.len()].copy_from_slice(bytes);
        Ok(bytes.len())
    }

    /// The caller has already removed any report-ID prefix. Strict payloads
    /// are identical to the offline FeatureMachine; unknown requests fail.
    pub fn set(&self, report_id: u8, payload: &[u8]) -> Result<(), Error> {
        let mut candidate = self.machine();
        candidate.set_payload(report_id, payload)?;
        let (mask, value) = match report_id {
            0x01 => (0xff, u32::from(candidate.selected)),
            0x02 => (
                ENABLED | IDLE_PENDING,
                if candidate.enabled {
                    ENABLED | IDLE_PENDING
                } else {
                    0
                },
            ),
            0x99 => (
                0xffff00,
                (u32::from(candidate.config_99[0]) << 8)
                    | (u32::from(candidate.config_99[1]) << 16),
            ),
            _ => return Err(Error::UnsupportedRequest),
        };
        // A single atomic word keeps GET snapshots coherent across EP0/main.
        let _ = self
            .state
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |old| {
                Some((old & !mask) | value)
            });
        Ok(())
    }

    pub fn input(&self, dst: &mut [u8]) -> Result<usize, i32> {
        let snapshot = self.state.load(Ordering::Acquire);
        if snapshot & (ENABLED | IDLE_PENDING) != ENABLED | IDLE_PENDING {
            return Ok(0);
        }
        if dst.len() < crate::HEADER_LEN {
            return Err(E_CAPACITY);
        }
        let old = self.state.fetch_and(!IDLE_PENDING, Ordering::AcqRel);
        if old & (ENABLED | IDLE_PENDING) != ENABLED | IDLE_PENDING {
            return Ok(0);
        }
        // No touch activity is possible in this stage, even if reset races.
        let timestamp = self.timestamp.fetch_add(32, Ordering::Relaxed) as u16;
        let mut encoder = Encoder::new(timestamp, 32);
        let report = encoder.frame(&[], true).map_err(|_| E_PAYLOAD)?;
        dst[..report.as_bytes().len()].copy_from_slice(report.as_bytes());
        Ok(report.as_bytes().len())
    }
}

static CORE: FfiCore = FfiCore::new();

fn error(error: Error) -> i32 {
    match error {
        Error::UnsupportedRequest => E_UNSUPPORTED,
        _ => E_PAYLOAD,
    }
}

// The C caller owns these buffers for the duration of each call. Zero-length
// calls accept null; nonzero lengths require a valid, aligned byte buffer.
unsafe fn output<'a>(ptr: *mut u8, length: usize) -> Result<&'a mut [u8], i32> {
    if length == 0 {
        return Ok(&mut []);
    }
    if ptr.is_null() {
        return Err(E_ARGUMENT);
    }
    Ok(unsafe { core::slice::from_raw_parts_mut(ptr, length) })
}

#[no_mangle]
pub extern "C" fn wkmt2_reset() {
    CORE.reset();
}

#[no_mangle]
pub extern "C" fn wkmt2_enabled() -> i32 {
    i32::from(CORE.enabled())
}

/// # Safety
/// dst must denote at least capacity writable bytes unless capacity is zero.
#[no_mangle]
pub unsafe extern "C" fn wkmt2_report_descriptor(dst: *mut u8, capacity: usize) -> i32 {
    if capacity < fixture::REPORT_DESCRIPTOR.len() {
        return E_CAPACITY;
    }
    let dst = match unsafe { output(dst, fixture::REPORT_DESCRIPTOR.len()) } {
        Ok(dst) => dst,
        Err(e) => return e,
    };
    dst.copy_from_slice(&fixture::REPORT_DESCRIPTOR);
    dst.len() as i32
}

/// # Safety
/// dst must denote at least min(capacity,256) writable bytes, or null for zero.
#[no_mangle]
pub unsafe extern "C" fn wkmt2_feature_get(report_id: u8, dst: *mut u8, capacity: usize) -> i32 {
    let dst = match unsafe { output(dst, capacity.min(256)) } {
        Ok(dst) => dst,
        Err(e) => return e,
    };
    match CORE.get(report_id, dst) {
        Ok(n) => n as i32,
        Err(e) => error(e),
    }
}

/// # Safety
/// payload must denote length readable bytes, or null for zero. Report ID is
/// already excluded by the C USB adapter. At most two payload bytes are valid.
#[no_mangle]
pub unsafe extern "C" fn wkmt2_feature_set(
    report_id: u8,
    payload: *const u8,
    length: usize,
) -> i32 {
    if length > 2 {
        return E_PAYLOAD;
    }
    let bytes = if length == 0 {
        &[][..]
    } else {
        if payload.is_null() {
            return E_ARGUMENT;
        }
        unsafe { core::slice::from_raw_parts(payload, length) }
    };
    match CORE.set(report_id, bytes) {
        Ok(()) => 0,
        Err(e) => error(e),
    }
}

/// # Safety
/// dst must denote min(capacity,64) writable bytes, or null for zero.
#[no_mangle]
pub unsafe extern "C" fn wkmt2_input(dst: *mut u8, capacity: usize) -> i32 {
    let dst = match unsafe { output(dst, capacity.min(crate::INPUT_CAPACITY)) } {
        Ok(dst) => dst,
        Err(e) => return e,
    };
    match CORE.input(dst) {
        Ok(n) => n as i32,
        Err(e) => e,
    }
}

// USB callbacks and service share one polling owner in this SDK. The guard also
// rejects unexpected reentry instead of spinning inside input/USB callbacks.
struct LiveStore {
    held: core::sync::atomic::AtomicBool,
    value: core::cell::UnsafeCell<crate::live::LiveCore>,
}
unsafe impl Sync for LiveStore {}
static LIVE: LiveStore = LiveStore {
    held: core::sync::atomic::AtomicBool::new(false),
    value: core::cell::UnsafeCell::new(crate::live::LiveCore::new()),
};
fn with_live(f: impl FnOnce(&mut crate::live::LiveCore) -> i32) -> i32 {
    if LIVE
        .held
        .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
        .is_err()
    {
        return -5;
    }
    let result = f(unsafe { &mut *LIVE.value.get() });
    LIVE.held.store(false, Ordering::Release);
    result
}
#[no_mangle]
pub extern "C" fn wkmt2_live_reset() {
    with_live(|s| {
        s.reset();
        0
    });
}
#[no_mangle]
pub extern "C" fn wkmt2_live_begin(epoch: u32, now: u32) -> i32 {
    with_live(|s| i32::from(s.begin(epoch, now)))
}
#[no_mangle]
pub extern "C" fn wkmt2_live_end(epoch: u32) {
    with_live(|s| {
        s.cancel(epoch);
        0
    });
}
#[no_mangle]
pub extern "C" fn wkmt2_live_tick(now: u32, enabled: i32) {
    with_live(|s| {
        s.tick(now, enabled != 0);
        0
    });
}
#[no_mangle]
pub extern "C" fn wkmt2_live_abort_pending() -> i32 {
    with_live(|s| i32::from(s.needs_abort()))
}
#[no_mangle]
pub extern "C" fn wkmt2_live_aborted() {
    with_live(|s| {
        s.aborted();
        0
    });
}
#[no_mangle]
pub extern "C" fn wkmt2_live_submitted() {
    with_live(|s| {
        s.submitted();
        0
    });
}
#[no_mangle]
pub extern "C" fn wkmt2_live_done() {
    with_live(|s| {
        s.complete();
        0
    });
}
/// # Safety
/// raw points to length initialized bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn wkmt2_live_offer(
    epoch: u32,
    raw: *const u8,
    length: usize,
    now: u32,
) -> i32 {
    if raw.is_null() || length > 57 {
        return E_PAYLOAD;
    }
    let bytes = unsafe { core::slice::from_raw_parts(raw, length) };
    with_live(|s| i32::from(s.offer(epoch, bytes, now)))
}
/// # Safety
/// dst points to capacity writable bytes. Copy only; submitted commits ownership.
#[no_mangle]
pub unsafe extern "C" fn wkmt2_live_input(dst: *mut u8, capacity: usize) -> i32 {
    let dst = match unsafe { output(dst, capacity.min(crate::INPUT_CAPACITY)) } {
        Ok(d) => d,
        Err(e) => return e,
    };
    with_live(|s| {
        let Some(p) = s.peek() else {
            return 0;
        };
        if dst.len() < p.len {
            return E_CAPACITY;
        }
        dst[..p.len].copy_from_slice(&p.bytes[..p.len]);
        p.len as i32
    })
}

#[no_mangle]
pub extern "C" fn wkmt2_live_faults() -> i32 {
    with_live(|s| s.faults() as i32)
}
