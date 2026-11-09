//! Native three-bit MT2 lifecycle. Caller supplies Book frames; no target APIs.
use crate::Frame;
use wiredkvm_mt2_protocol_draft::{
    native_format::{usb_frame, FingerKind, NativeContact, NativeState},
    Geometry,
};
pub struct Mapper {
    epoch: u32,
    waiting_up: bool,
    ids: [i32; 5],
    contacts: Vec<NativeContact>,
    clock: u32,
}
impl Default for Mapper {
    fn default() -> Self {
        Self {
            epoch: 0,
            waiting_up: true,
            ids: [-1; 5],
            contacts: Vec::new(),
            clock: 0,
        }
    }
}
impl Mapper {
    pub fn has_contacts(&self) -> bool {
        !self.contacts.is_empty()
    }
    pub fn enable(&mut self, epoch: u32) {
        self.epoch = epoch;
        self.waiting_up = true;
        self.ids = [-1; 5];
        self.contacts.clear();
    }
    fn encode(&mut self, c: &[NativeContact]) -> String {
        let p = usb_frame(c, self.clock).unwrap();
        self.clock = self.clock.wrapping_add(4);
        let hex = p
            .as_bytes()
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        format!("H D {} {}", self.epoch, hex)
    }
    fn release(&mut self) -> Vec<String> {
        if self.contacts.is_empty() || self.epoch == 0 {
            return Vec::new();
        }
        let stop = self
            .contacts
            .iter()
            .map(|c| c.with_state(NativeState::Stop))
            .collect::<Vec<_>>();
        let gone = self
            .contacts
            .iter()
            .map(|c| c.with_state(NativeState::Inactive))
            .collect::<Vec<_>>();
        let result = vec![self.encode(&stop), self.encode(&gone), self.encode(&[])];
        self.contacts.clear();
        self.ids = [-1; 5];
        result
    }
    pub fn disable(&mut self) -> Vec<String> {
        let mut rows = self.release();
        if self.epoch != 0 {
            rows.push(format!("H E {}", self.epoch));
        }
        self.epoch = 0;
        self.waiting_up = true;
        rows
    }
    pub fn sample(&mut self, f: &Frame) -> Vec<String> {
        if self.epoch == 0 {
            return Vec::new();
        }
        let touches = f.contacts[..f.count]
            .iter()
            .filter(|t| t.touching())
            .collect::<Vec<_>>();
        if self.waiting_up {
            if touches.is_empty() {
                self.waiting_up = false;
                return Vec::new();
            }
            if touches.iter().all(|t| t.state == 3) {
                self.waiting_up = false;
            } else {
                return Vec::new();
            }
        }
        if !(2..=5).contains(&touches.len()) {
            return self.release();
        }
        let mut result = Vec::new();
        // Stop the previous topology before reusing any ID. Motion with unchanged
        // contacts stays one frame, preserving both low latency and complete starts.
        let changed = self
            .ids
            .iter()
            .any(|id| *id >= 0 && !touches.iter().any(|t| t.id == *id));
        if changed {
            result.extend(self.release());
        }
        let kinds = [
            FingerKind::Index,
            FingerKind::Middle,
            FingerKind::Ring,
            FingerKind::Little,
            FingerKind::Thumb,
        ];
        let g = Geometry {
            major: 20,
            minor: 20,
            size: 10,
            pressure: 5,
            orientation: 0,
        };
        let mut start = Vec::new();
        let mut active = Vec::new();
        let mut new_contact = false;
        for t in touches {
            let (slot, new) = match self.ids.iter().position(|id| *id == t.id) {
                Some(i) => (i, false),
                None => {
                    let i = self.ids.iter().position(|id| *id < 0).unwrap();
                    self.ids[i] = t.id;
                    (i, true)
                }
            };
            let x = (-3678.0 + t.x.clamp(0.0, 1.0) * 7612.0).round() as i16;
            let y = (2587.0 - t.y.clamp(0.0, 1.0) * 5065.0).round() as i16;
            let c = NativeContact::new(
                x,
                y,
                slot as u8 + 1,
                kinds[slot],
                if new {
                    NativeState::Start
                } else {
                    NativeState::Active
                },
                g,
            )
            .unwrap();
            new_contact |= new;
            start.push(c);
            active.push(c.with_state(NativeState::Active));
        }
        if new_contact {
            result.push(self.encode(&start));
        }
        result.push(self.encode(&active));
        self.contacts = active;
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Touch, MAX_CONTACTS};
    use wiredkvm_mt2_protocol_draft::live::Packet;
    fn f(n: usize, state: i32) -> Frame {
        let mut c = [Touch::default(); MAX_CONTACTS];
        for (i, t) in c[..n].iter_mut().enumerate() {
            *t = Touch {
                id: i as i32,
                state,
                x: 0.2 + i as f32 * 0.1,
                y: 0.5,
                vx: 0.0,
                vy: 0.0,
            };
        }
        Frame {
            frame: 1,
            timestamp: 1.0,
            count: n,
            contacts: c,
        }
    }
    fn bytes(s: &str) -> Vec<u8> {
        let h = s.split(' ').last().unwrap();
        h.as_bytes()
            .chunks_exact(2)
            .map(|p| u8::from_str_radix(core::str::from_utf8(p).unwrap(), 16).unwrap())
            .collect()
    }
    #[test]
    fn four_fingers_have_types_and_distinct_start_move_stop() {
        let mut m = Mapper::default();
        m.enable(5);
        assert!(m.sample(&f(4, 4)).is_empty());
        m.sample(&f(0, 0));
        let rows = m.sample(&f(4, 3));
        assert_eq!(rows.len(), 2);
        let start = bytes(&rows[0]);
        let active = bytes(&rows[1]);
        for i in 0..4 {
            assert_eq!(start[15 + i * 9] >> 5, 3);
            assert_eq!((start[15 + i * 9] >> 2) & 7, 2 + i as u8);
            assert_eq!(active[15 + i * 9] >> 5, 4);
        }
        let release = m.sample(&f(4, 5));
        assert_eq!(release.len(), 3);
        assert_eq!(bytes(&release[0])[15] >> 5, 7);
        assert_eq!(bytes(&release[1])[15] >> 5, 0);
        assert_eq!(bytes(&release[2]).len(), 12);
    }
    #[test]
    fn source_handback_and_two_to_five_transitions_stay_valid() {
        let mut m = Mapper::default();
        m.enable(9);
        for n in [2, 3, 4, 5, 3, 2, 0, 4] {
            for row in m.sample(&f(n, 3)) {
                assert!(Packet::parse(&bytes(&row)).is_some());
            }
        }
        let end = m.disable();
        assert_eq!(end.last().unwrap(), "H E 9");
        assert!(m.sample(&f(4, 3)).is_empty());
    }
}
