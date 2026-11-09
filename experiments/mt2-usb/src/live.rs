//! Bounded gesture transport. Caller owns USB submission/completion; no I/O.
//! Full snapshots, not deltas. Coalesce motion only when contact topology matches.
use crate::{Contact, ContactState, Encoder, CONTACT_LEN, HEADER_LEN, INPUT_CAPACITY};

#[derive(Clone, Copy)]
pub struct Packet {
    pub bytes: [u8; INPUT_CAPACITY],
    pub len: usize,
}
impl Packet {
    const EMPTY: Self = Self {
        bytes: [0; INPUT_CAPACITY],
        len: 0,
    };
    pub fn parse(raw: &[u8]) -> Option<Self> {
        if raw.len() < HEADER_LEN
            || raw.len() > 57
            || (raw.len() - HEADER_LEN) % CONTACT_LEN != 0
            || raw[0] != 2
            || raw[1..7] != [0; 6]
            || raw[8] != 0x31
            || (!cfg!(feature = "native-mt2") && raw[11] != 0x88)
        {
            return None;
        }
        let count = (raw.len() - HEADER_LEN) / CONTACT_LEN;
        let mut ids = 0u16;
        let mut down = 0;
        let mut present = false;
        for record in raw[HEADER_LEN..].chunks_exact(CONTACT_LEN) {
            let id = record[8] & 15;
            let bit = 1 << id;
            if ids & bit != 0 {
                return None;
            }
            ids |= bit;
            if cfg!(feature = "native-mt2") {
                if raw[9] & 7 != 4 {
                    return None;
                }

                let state = record[3] >> 5;
                let kind = (record[3] >> 2) & 7;
                if id == 0
                    || !(1..=5).contains(&kind)
                    || ![0, 3, 4, 7].contains(&state)
                    || record[8] & 16 != 0
                {
                    return None;
                }
                present |= state != 0;
                if state == 3 || state == 4 {
                    down += 1;
                }
            } else {
                present = count != 0;
                match record[3] & 0xc0 {
                    0x80 => down += 1,
                    0xc0 => (),
                    _ => return None,
                }
            }
        }
        if raw[7] != u8::from(present) {
            return None;
        }
        // Single-finger pointer movement stays on the existing absolute mouse.
        if down == 1 {
            return None;
        }
        let mut p = Self::EMPTY;
        p.len = raw.len();
        p.bytes[..raw.len()].copy_from_slice(raw);
        Some(p)
    }
    fn topology(&self) -> (u16, u16, u64) {
        let mut all = 0;
        let mut down = 0;
        let mut states = 0u64;
        for r in self.bytes[HEADER_LEN..self.len].chunks_exact(CONTACT_LEN) {
            let bit = 1 << (r[8] & 15);
            all |= bit;
            let state = if cfg!(feature = "native-mt2") {
                r[3] >> 5
            } else {
                r[3] >> 6
            };
            states |= (state as u64) << ((r[8] & 15) * 3);
            if if cfg!(feature = "native-mt2") {
                state == 3 || state == 4
            } else {
                state == 2
            } {
                down |= bit;
            }
        }
        (all, down, states)
    }
}
const SLOTS: usize = 16;
pub const LEASE_MS: u32 = 180;

pub struct LiveCore {
    queue: [Packet; SLOTS],
    head: usize,
    count: usize,
    epoch: u32,
    active: bool,
    pending: u32,
    seen_epoch: u32,
    clock: u32,
    stage_at: u32,
    faults: u32,
    last: Packet,
    closing: bool,
    abort: bool,
    staged: bool,
}
impl Default for LiveCore {
    fn default() -> Self {
        Self::new()
    }
}
impl LiveCore {
    pub const fn new() -> Self {
        Self {
            queue: [Packet::EMPTY; SLOTS],
            head: 0,
            count: 0,
            epoch: 0,
            active: false,
            pending: 0,
            seen_epoch: 0,
            clock: 0,
            stage_at: 0,
            faults: 0,
            last: Packet::EMPTY,
            closing: false,
            abort: false,
            staged: false,
        }
    }
    pub fn reset(&mut self) {
        *self = Self::new();
    }
    fn push(&mut self, p: Packet) {
        let n = (self.head + self.count) % SLOTS;
        self.queue[n] = p;
        self.count += 1;
    }
    pub fn begin(&mut self, epoch: u32, now: u32) -> bool {
        if epoch == 0 {
            return false;
        }
        if self.active && self.epoch == epoch {
            return true;
        }
        if self.pending == epoch {
            return false;
        }
        if self.seen_epoch != 0 && (epoch.wrapping_sub(self.seen_epoch) as i32) <= 0 {
            return false;
        }
        self.seen_epoch = epoch;
        if self.active || self.closing || self.staged {
            self.end();
            self.pending = epoch;
            false
        } else {
            self.epoch = epoch;
            self.active = true;
            self.clock = now;
            true
        }
    }
    pub fn offer(&mut self, epoch: u32, raw: &[u8], now: u32) -> bool {
        if !self.active || self.closing || self.epoch != epoch {
            return false;
        }
        let Some(p) = Packet::parse(raw) else {
            self.faults = self.faults.wrapping_add(1);
            self.end();
            return false;
        };
        self.clock = now;
        // Never overwrite the head owned by USB DMA, or a begin/end transition.
        if self.count > usize::from(self.staged) {
            let tail = (self.head + self.count - 1) % SLOTS;
            if p.topology() == self.queue[tail].topology() {
                self.queue[tail] = p;
                self.last = p;
                return true;
            }
        }
        if self.count >= SLOTS - 2 {
            self.faults = self.faults.wrapping_add(1);
            self.end();
            return false;
        }
        self.push(p);
        self.last = p;
        true
    }
    pub fn cancel(&mut self, epoch: u32) {
        if epoch == self.pending {
            self.pending = 0;
        }
        if epoch == self.epoch {
            self.end();
        }
    }
    /// Flush queued motion. Hardware must retire/NAK the old DMA before release.
    pub fn end(&mut self) {
        if self.closing {
            return;
        }
        self.active = false;
        self.pending = 0;
        self.head = 0;
        self.count = 0;
        self.closing = true;
        self.abort = self.staged;
        let mut contacts = [Contact::from_observed_record([0; CONTACT_LEN]); 5];
        let n = if self.last.len >= HEADER_LEN {
            (self.last.len - HEADER_LEN) / CONTACT_LEN
        } else {
            0
        };
        for (i, r) in self.last.bytes[HEADER_LEN..HEADER_LEN + n * CONTACT_LEN]
            .chunks_exact(CONTACT_LEN)
            .enumerate()
        {
            contacts[i] = Contact::from_observed_record(r.try_into().unwrap())
                .with_state(ContactState::Release);
        }
        let mut enc = Encoder::new(0, 32);
        for c in [&contacts[..n], &[][..]] {
            let mut report = enc.frame(c, true).unwrap();
            if cfg!(feature = "native-mt2") {
                report.bytes[9..12].copy_from_slice(&[4, 0, 0]);
                for offset in (HEADER_LEN..report.len).step_by(CONTACT_LEN) {
                    report.bytes[offset + 3] = (report.bytes[offset + 3] & 0x1f) | 0xe0;
                    report.bytes[offset + 4..offset + 8].fill(0);
                }
            }
            let mut p = Packet::EMPTY;
            p.len = report.as_bytes().len();
            p.bytes[..p.len].copy_from_slice(report.as_bytes());
            self.push(p);
        }
        self.last = Packet::EMPTY;
    }
    pub fn tick(&mut self, now: u32, enabled: bool) {
        let touching = self.last.len >= HEADER_LEN && self.last.topology().1 != 0;
        let expired = (touching && now.wrapping_sub(self.clock) >= LEASE_MS)
            || (self.staged && now.wrapping_sub(self.stage_at) >= LEASE_MS);
        if self.active && (!enabled || expired) {
            if enabled {
                self.faults = self.faults.wrapping_add(1);
            }
            self.end();
        }
        if !self.closing && !self.active && self.pending != 0 {
            self.epoch = self.pending;
            self.pending = 0;
            self.active = true;
            self.clock = now;
        }
    }
    pub fn needs_abort(&self) -> bool {
        self.abort
    }
    pub fn aborted(&mut self) {
        self.abort = false;
        self.staged = false;
    }
    pub fn peek(&mut self) -> Option<&Packet> {
        if self.abort || self.count == 0 || self.staged {
            return None;
        }
        Some(&self.queue[self.head])
    }
    pub fn submitted(&mut self) {
        if self.count != 0 && !self.abort {
            self.staged = true;
            self.stage_at = self.clock;
        }
    }
    pub fn complete(&mut self) {
        if self.abort {
            self.aborted();
            return;
        }
        if !self.staged {
            return;
        }
        self.staged = false;
        self.head = (self.head + 1) % SLOTS;
        self.count -= 1;
        if self.closing && self.count == 0 {
            self.closing = false;
        }
    }
    pub fn faults(&self) -> u32 {
        self.faults
    }
    pub fn queued(&self) -> usize {
        self.count
    }
}
