//! USB1 file-cell demultiplexer. Called only by the existing USB polling owner.
//! Never changes mouse/key/touch state or borrows the bridge's Bulk queue.
use core::cell::UnsafeCell;
use wiredkvm_cable_image::{Memory, Upload, CELL};

extern "C" {
    fn wk_cable_platform_ready() -> i32;
    fn wk_cable_platform_write(offset: u32, data: *const u8, n: usize) -> i32;
    fn wk_cable_forward(data: *const u8, n: usize);
}
struct Ram;
impl Memory for Ram {
    fn available(&self) -> bool { unsafe { wk_cable_platform_ready() != 0 } }
    fn write_verified(&mut self, offset: u32, data: &[u8]) -> bool {
        unsafe { wk_cable_platform_write(offset, data.as_ptr(), data.len()) != 0 }
    }
}
struct State { upload: Upload, cell: [u8; CELL], used: usize, ack: [u8; CELL], pending: bool, published: u32 }
struct Owner(UnsafeCell<State>);
// Same polling owner contract as the existing C USB adapter; never called from
// a hardware IRQ or another thread. All USB callbacks run in that polling pass.
unsafe impl Sync for Owner {}
static STATE: Owner = Owner(UnsafeCell::new(State { upload: Upload::new(), cell: [0; CELL], used: 0,
    ack: [0; CELL], pending: false, published: 0 }));

#[no_mangle]
pub extern "C" fn wk_cable_setup_reset() {
    let s = unsafe { &mut *STATE.0.get() }; s.upload.disconnected(); s.used = 0; s.pending = false;
}
#[no_mangle]
pub extern "C" fn wk_cable_setup_peer_reset() {
    let s = unsafe { &mut *STATE.0.get() };
    // Target reconnect invalidates partial forwarded file cells, but must not
    // interrupt the host's independent startup image upload.
    if s.upload.published_bytes().is_some() { s.used = 0; }
}
#[no_mangle]
pub extern "C" fn wk_cable_setup_size() -> u32 { unsafe { &*STATE.0.get() }.upload.published_bytes().unwrap_or(0) }
#[no_mangle]
pub extern "C" fn wk_cable_setup_changed() -> u32 {
    let s = unsafe { &mut *STATE.0.get() }; let n = s.published; s.published = 0; n
}
#[no_mangle]
pub extern "C" fn wk_cable_setup_pending() -> i32 { unsafe { &*STATE.0.get() }.pending as i32 }
#[no_mangle]
pub unsafe extern "C" fn wk_cable_setup_input(data: *const u8, n: usize) {
    if data.is_null() || n > CELL { return; }
    let s = &mut *STATE.0.get(); if s.pending { return; }
    let mut bytes = core::slice::from_raw_parts(data, n);
    while !bytes.is_empty() {
        let count = core::cmp::min(CELL-s.used, bytes.len());
        s.cell[s.used..s.used+count].copy_from_slice(&bytes[..count]);s.used+=count;bytes=&bytes[count..];
        if s.used == CELL {
            if &s.cell[..4] == b"WKIM" {
                let before = s.upload.published_bytes(); let reply = s.upload.accept(0, &s.cell, &mut Ram);
                if before.is_none() { s.published = s.upload.published_bytes().unwrap_or(0); }
                s.ack = reply.encode(); s.pending = true;
            } else { wk_cable_forward(s.cell.as_ptr(), CELL); }
            s.used = 0;
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn wk_cable_setup_ack(out: *mut u8, capacity: usize) -> usize {
    let s = &mut *STATE.0.get(); if !s.pending || out.is_null() || capacity < CELL { return 0; }
    core::ptr::copy_nonoverlapping(s.ack.as_ptr(), out, CELL); CELL
}
#[no_mangle]
pub extern "C" fn wk_cable_setup_ack_submitted() { unsafe { &mut *STATE.0.get() }.pending = false; }
