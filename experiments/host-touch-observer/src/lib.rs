#[cfg(not(feature = "native-mt2"))]
pub mod forward;
#[cfg(feature = "native-mt2")]
#[path = "forward_native.rs"]
pub mod forward;
// Book-only raw contact decoding. No USB, event injection or clipboard access.
pub const RECORD_BYTES: usize = 96;
pub const MAX_CONTACTS: usize = 16;

pub fn eligible_builtin(built_in: bool, registry_id: u64, product: &str, transport: &str) -> bool {
    built_in
        && registry_id != 0
        && transport.eq_ignore_ascii_case("SPI")
        && product.to_ascii_lowercase().contains("trackpad")
        && !product.to_ascii_lowercase().contains("wiredkvm")
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Touch {
    pub id: i32,
    pub state: i32,
    pub x: f32,
    pub y: f32,
    pub vx: f32,
    pub vy: f32,
}
impl Touch {
    pub fn touching(&self) -> bool {
        // Public reverse-engineered MT states: 3=make, 4=touch,
        // 5=break (release), not a force/press state.
        matches!(self.state, 3 | 4)
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub frame: u32,
    pub timestamp: f64,
    pub count: usize,
    pub contacts: [Touch; MAX_CONTACTS],
}

/// Decode only the documented-by-observation common prefix. Shape and force
/// fields are deliberately not assigned meaning or converted to MT2 bytes.
pub fn decode(
    bytes: &[u8],
    count: usize,
    timestamp: f64,
    frame: usize,
) -> Result<Frame, &'static str> {
    if count > MAX_CONTACTS || bytes.len() != count * RECORD_BYTES {
        return Err("frame length/count");
    }
    if !timestamp.is_finite() || timestamp < 0.0 || frame > u32::MAX as usize {
        return Err("frame clock");
    }
    let mut out = Frame {
        frame: frame as u32,
        timestamp,
        count,
        contacts: [Touch::default(); MAX_CONTACTS],
    };
    for (i, record) in bytes.chunks_exact(RECORD_BYTES).enumerate() {
        let int = |n| i32::from_ne_bytes(record[n..n + 4].try_into().unwrap());
        let float = |n| f32::from_ne_bytes(record[n..n + 4].try_into().unwrap());
        let time = f64::from_ne_bytes(record[8..16].try_into().unwrap());
        if int(0) as u32 != out.frame || !time.is_finite() || (time - timestamp).abs() > 0.1 {
            return Err("record ABI/clock mismatch");
        }
        let touch = Touch {
            id: int(16),
            state: int(20),
            x: float(32),
            y: float(36),
            vx: float(40),
            vy: float(44),
        };
        if touch.id < 0 || !(0..=7).contains(&touch.state) {
            return Err("contact id/state");
        }
        if !touch.x.is_finite()
            || !touch.y.is_finite()
            || !touch.vx.is_finite()
            || !touch.vy.is_finite()
            || !(-0.25..=1.25).contains(&touch.x)
            || !(-0.25..=1.25).contains(&touch.y)
        {
            return Err("contact coordinates");
        }
        if out.contacts[..i].iter().any(|t| t.id == touch.id) {
            return Err("duplicate id");
        }
        out.contacts[i] = touch;
    }
    Ok(out)
}

#[derive(Default)]
pub struct Stats {
    pub frames: u64,
    pub moving_frames: u64,
    pub four_touch_frames: u64,
    pub four_record_frames: u64,
    pub state_counts: [u64; 8],
    pub max_touching: usize,
    pub timestamp_regressions: u64,
    pub max_gap_seconds: f64,
    previous: Option<f64>,
}
impl Stats {
    pub fn note(&mut self, f: &Frame) {
        self.frames += 1;
        if f.count == 4 {
            self.four_record_frames += 1;
        }
        for contact in &f.contacts[..f.count] {
            self.state_counts[contact.state as usize] += 1;
        }
        let n = f.contacts[..f.count]
            .iter()
            .filter(|t| t.touching())
            .count();
        self.max_touching = self.max_touching.max(n);
        if n == 4 {
            self.four_touch_frames += 1;
        }
        if f.contacts[..f.count]
            .iter()
            .any(|t| t.vx != 0.0 || t.vy != 0.0)
        {
            self.moving_frames += 1;
        }
        if let Some(t) = self.previous {
            if f.timestamp < t {
                self.timestamp_regressions += 1;
            } else {
                self.max_gap_seconds = self.max_gap_seconds.max(f.timestamp - t);
            }
        }
        self.previous = Some(f.timestamp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn records(n: usize) -> Vec<u8> {
        let mut b = vec![0; n * RECORD_BYTES];
        for i in 0..n {
            let r = &mut b[i * RECORD_BYTES..(i + 1) * RECORD_BYTES];
            r[..4].copy_from_slice(&12i32.to_ne_bytes());
            r[8..16].copy_from_slice(&3.0f64.to_ne_bytes());
            r[16..20].copy_from_slice(&(i as i32 + 1).to_ne_bytes());
            r[20..24].copy_from_slice(&4i32.to_ne_bytes());
            r[32..36].copy_from_slice(&0.3f32.to_ne_bytes());
            r[36..40].copy_from_slice(&0.7f32.to_ne_bytes());
        }
        b
    }
    #[test]
    fn two_and_four_contacts_keep_ids_and_unaccelerated_positions() {
        for n in [0, 2, 4, 5, 16] {
            let f = decode(&records(n), n, 3.0, 12).unwrap();
            assert_eq!(f.count, n);
            for i in 0..n {
                assert_eq!(f.contacts[i].id, i as i32 + 1);
                assert_eq!(f.contacts[i].x, 0.3);
                assert_eq!(f.contacts[i].y, 0.7);
            }
        }
    }
    #[test]
    fn lengths_count_and_abi_are_checked() {
        assert!(decode(&records(17), 17, 3.0, 12).is_err());
        assert!(decode(&records(2)[..191], 2, 3.0, 12).is_err());
        assert!(decode(&records(1), 1, 3.0, 13).is_err());
        assert!(decode(&records(1), 1, 4.0, 12).is_err());
        assert!(decode(&records(1), 1, f64::NAN, 12).is_err());
        let mut b = records(1);
        b[8..16].copy_from_slice(&f64::INFINITY.to_ne_bytes());
        assert!(decode(&b, 1, 3.0, 12).is_err());
    }
    #[test]
    fn invalid_contact_fields_cannot_escape() {
        for (offset, value) in [(16, -1i32), (20, 8i32)] {
            let mut b = records(1);
            b[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
            assert!(decode(&b, 1, 3.0, 12).is_err());
        }
        for offset in [32, 36, 40, 44] {
            let mut b = records(1);
            b[offset..offset + 4].copy_from_slice(&f32::NAN.to_ne_bytes());
            assert!(decode(&b, 1, 3.0, 12).is_err());
        }
        let mut b = records(2);
        b[112..116].copy_from_slice(&1i32.to_ne_bytes());
        assert!(decode(&b, 2, 3.0, 12).is_err());
    }
    #[test]
    fn physical_four_contacts_are_counted_separately_from_hover() {
        let f = decode(&records(4), 4, 3.0, 12).unwrap();
        let mut stats = Stats::default();
        stats.note(&f);
        assert_eq!(stats.four_touch_frames, 1);
        let mut b = records(4);
        b[20..24].copy_from_slice(&2i32.to_ne_bytes());
        stats.note(&decode(&b, 4, 3.0, 12).unwrap());
        assert_eq!(stats.four_touch_frames, 1);
        assert_eq!(stats.max_touching, 4);
    }
    #[test]
    fn break_and_linger_are_never_kept_down() {
        for state in 0..=7 {
            let t = Touch {
                state,
                ..Touch::default()
            };
            assert_eq!(t.touching(), state == 3 || state == 4);
        }
        let mut bytes = records(4);
        bytes[20..24].copy_from_slice(&5i32.to_ne_bytes());
        let mut stats = Stats::default();
        stats.note(&decode(&bytes, 4, 3.0, 12).unwrap());
        assert_eq!(stats.four_touch_frames, 0);
        assert_eq!(stats.four_record_frames, 1);
        assert_eq!(stats.state_counts[5], 1);
        assert_eq!(stats.max_touching, 3);
    }
    #[test]
    fn clock_regressions_are_not_hidden() {
        let mut f = decode(&records(2), 2, 3.0, 12).unwrap();
        let mut s = Stats::default();
        s.note(&f);
        f.timestamp = 2.0;
        s.note(&f);
        assert_eq!(s.timestamp_regressions, 1);
    }
}
#[test]
fn source_selection_rejects_mouse_touchbar_virtual_and_unknown() {
    assert!(eligible_builtin(
        true,
        42,
        "Apple Internal Keyboard / Trackpad",
        "SPI"
    ));
    for (built, id, product, transport) in [
        (false, 42, "Magic Trackpad", "Bluetooth"),
        (true, 42, "Magic Mouse", "SPI"),
        (true, 42, "Touch Bar", "SPI"),
        (true, 42, "WiredKVM Trackpad", "SPI"),
        (true, 0, "Trackpad", "SPI"),
        (true, 42, "Trackpad", "Virtual"),
        (true, 42, "", "SPI"),
    ] {
        assert!(!eligible_builtin(built, id, product, transport));
    }
}
