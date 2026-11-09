//! Experimental geometry mapper. No clipboard or target OS access.
use crate::Frame;
use wiredkvm_mt2_protocol_draft::{Contact, ContactState, Encoder, Geometry};
pub struct Mapper {
    epoch: u32,
    waiting_up: bool,
    ids: [i32; 5],
    contacts: Vec<Contact>,
    encoder: Encoder,
}
impl Default for Mapper {
    fn default() -> Self {
        Self {
            epoch: 0,
            waiting_up: true,
            ids: [-1; 5],
            contacts: Vec::new(),
            encoder: Encoder::new(0, 32),
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
    pub fn disable(&mut self) -> Vec<String> {
        let mut out = self.release();
        if self.epoch != 0 {
            out.push(format!("H E {}", self.epoch));
        }
        self.epoch = 0;
        self.waiting_up = true;
        out
    }
    fn encode(&mut self, c: &[Contact]) -> String {
        let r = self.encoder.frame(c, true).unwrap();
        let hex = r
            .as_bytes()
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        format!("H D {} {hex}", self.epoch)
    }
    fn release(&mut self) -> Vec<String> {
        if self.epoch == 0 || self.contacts.is_empty() {
            return Vec::new();
        }
        let released = self
            .contacts
            .iter()
            .map(|c| c.with_state(ContactState::Release))
            .collect::<Vec<_>>();
        let out = vec![self.encode(&released), self.encode(&[])];
        self.contacts.clear();
        self.ids = [-1; 5];
        out
    }
    pub fn sample(&mut self, f: &Frame) -> Vec<String> {
        let touches = f.contacts[..f.count]
            .iter()
            .filter(|t| t.touching())
            .collect::<Vec<_>>();
        if self.epoch == 0 {
            return Vec::new();
        }
        if self.waiting_up {
            if touches.is_empty() {
                self.waiting_up = false;
                return Vec::new();
            }
            // A complete MakeTouch snapshot began after handoff; accept it.
            // Existing Touching contacts must first lift, preventing replay.
            if touches.iter().all(|t| t.state == 3) {
                self.waiting_up = false;
            } else {
                return Vec::new();
            }
        }
        if !(2..=5).contains(&touches.len()) {
            return self.release();
        }
        let mut out = Vec::new();
        let mut records = Vec::new();
        let old_ids = self.ids;
        for (i, id) in old_ids.iter().enumerate() {
            if *id != -1 && !touches.iter().any(|t| t.id == *id) {
                if let Some(c) = self.contacts.iter().find(|c| c.id() == i as u8) {
                    records.push(c.with_state(ContactState::Release));
                }
                self.ids[i] = -1;
            }
        }
        if records.len() + touches.len() > 5 {
            out.extend(self.release());
            records.clear();
        }
        // Never recycle a released slot in the same report (duplicate HID ID).
        if touches.iter().any(|t| !self.ids.contains(&t.id)) && records.len() != 0 {
            out.extend(self.release());
            records.clear();
        }
        let geometry = Geometry {
            major: 72,
            minor: 48,
            size: 31,
            pressure: 64,
            orientation: 0,
        };
        let mut current = Vec::new();
        for t in touches {
            let slot = match self.ids.iter().position(|id| *id == t.id) {
                Some(n) => n,
                None => {
                    let n = self.ids.iter().position(|id| *id == -1).unwrap();
                    self.ids[n] = t.id;
                    n
                }
            };
            // Linux MT2 surface bounds; Book normalized Y grows upward, logical
            // HID Y grows downward. Wire encoder applies its signed-Y packing.
            let x = (-3678.0 + t.x.clamp(0.0, 1.0) * 7612.0).round() as i16;
            let y = (2587.0 - t.y.clamp(0.0, 1.0) * 5065.0).round() as i16;
            current.push(
                Contact::synthesized(x, y, slot as u8, ContactState::Touch, geometry).unwrap(),
            );
        }
        records.extend_from_slice(&current);
        out.push(self.encode(&records));
        self.contacts = current;
        out
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Touch, MAX_CONTACTS};
    fn f(n: usize, state: i32) -> Frame {
        let mut c = [Touch::default(); MAX_CONTACTS];
        for (i, t) in c[..n].iter_mut().enumerate() {
            *t = Touch {
                id: 100 + i as i32,
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
    #[test]
    fn entry_requires_lift_single_stays_mouse() {
        let mut m = Mapper::default();
        m.enable(7);
        assert!(m.sample(&f(4, 4)).is_empty());
        m.sample(&f(0, 0));
        assert!(m.sample(&f(1, 4)).is_empty());
        assert_eq!(m.sample(&f(4, 4)).len(), 1);
        assert_eq!(m.sample(&f(1, 4)).len(), 2);
    }
    #[test]
    fn fresh_make_after_handoff_does_not_require_an_extra_gesture() {
        let mut m = Mapper::default();
        m.enable(6);
        assert_eq!(m.sample(&f(2, 3)).len(), 1);
    }
    #[test]
    fn phase_five_releases_all_and_does_not_keep_touching() {
        let mut m = Mapper::default();
        m.enable(8);
        m.sample(&f(0, 0));
        m.sample(&f(4, 4));
        let r = m.sample(&f(4, 5));
        assert_eq!(r.len(), 2);
        assert!(m.sample(&f(4, 5)).is_empty());
    }
    #[test]
    fn stop_precedes_new_epoch_and_local_frames_emit_nothing() {
        let mut m = Mapper::default();
        m.enable(9);
        m.sample(&f(0, 0));
        m.sample(&f(2, 4));
        let r = m.disable();
        assert_eq!(r.len(), 3);
        assert_eq!(r[2], "H E 9");
        assert!(m.sample(&f(4, 4)).is_empty());
        m.enable(10);
        assert!(m.sample(&f(4, 4)).is_empty());
    }
}

#[cfg(test)]
mod transition_tests {
    use super::*;
    use crate::{Touch, MAX_CONTACTS};
    use wiredkvm_mt2_protocol_draft::live::Packet;
    #[test]
    fn all_two_to_five_contact_replacements_produce_valid_distinct_ids() {
        let mut m = Mapper::default();
        m.enable(1);
        for n in [2, 3, 4, 5, 4, 3, 2, 0, 2, 4] {
            let mut c = [Touch::default(); MAX_CONTACTS];
            for (i, t) in c[..n].iter_mut().enumerate() {
                *t = Touch {
                    id: 100 + i as i32 + n as i32,
                    state: 3,
                    x: 0.5,
                    y: 0.5,
                    vx: 0.0,
                    vy: 0.0,
                };
            }
            let f = Frame {
                frame: 1,
                timestamp: 1.0,
                count: n,
                contacts: c,
            };
            for row in m.sample(&f) {
                let hex = row.split(' ').last().unwrap();
                let b = hex
                    .as_bytes()
                    .chunks_exact(2)
                    .map(|v| u8::from_str_radix(core::str::from_utf8(v).unwrap(), 16).unwrap())
                    .collect::<Vec<_>>();
                assert!(Packet::parse(&b).is_some());
            }
        }
    }
}
