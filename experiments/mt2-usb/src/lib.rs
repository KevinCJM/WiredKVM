#![no_std]
//! ISOLATED PROTOCOL EXPERIMENT. No USB driver or production dependency.
//! Wire facts and unresolved fields are documented in README.md and SOURCES.md.

#[cfg(feature = "c-abi")]
pub mod ffi;
#[cfg(all(feature = "c-abi", feature = "ram-setup"))]
pub mod ram_setup;
pub mod live;
pub mod native_format;
#[cfg(feature = "c-abi")]
mod fixture;

#[cfg(all(feature = "c-abi", target_os = "none"))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo<'_>) -> ! {
    loop {
        core::hint::spin_loop();
    }
}

pub const MAX_CONTACTS: usize = 5;
pub const INPUT_CAPACITY: usize = 64;
pub const HEADER_LEN: usize = 12;
pub const CONTACT_LEN: usize = 9;
pub const X_MIN: i16 = -4096;
pub const X_MAX: i16 = 4095;
// The wire stores the negative of logical Y as a signed 13-bit number.
pub const Y_MIN: i16 = -4095;
pub const Y_MAX: i16 = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    CoordinateRange,
    ContactIdRange,
    DuplicateContactId,
    TooManyContacts,
    Disabled,
    MissingPropertyCapture,
    PropertyCaptureTooLarge,
    UnsupportedRequest,
    InvalidLength,
    InvalidValue,
    ReportIdMismatch,
    OrientationRange,
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContactState {
    None = 0x00,
    Approach = 0x40,
    Touch = 0x80,
    Release = 0xc0,
}

/// Opaque observed contact record. Unknown pressure/shape/reserved fields are
/// retained. Constructing a record does NOT certify its meaning to macOS.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Contact([u8; CONTACT_LEN]);

/// USB MT2 fields decoded by the upstream Linux magicmouse driver. These are
/// protocol units, not calibrated millimetres/force. Values used for synthesized
/// contacts must still be accepted by the target's native driver in real tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    pub major: u8,
    pub minor: u8,
    pub size: u8,
    pub pressure: u8,
    pub orientation: i8,
}

impl Contact {
    /// Explicit synthesized record, separate from the opaque observed-record
    /// constructor. No unknown bytes are asserted to have been captured.
    pub fn synthesized(x:i16,y:i16,id:u8,state:ContactState,geometry:Geometry)->Result<Self,Error> {
        if !(-4..=3).contains(&geometry.orientation) {return Err(Error::OrientationRange);}
        let mut result=Self([0;CONTACT_LEN]).with_position(x,y)?.with_id(id)?.with_state(state);
        result.0[4]=geometry.major;result.0[5]=geometry.minor;
        result.0[6]=geometry.size;result.0[7]=geometry.pressure;
        result.0[8]|=((geometry.orientation+4) as u8)<<5;
        Ok(result)
    }
    pub const fn from_observed_record(record: [u8; CONTACT_LEN]) -> Self {
        Self(record)
    }

    pub const fn bytes(&self) -> &[u8; CONTACT_LEN] {
        &self.0
    }
    pub fn id(&self) -> u8 {
        self.0[8] & 15
    }
    pub fn state(&self) -> ContactState {
        match self.0[3] & 0xc0 {
            0x40 => ContactState::Approach,
            0x80 => ContactState::Touch,
            0xc0 => ContactState::Release,
            _ => ContactState::None,
        }
    }

    pub fn position(&self) -> (i16, i16) {
        let x = u16::from(self.0[0]) | (u16::from(self.0[1] & 31) << 8);
        let raw_y = u16::from(self.0[1] >> 5)
            | (u16::from(self.0[2]) << 3)
            | (u16::from(self.0[3] & 3) << 11);
        (signed_13(x), -signed_13(raw_y))
    }

    pub fn with_position(mut self, x: i16, y: i16) -> Result<Self, Error> {
        if !(X_MIN..=X_MAX).contains(&x) || !(Y_MIN..=Y_MAX).contains(&y) {
            return Err(Error::CoordinateRange);
        }
        let rx = (x as u16) & 0x1fff;
        let ry = ((-(i32::from(y))) as u16) & 0x1fff;
        self.0[0] = rx as u8;
        self.0[1] = ((rx >> 8) as u8 & 31) | ((ry as u8 & 7) << 5);
        self.0[2] = (ry >> 3) as u8;
        self.0[3] = (self.0[3] & 0xfc) | ((ry >> 11) as u8 & 3);
        Ok(self)
    }

    pub fn with_id(mut self, id: u8) -> Result<Self, Error> {
        if id > 15 {
            return Err(Error::ContactIdRange);
        }
        self.0[8] = (self.0[8] & 0xf0) | id;
        Ok(self)
    }

    pub fn with_state(mut self, state: ContactState) -> Self {
        self.0[3] = (self.0[3] & 0x3f) | state as u8;
        self
    }
}

fn signed_13(raw: u16) -> i16 {
    let signed = i32::from(raw & 0x1fff);
    (if signed & 0x1000 != 0 {
        signed - 8192
    } else {
        signed
    }) as i16
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputReport {
    bytes: [u8; INPUT_CAPACITY],
    len: usize,
}

impl InputReport {
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}

/// Serializes only known MT2 header/position fields. No scheduler, interpolation
/// or automatic gesture synthesis. The caller supplies complete contact records.
pub struct Encoder {
    timestamp: u16,
    increment: u16,
    previous: [Contact; MAX_CONTACTS],
    count: usize,
}

impl Encoder {
    pub const fn new(timestamp: u16, increment: u16) -> Self {
        Self {
            timestamp,
            increment,
            previous: [Contact::from_observed_record([0; CONTACT_LEN]); MAX_CONTACTS],
            count: 0,
        }
    }

    pub const fn next_timestamp(&self) -> u16 {
        self.timestamp
    }

    pub fn reset(&mut self, timestamp: u16) {
        self.timestamp = timestamp;
        self.previous = [Contact::from_observed_record([0; CONTACT_LEN]); MAX_CONTACTS];
        self.count = 0;
    }

    pub fn frame(&mut self, contacts: &[Contact], enabled: bool) -> Result<InputReport, Error> {
        if !enabled {
            return Err(Error::Disabled);
        }
        if contacts.len() > MAX_CONTACTS {
            return Err(Error::TooManyContacts);
        }
        let mut seen = 0u16;
        for contact in contacts {
            let bit = 1u16 << contact.id();
            if seen & bit != 0 {
                return Err(Error::DuplicateContactId);
            }
            seen |= bit;
        }
        let report = self.encode(contacts);
        self.previous[..contacts.len()].copy_from_slice(contacts);
        self.count = contacts.len();
        Ok(report)
    }

    /// Returns an explicit RELEASE frame followed by a zero-contact frame.
    /// Their delivery cadence and host acceptance remain hardware test items.
    /// No button bit is ever asserted by this gesture-only draft.
    pub fn release(&mut self, enabled: bool) -> Result<[InputReport; 2], Error> {
        if !enabled {
            return Err(Error::Disabled);
        }
        let mut contacts = self.previous;
        for contact in &mut contacts[..self.count] {
            *contact = contact.with_state(ContactState::Release);
        }
        let release = self.encode(&contacts[..self.count]);
        let gone = self.encode(&[]);
        self.previous = [Contact::from_observed_record([0; CONTACT_LEN]); MAX_CONTACTS];
        self.count = 0;
        Ok([release, gone])
    }

    fn encode(&mut self, contacts: &[Contact]) -> InputReport {
        let mut result = InputReport {
            bytes: [0; INPUT_CAPACITY],
            len: HEADER_LEN + contacts.len() * CONTACT_LEN,
        };
        result.bytes[0] = 0x02;
        // bytes 1..6 stay zero: clicks and pointer movement remain separate.
        result.bytes[7] = u8::from(!contacts.is_empty());
        result.bytes[8] = 0x31;
        result.bytes[9..11].copy_from_slice(&self.timestamp.to_le_bytes());
        result.bytes[11] = 0x88;
        for (i, contact) in contacts.iter().enumerate() {
            let offset = HEADER_LEN + i * CONTACT_LEN;
            result.bytes[offset..offset + CONTACT_LEN].copy_from_slice(contact.bytes());
        }
        self.timestamp = self.timestamp.wrapping_add(self.increment);
        result
    }
}

/// Feature reports use control transfers and are NOT limited to a 64-byte
/// interrupt report. This draft caps property responses at 256 bytes including ID.
pub struct FeatureReply {
    bytes: [u8; 256],
    len: usize,
}
impl FeatureReply {
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
    fn new(id: u8, payload: &[u8], requested: usize) -> Self {
        let mut reply = Self {
            bytes: [0; 256],
            len: (payload.len() + 1).min(requested),
        };
        if reply.len > 0 {
            reply.bytes[0] = id;
            reply.bytes[1..reply.len].copy_from_slice(&payload[..reply.len - 1]);
        }
        reply
    }
}

/// Model of the observed selector/enable/config behavior. The USB adapter does
/// not exist. Payload lengths are strict; unknown requests fail closed.
pub struct FeatureMachine<'a> {
    property_capture: &'a [u8],
    selected: u8,
    config_99: [u8; 2],
    enabled: bool,
}

impl<'a> FeatureMachine<'a> {
    pub fn new(property_capture: &'a [u8]) -> Result<Self, Error> {
        if property_capture.is_empty() {
            return Err(Error::MissingPropertyCapture);
        }
        if property_capture.len() > 255 {
            return Err(Error::PropertyCaptureTooLarge);
        }
        Ok(Self {
            property_capture,
            selected: 0x99,
            config_99: [0; 2],
            enabled: false,
        })
    }

    pub const fn enabled(&self) -> bool {
        self.enabled
    }
    pub fn reset(&mut self) {
        self.selected = 0x99;
        self.config_99 = [0; 2];
        self.enabled = false;
    }

    /// Reply includes report ID. Length is clipped exactly as GET_REPORT wLength.
    pub fn get(&self, report_id: u8, requested: usize) -> Result<FeatureReply, Error> {
        let selector_size = match self.selected {
            0xdb => self.property_capture.len(),
            _ => 2,
        };
        let selector = [self.selected, 0, selector_size as u8, 0];
        let enable = [u8::from(self.enabled)];
        let payload: &[u8] = match report_id {
            0x00 => &[1],
            0x01 => &selector,
            0x02 => &enable,
            0x99 => &self.config_99,
            0xdb => self.property_capture,
            _ => return Err(Error::UnsupportedRequest),
        };
        Ok(FeatureReply::new(report_id, payload, requested))
    }

    /// Normalized payload EXCLUDES the report ID. An eventual USB driver must
    /// establish its buffer contract before calling this API; see README gaps.
    pub fn set_payload(&mut self, report_id: u8, payload: &[u8]) -> Result<(), Error> {
        match report_id {
            0x01 => {
                if payload.len() != 1 {
                    return Err(Error::InvalidLength);
                }
                if !matches!(payload[0], 0xdb | 0x99) {
                    return Err(Error::UnsupportedRequest);
                }
                self.selected = payload[0];
            }
            0x02 => {
                if payload.len() != 1 {
                    return Err(Error::InvalidLength);
                }
                if payload[0] > 1 {
                    return Err(Error::InvalidValue);
                }
                self.enabled = payload[0] == 1;
            }
            0x99 => {
                if payload.len() != 2 {
                    return Err(Error::InvalidLength);
                }
                self.config_99.copy_from_slice(payload);
            }
            _ => return Err(Error::UnsupportedRequest),
        }
        Ok(())
    }

    /// Explicit alternate entry for buffers that INCLUDE the report ID. Never
    /// heuristically strip a prefix: the adapter must choose one API contract.
    pub fn set_wire(&mut self, report_id: u8, wire: &[u8]) -> Result<(), Error> {
        if wire.first() != Some(&report_id) {
            return Err(Error::ReportIdMismatch);
        }
        self.set_payload(report_id, &wire[1..])
    }
}
