//! Explicit macOS MT2 fields, separate from the coarse Linux two-bit view.
//! Wire facts cross-checked with VoodooInputSimulatorDevice.hpp/.cpp. This is
//! independently written encoding, not imported kernel-extension code.
use crate::{Contact, Error, Geometry, InputReport, CONTACT_LEN, HEADER_LEN, INPUT_CAPACITY};

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FingerKind {
    Thumb = 1,
    Index = 2,
    Middle = 3,
    Ring = 4,
    Little = 5,
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativeState {
    Inactive = 0,
    Start = 3,
    Active = 4,
    Stop = 7,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativeContact(Contact);
impl NativeContact {
    pub fn new(
        x: i16,
        y: i16,
        id: u8,
        kind: FingerKind,
        state: NativeState,
        g: Geometry,
    ) -> Result<Self, Error> {
        // Apple's transducer IDs are 1..15; zero is not used by this mapper.
        if !(1..=15).contains(&id) {
            return Err(Error::ContactIdRange);
        }
        if !(-4..=3).contains(&g.orientation) {
            return Err(Error::OrientationRange);
        }
        let c = Contact::from_observed_record([0; CONTACT_LEN])
            .with_position(x, y)?
            .with_id(id)?;
        let mut r = *c.bytes();
        // The low two bits complete signed Y. Bits 2..4 identify the finger;
        // bits 5..7 are the complete lifecycle, not just its top two bits.
        r[3] = (r[3] & 3) | ((kind as u8) << 2) | ((state as u8) << 5);
        r[4] = g.major;
        r[5] = g.minor;
        r[6] = g.size;
        r[7] = g.pressure;
        r[8] |= ((g.orientation + 4) as u8) << 5;
        Ok(Self(Contact::from_observed_record(r)))
    }
    pub fn bytes(&self) -> &[u8; CONTACT_LEN] {
        self.0.bytes()
    }
    pub fn with_state(self, state: NativeState) -> Self {
        let mut r = *self.bytes();
        r[3] = (r[3] & 0x1f) | ((state as u8) << 5);
        if matches!(state, NativeState::Stop | NativeState::Inactive) {
            r[4..8].fill(0);
        }
        Self(Contact::from_observed_record(r))
    }
}

/// USB touch-presence bit plus a complete three-byte clock. The I2C transport's
/// 2/3 presence convention is deliberately not assumed for this USB candidate.
pub fn usb_frame(contacts: &[NativeContact], millis: u32) -> Result<InputReport, Error> {
    if contacts.len() > 5 {
        return Err(Error::TooManyContacts);
    }
    let mut ids = 0u16;
    let mut present = false;
    let mut r = InputReport {
        bytes: [0; INPUT_CAPACITY],
        len: HEADER_LEN + contacts.len() * CONTACT_LEN,
    };
    r.bytes[0] = 2;
    r.bytes[8] = 0x31;
    let stamp = millis.wrapping_mul(8) | 4;
    r.bytes[9] = stamp as u8;
    r.bytes[10] = (stamp >> 8) as u8;
    r.bytes[11] = (stamp >> 16) as u8;
    for (i, c) in contacts.iter().enumerate() {
        let id = c.bytes()[8] & 15;
        let bit = 1 << id;
        if ids & bit != 0 {
            return Err(Error::DuplicateContactId);
        }
        ids |= bit;
        present |= c.bytes()[3] >> 5 != 0;
        r.bytes[HEADER_LEN + i * CONTACT_LEN..HEADER_LEN + (i + 1) * CONTACT_LEN]
            .copy_from_slice(c.bytes());
    }
    r.bytes[7] = u8::from(present);
    Ok(r)
}
