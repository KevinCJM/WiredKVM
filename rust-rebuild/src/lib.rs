//! Offline routing tests against the real recovered CH32 bridge C core.
//!
//! This is not a USB driver, clipboard client, or file integrity validator.
//! WKS5 test cells deliberately carry an invalid SHA field: the bridge routes
//! bytes while the real endpoint stream engine verifies SHA-256 separately.
//! No filesystem/device/clipboard APIs or destructor cleanup are present.
use std::{ffi::c_void, marker::PhantomData, ptr::NonNull, rc::Rc};

pub const CELL_BYTES: usize = 512;
pub const BODY_BYTES: usize = 432;
pub const BULK_SLOTS: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Port {
    Host = 0,
    Target = 1,
}
impl Port {
    pub fn peer(self) -> Self {
        match self {
            Self::Host => Self::Target,
            Self::Target => Self::Host,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ControlKind {
    Session = 1,
    Grant = 2,
    Cancel = 3,
    Accepted = 4,
    Cancelled = 5,
    Retired = 6,
    PasteCancel = 7,
    RetiredAck = 8,
}

/// Actual WKB5 layout from WKStreamFiles.swift, including its IEEE CRC-32.
pub struct BulkControl {
    pub kind: ControlKind,
    pub origin: Port,
    pub epoch: u64,
    pub id: [u8; 16],
    pub generation: u64,
}
impl BulkControl {
    pub fn encode(&self) -> [u8; 64] {
        let mut bytes = [0_u8; 64];
        bytes[..4].copy_from_slice(b"WKB5");
        bytes[4] = self.kind as u8;
        bytes[5] = self.origin as u8;
        bytes[8..16].copy_from_slice(&self.epoch.to_le_bytes());
        bytes[16..32].copy_from_slice(&self.id);
        bytes[32..40].copy_from_slice(&self.generation.to_le_bytes());
        let crc = crc32(&bytes[..60]);
        bytes[60..64].copy_from_slice(&crc.to_le_bytes());
        bytes
    }
}

pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for &byte in bytes {
        crc ^= byte as u32;
        for _ in 0..8 {
            crc = (crc >> 1) ^ if crc & 1 != 0 { 0xedb8_8320 } else { 0 };
        }
    }
    !crc
}

/// A routing-only WKS5 fixture. Never pass this to a production file receiver.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoutingCell(pub [u8; CELL_BYTES]);
impl RoutingCell {
    pub fn data(epoch: u64, id: [u8; 16], sequence: u64) -> Self {
        let mut bytes = [0_u8; CELL_BYTES];
        bytes[..4].copy_from_slice(b"WKS5");
        bytes[4..8].copy_from_slice(&(CELL_BYTES as u32).to_le_bytes());
        bytes[8] = 1;
        bytes[12..20].copy_from_slice(&epoch.to_le_bytes());
        bytes[20..36].copy_from_slice(&id);
        bytes[36..44].copy_from_slice(&(sequence * BODY_BYTES as u64).to_le_bytes());
        bytes[44..48].copy_from_slice(&(BODY_BYTES as u32).to_le_bytes());
        // Sentinel explicitly marks the unverified digest; this is not SHA-256.
        bytes[48..80].fill(0xa5);
        for (index, byte) in bytes[80..].iter_mut().enumerate() {
            *byte = (sequence as u8)
                .wrapping_add(index as u8)
                .wrapping_add(id[0]);
        }
        Self(bytes)
    }
}

extern "C" {
    fn wk407_sim_create() -> *mut c_void;
    fn wk407_sim_destroy(sim: *mut c_void);
    fn wk407_sim_write(sim: *mut c_void, source: u32, data: *const c_void, size: usize) -> usize;
    fn wk407_sim_read(sim: *mut c_void, destination: u32, data: *mut c_void, size: usize) -> usize;
    fn wk407_sim_connect(sim: *mut c_void, port: u32, online: i32, now: u32);
    fn wk407_sim_hid_probe(sim: *mut c_void, now: u32) -> u32;
    fn wk407_sim_peak(sim: *mut c_void) -> u32;
    fn wk407_sim_size() -> usize;
    fn wk407_sim_control(sim: *mut c_void, source: u32, report: *const c_void) -> i32;
}

/// Owns only a calloc-backed C object. Single-threaded like the firmware core.
/// Explicit close releases RAM only. No Drop implementation or path cleanup.
pub struct Simulator {
    raw: NonNull<c_void>,
    _single_thread: PhantomData<Rc<()>>,
}
impl Simulator {
    pub fn new() -> Result<Self, String> {
        // SAFETY: C factory has no arguments and returns owned simulator memory.
        let raw =
            NonNull::new(unsafe { wk407_sim_create() }).ok_or("simulator allocation failed")?;
        Ok(Self {
            raw,
            _single_thread: PhantomData,
        })
    }
    pub fn write(&mut self, source: Port, data: &[u8]) -> usize {
        // SAFETY: live owned simulator; enum bounds port; slice bounds C reads.
        unsafe {
            wk407_sim_write(
                self.raw.as_ptr(),
                source as u32,
                data.as_ptr().cast(),
                data.len(),
            )
        }
    }
    pub fn read(&mut self, destination: Port, output: &mut [u8]) -> usize {
        // SAFETY: mutable slice has output.len() writable bytes, port is bounded.
        unsafe {
            wk407_sim_read(
                self.raw.as_ptr(),
                destination as u32,
                output.as_mut_ptr().cast(),
                output.len(),
            )
        }
    }
    pub fn control(&mut self, source: Port, report: &BulkControl) -> bool {
        self.control_bytes(source, &report.encode())
    }
    pub fn control_bytes(&mut self, source: Port, bytes: &[u8; 64]) -> bool {
        // SAFETY: the C entry point reads exactly one 64-byte control report.
        unsafe { wk407_sim_control(self.raw.as_ptr(), source as u32, bytes.as_ptr().cast()) != 0 }
    }
    pub fn session(&mut self, epoch: u64) -> bool {
        [Port::Host, Port::Target].into_iter().all(|port| {
            self.control(
                port,
                &BulkControl {
                    kind: ControlKind::Session,
                    origin: port,
                    epoch,
                    id: [0; 16],
                    generation: 0,
                },
            )
        })
    }
    pub fn grant(&mut self, origin: Port, epoch: u64, id: [u8; 16], generation: u64) -> bool {
        self.control(
            origin.peer(),
            &BulkControl {
                kind: ControlKind::Grant,
                origin,
                epoch,
                id,
                generation,
            },
        )
    }
    pub fn connect(&mut self, port: Port, online: bool, now: u32) {
        // SAFETY: live simulator and bounded port; this resets memory state only.
        unsafe { wk407_sim_connect(self.raw.as_ptr(), port as u32, online.into(), now) }
    }
    /// Parses actual WK1 input and requires its ACK plus absolute-pointer HID.
    /// This measures logical service, not real keyboard or USB scheduling delay.
    pub fn hid_probe(&mut self, now: u32) -> bool {
        // SAFETY: live simulator; helper owns all temporary C buffers.
        unsafe { wk407_sim_hid_probe(self.raw.as_ptr(), now) != 0 }
    }
    pub fn bulk_peak(&mut self) -> u32 {
        // SAFETY: live simulator and a read-only scalar accessor.
        unsafe { wk407_sim_peak(self.raw.as_ptr()) }
    }
    pub fn core_bytes() -> usize {
        // SAFETY: C returns sizeof(wk407_bridge), no pointers or global mutation.
        unsafe { wk407_sim_size() }
    }
    pub fn close(self) {
        // SAFETY: consuming self makes the owned C allocation inaccessible.
        unsafe { wk407_sim_destroy(self.raw.as_ptr()) }
    }
}

#[derive(Debug)]
pub struct StressReport {
    pub hid_services: u32,
    pub routed_cells_per_direction: u32,
    pub routed_bytes: u64,
    pub bulk_high_water: u32,
    pub core_bytes: usize,
}

/// Saturates both real C Bulk queues while servicing a WK1/HID probe per step.
/// All bytes are synthetic and stay in RAM. No timing/USB/SHA claim is made.
pub fn run_routing_stress(iterations: u32) -> Result<StressReport, String> {
    let mut sim = Simulator::new()?;
    let result = (|| {
        let epoch = 0x1020_3040_5060_7080;
        if !sim.session(epoch) {
            return Err("session rejected".into());
        }
        for (port, id) in [(Port::Host, [0x11; 16]), (Port::Target, [0x22; 16])] {
            if !sim.grant(port, epoch, id, 1) {
                return Err("grant rejected".into());
            }
            for sequence in 0..BULK_SLOTS {
                if sim.write(port, &RoutingCell::data(epoch, id, sequence as u64).0) != CELL_BYTES {
                    return Err("initial saturation failed".into());
                }
            }
        }
        for step in 0..iterations {
            for (port, id) in [(Port::Host, [0x11; 16]), (Port::Target, [0x22; 16])] {
                if sim.write(port, &RoutingCell::data(epoch, id, u64::from(step)).0) != 0 {
                    return Err(format!("queue not full at step {step}"));
                }
            }
            if !sim.hid_probe(step + 1) {
                return Err(format!("HID starved at step {step}"));
            }
            for (port, id) in [(Port::Host, [0x11; 16]), (Port::Target, [0x22; 16])] {
                let mut actual = [0; CELL_BYTES];
                if sim.read(port.peer(), &mut actual) != CELL_BYTES
                    || actual != RoutingCell::data(epoch, id, u64::from(step)).0
                {
                    return Err(format!("routing order/content changed at step {step}"));
                }
                if sim.write(
                    port,
                    &RoutingCell::data(epoch, id, u64::from(step) + BULK_SLOTS as u64).0,
                ) != CELL_BYTES
                {
                    return Err(format!("refill failed at step {step}"));
                }
            }
        }
        Ok(StressReport {
            hid_services: iterations,
            routed_cells_per_direction: iterations,
            routed_bytes: u64::from(iterations) * 2 * CELL_BYTES as u64,
            bulk_high_water: sim.bulk_peak(),
            core_bytes: Simulator::core_bytes(),
        })
    })();
    sim.close();
    result
}
