//! Offline guards and the experiment-only WKAP protocol. No hardware I/O here.
use std::collections::BTreeMap;
pub type Result<T> = std::result::Result<T, String>;
pub const SERIAL: &str = "CH32V407-DoNotShip";
pub const ASSOCIATION: &str = "A47C8F062A1A/ad21ad506c54c6c6";
pub const POINTS: [(u16, u16); 5] = [
    (16384, 16384),
    (8192, 8192),
    (24576, 8192),
    (8192, 24576),
    (24576, 24576),
];
pub const FIRMWARE_SHA: Option<&str> = option_env!("WK407_PROBE_FIRMWARE_SHA256");
/// Only the reviewed 2026-11-09 candidate may enter a supervised Book-only
/// five-point test. This does not authorize production or mini deployment.
pub const REVIEWED_FIRMWARE_SHA: &str =
    "0c8da9dd860070794a2ebc9eebb6ae1f69ec46407d5f9cf4637654f6cd79d8dd";
pub const fn reviewed_firmware(sha: Option<&str>) -> bool {
    let Some(sha) = sha else { return false };
    let actual = sha.as_bytes();
    let expected = REVIEWED_FIRMWARE_SHA.as_bytes();
    if actual.len() != expected.len() { return false; }
    let mut i = 0;
    while i < actual.len() {
        if actual[i] != expected[i] { return false; }
        i += 1;
    }
    true
}
pub const HARDWARE_EXECUTION_REVIEWED: bool = reviewed_firmware(FIRMWARE_SHA);
pub fn require(ok: bool, why: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(why.into())
    }
}
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Text(String),
    Bytes(Vec<u8>),
    List(Vec<Value>),
    Dict(BTreeMap<String, Value>),
}
impl Value {
    pub fn get(&self, key: &str) -> &Value {
        if let Self::Dict(d) = self {
            d.get(key).unwrap_or(&Self::Null)
        } else {
            &Self::Null
        }
    }
    pub fn int(&self) -> Option<i64> {
        if let Self::Int(x) = self {
            Some(*x)
        } else {
            None
        }
    }
    pub fn text(&self) -> Option<&str> {
        if let Self::Text(x) = self {
            Some(x)
        } else {
            None
        }
    }
    pub fn is(&self, key: &str, value: &str) -> bool {
        self.get(key).text() == Some(value)
    }
}
pub fn walk<'a>(v: &'a Value, out: &mut Vec<&'a Value>) {
    match v {
        Value::List(a) => {
            for v in a {
                walk(v, out)
            }
        }
        Value::Dict(_) => {
            out.push(v);
            walk(v.get("IORegistryEntryChildren"), out)
        }
        _ => (),
    }
}
pub fn vendor_descriptor() -> Vec<u8> {
    vec![
        6, 0x60, 0xff, 9, 0x61, 0xa1, 1, 0x15, 0, 0x26, 0xff, 0, 0x75, 8, 0x95, 64, 9, 0x62, 0x81,
        2, 0x95, 64, 9, 0x63, 0x91, 2, 0x95, 64, 9, 0x64, 0xb1, 2, 0xc0,
    ]
}
pub fn absolute_descriptor() -> Vec<u8> {
    vec![
        5, 1, 9, 1, 0xa1, 1, 0x85, 3, 9, 2, 0xa1, 2, 5, 9, 0x19, 1, 0x29, 5, 0x15, 0, 0x25, 1,
        0x75, 1, 0x95, 5, 0x81, 2, 0x95, 3, 0x81, 1, 5, 1, 9, 0x30, 9, 0x31, 0x15, 0, 0x26, 0xff,
        0x7f, 0x75, 16, 0x95, 2, 0x81, 2, 9, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 8, 0x95, 1, 0x81,
        6, 5, 0x0c, 0x0a, 0x38, 2, 0x81, 6, 0xc0, 0xc0,
    ]
}
#[derive(Clone, Debug, PartialEq)]
pub struct Identity {
    pub location: u32,
    pub registry: u64,
}
pub fn select(registry: &Value) -> Result<Identity> {
    let mut all = vec![];
    walk(registry, &mut all);
    let devices: Vec<_> = all
        .iter()
        .copied()
        .filter(|d| d.is("IOObjectClass", "IOUSBHostDevice"))
        .collect();
    let vidpid = |d: &&Value, v, p| {
        d.get("idVendor").int() == Some(v) && d.get("idProduct").int() == Some(p)
    };
    require(
        !devices
            .iter()
            .any(|d| vidpid(d, 0x1a86, 0x4070) || vidpid(d, 0x1a86, 0x8010)),
        "Host USB1 or DBG is present; USB2 only required",
    )?;
    let roles: Vec<_> = devices
        .iter()
        .copied()
        .filter(|d| d.is("USB Serial Number", SERIAL))
        .collect();
    let targets: Vec<_> = devices
        .iter()
        .filter(|d| vidpid(d, 0x05ac, 0x0265))
        .collect();
    require(
        roles.len() == 1 && targets.len() == 1 && std::ptr::eq(roles[0], *targets[0]),
        "Need exactly one experimental target with expected serial",
    )?;
    let d = roles[0];
    require(
        d.get("bcdDevice").int() == Some(0x026c),
        "Expected isolated 026c candidate",
    )?;
    require(
        d.is("USB Vendor Name", "WiredKVM Prototype"),
        "Unexpected manufacturer",
    )?;
    let mut nodes = vec![];
    walk(d, &mut nodes);
    for (number, expected) in [(1, absolute_descriptor()), (2, vendor_descriptor())] {
        let itfs: Vec<_> = nodes
            .iter()
            .copied()
            .filter(|n| {
                n.is("IOObjectClass", "IOUSBHostInterface")
                    && n.get("bInterfaceNumber").int() == Some(number)
            })
            .collect();
        require(itfs.len() == 1, "Missing or ambiguous target HID interface")?;
        let mut children = vec![];
        walk(itfs[0], &mut children);
        let descs: Vec<_> = children
            .iter()
            .flat_map(|n| [n.get("ReportDescriptor"), n.get("HIDReportDescriptor")])
            .filter_map(|v| {
                if let Value::Bytes(b) = v {
                    Some(b)
                } else {
                    None
                }
            })
            .collect();
        require(
            !descs.is_empty() && descs.iter().all(|b| **b == expected),
            "Actual HID descriptor differs from audited candidate",
        )?;
        if number == 1 {
            require(
                !children.iter().any(|n| {
                    n.get("IOClass").text().unwrap_or("").contains("Multitouch")
                        || n.get("IOUserClass")
                            .text()
                            .unwrap_or("")
                            .contains("Multitouch")
                }),
                "Absolute interface claimed by multitouch driver",
            )?;
            // AbsolutePointer property is deliberately not required. Real coordinates decide.
        }
    }
    let location = d.get("locationID").int().ok_or("No USB location")?;
    let id = d
        .get("IORegistryEntryID")
        .int()
        .ok_or("No USB registry ID")?;
    require(
        location >= 0 && location <= u32::MAX as i64 && id > 0,
        "Invalid USB identity fields",
    )?;
    Ok(Identity {
        location: location as u32,
        registry: id as u64,
    })
}
pub fn check_processes(text: &str) -> Result<()> {
    for line in text.lines() {
        let cmd = line
            .trim()
            .split_once(char::is_whitespace)
            .map(|(_, c)| c.trim())
            .unwrap_or("");
        let name = cmd.rsplit('/').next().unwrap_or(cmd).to_lowercase();
        require(
            !(name.contains("wiredkvm") || name.starts_with("macos-capture")),
            "Controller/capture/companion still running; probe will not stop it",
        )?;
    }
    Ok(())
}
pub fn validate_proof(v: &Value, age: f64, association: &str) -> Result<()> {
    require(
        association == ASSOCIATION,
        "Explicit same-board association required",
    )?;
    let sha = FIRMWARE_SHA.ok_or("Build is not bound to a verified candidate firmware SHA256")?;
    require(reviewed_firmware(Some(sha)), "Compiled firmware is not the reviewed Book-only candidate")?;
    require(
        sha.len() == 64 && sha.bytes().all(|c| c.is_ascii_hexdigit()),
        "Invalid compiled candidate SHA256",
    )?;
    for k in ["flashed", "readback_verified", "reset_run"] {
        require(
            v.get(k) == &Value::Bool(true),
            "Flash proof is not a verified running flash",
        )?;
    }
    for (k, s) in [
        ("probe_serial", "A47C8F062A1A"),
        ("chip_id", "0x46740011"),
        ("uid", "ad21ad506c54c6c6"),
        ("firmware_sha256", sha),
    ] {
        require(v.is(k, s), "Flash proof board or firmware mismatch")?;
    }
    require(
        (-60.0..=21600.0).contains(&age),
        "Flash proof too old or future dated",
    )
}
pub fn request(op: u8, point: u8, nonce: u32, seq: u32) -> Result<[u8; 64]> {
    require(nonce != 0 && seq != 0, "Zero nonce or sequence")?;
    require(
        match op {
            1 => point == 0 && seq == 1,
            2 => point < 5 && (2..=6).contains(&seq),
            3 => point == 0 && (2..=7).contains(&seq),
            _ => false,
        },
        "Forbidden probe operation",
    )?;
    let mut b = [0; 64];
    b[..4].copy_from_slice(b"WKAP");
    b[4] = 1;
    b[5] = op;
    b[6] = point;
    b[8..12].copy_from_slice(&nonce.to_le_bytes());
    b[12..16].copy_from_slice(&seq.to_le_bytes());
    Ok(b)
}
#[derive(Debug, PartialEq)]
pub struct Status {
    pub phase: u8,
    pub result: u8,
    pub point: u8,
    pub nonce: u32,
    pub accepted: u32,
    pub submitted: u32,
    pub completed: u32,
    pub received: u32,
    pub remaining: u32,
    pub flags: u32,
    pub invalidations: u32,
    pub epoch: u32,
}
impl Status {
    pub fn input_idle(&self) -> bool { self.flags & 15 == 0 }
    pub fn disarm_complete(&self, nonce: u32) -> Result<bool> {
        require(self.nonce == 0 || self.nonce == nonce, "Another probe owns the endpoint")?;
        if self.input_idle() {
            require(self.nonce == 0, "DISARM nonce not cleared")?;
            return Ok(true);
        }
        Ok(false)
    }
    pub fn evidence(&self) -> String {
        format!("{{\"phase\":{},\"result\":{},\"point\":{},\"accepted\":{},\"submitted\":{},\"completed\":{},\"received\":{},\"remaining_ms\":{},\"flags\":{},\"epoch\":{}}}",self.phase,self.result,self.point,self.accepted,self.submitted,self.completed,self.received,self.remaining,self.flags,self.epoch)
    }
    pub fn point_complete(&self, nonce: u32, seq: u32, epoch: u32, point: u8) -> Result<bool> {
        self.safe()?;
        require(
            self.result == 0
                && self.nonce == nonce
                && self.epoch == epoch
                && self.remaining > 0
                && self.flags & 1 != 0,
            "Rejected, expired or unrelated point status",
        )?;
        require(
            self.completed <= self.submitted
                && self.submitted <= self.accepted
                && self.accepted <= seq
                && self.received <= seq,
            "Out-of-order point status",
        )?;
        if self.accepted < seq {
            return Ok(false);
        }
        require(
            self.received == seq && self.point == point,
            "Accepted point mismatch",
        )?;
        if self.completed == seq {
            require(self.phase == 4, "Completion phase mismatch")?;
            return Ok(true);
        }
        Ok(false)
    }
    pub fn parse(b: &[u8]) -> Result<Self> {
        require(
            b.len() == 64
                && b[..4] == *b"WKAS"
                && b[4] == 1
                && b[5] <= 4
                && b[6] <= 7
                && b[44..].iter().all(|x| *x == 0),
            "Malformed status",
        )?;
        let get = |i| u32::from_le_bytes(b[i..i + 4].try_into().unwrap());
        let s = Self {
            phase: b[5],
            result: b[6],
            point: b[7],
            nonce: get(8),
            accepted: get(12),
            submitted: get(16),
            completed: get(20),
            received: get(24),
            remaining: get(28),
            flags: get(32),
            invalidations: get(36),
            epoch: get(40),
        };
        require(s.flags & !0xf0f == 0, "Unknown status flags")?;
        Ok(s)
    }
    pub fn safe(&self) -> Result<()> {
        require(
            self.flags & (1 << 9) != 0 && self.flags & ((1 << 8) | (1 << 11)) == 0,
            "Firmware reports USB1, target offline, or held input",
        )
    }
    pub fn transaction(&self, nonce: u32, seq: u32, epoch: u32) -> Result<()> {
        self.safe()?;
        require(
            self.result == 0
                && self.nonce == nonce
                && self.accepted == seq
                && self.received == seq
                && self.epoch == epoch
                && self.remaining > 0,
            "Rejected, expired, stale or unrelated status",
        )
    }
}
pub fn coordinates(point: usize, width: f64, height: f64) -> Result<(f64, f64)> {
    let p = POINTS.get(point).ok_or("Bad point")?;
    Ok((
        p.0 as f64 / 32767.0 * (width - 1.0),
        p.1 as f64 / 32767.0 * (height - 1.0),
    ))
}
pub fn position_pass(expected: (f64, f64), actual: (f64, f64)) -> bool {
    actual.0.is_finite()
        && actual.1.is_finite()
        && (expected.0 - actual.0).abs() <= 4.0
        && (expected.1 - actual.1).abs() <= 4.0
}
pub fn quote(s: &str) -> String {
    format!(
        "\"{}\"",
        s.chars()
            .flat_map(|c| match c {
                '"' => "\\\"".chars().collect::<Vec<_>>(),
                '\\' => "\\\\".chars().collect(),
                c if c < ' ' => format!("\\u{:04x}", c as u32).chars().collect(),
                c => vec![c],
            })
            .collect::<String>()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn d(pairs: Vec<(&str, Value)>) -> Value {
        Value::Dict(pairs.into_iter().map(|(k, v)| (k.into(), v)).collect())
    }
    fn fixture() -> Value {
        d(vec![
            ("IOObjectClass", Value::Text("IOUSBHostDevice".into())),
            ("USB Serial Number", Value::Text(SERIAL.into())),
            ("USB Vendor Name", Value::Text("WiredKVM Prototype".into())),
            ("idVendor", Value::Int(0x05ac)),
            ("idProduct", Value::Int(0x0265)),
            ("bcdDevice", Value::Int(0x026c)),
            ("locationID", Value::Int(123)),
            ("IORegistryEntryID", Value::Int(42)),
            (
                "IORegistryEntryChildren",
                Value::List(
                    [(1, absolute_descriptor()), (2, vendor_descriptor())]
                        .into_iter()
                        .map(|(n, b)| {
                            d(vec![
                                ("IOObjectClass", Value::Text("IOUSBHostInterface".into())),
                                ("bInterfaceNumber", Value::Int(n)),
                                ("ReportDescriptor", Value::Bytes(b)),
                            ])
                        })
                        .collect(),
                ),
            ),
        ])
    }
    #[test]
    fn selector_accepts_without_absolute_property() {
        assert_eq!(select(&Value::List(vec![fixture()])).unwrap().location, 123);
    }
    #[test]
    fn selector_rejects_duplicates() {
        assert!(select(&Value::List(vec![fixture(), fixture()])).is_err());
    }
    #[test]
    fn selector_rejects_old_profile() {
        let mut v = fixture();
        if let Value::Dict(m) = &mut v {
            m.insert("bcdDevice".into(), Value::Int(0x026b));
        }
        assert!(select(&v).is_err());
    }
    #[test]
    fn selector_rejects_host_or_dbg() {
        for pid in [0x4070, 0x8010] {
            let other = d(vec![
                ("IOObjectClass", Value::Text("IOUSBHostDevice".into())),
                ("idVendor", Value::Int(0x1a86)),
                ("idProduct", Value::Int(pid)),
            ]);
            assert!(select(&Value::List(vec![fixture(), other])).is_err());
        }
    }
    #[test]
    fn request_only_fixed_points() {
        for p in 0..5 {
            let b = request(2, p, 9, p as u32 + 2).unwrap();
            assert_eq!(b[6], p);
            assert!(b[16..].iter().all(|x| *x == 0));
        }
        assert!(request(2, 5, 9, 2).is_err());
        assert!(request(1, 0, 9, 2).is_err());
        assert!(request(4, 0, 9, 2).is_err());
    }
    #[test]
    fn process_guards() {
        assert!(check_processes("12 /x/wiredkvm-native\n").is_err());
        assert!(check_processes("12 /x/WiredKVM Companion\n").is_err());
        assert!(check_processes("12 /x/macos-capture-foo\n").is_err());
        assert!(check_processes("12 /x/wk-mt2-single-port-probe\n").is_ok());
    }
    #[test]
    fn coordinate_guard() {
        let p = coordinates(0, 1440., 900.).unwrap();
        assert!(position_pass(p, (p.0 + 3., p.1 - 4.)));
        assert!(!position_pass(p, (p.0 + 5., p.1)));
        assert!(!position_pass(p, (f64::NAN, 0.)));
    }
    #[test]
    fn status_rejects_unrelated_and_unsafe() {
        let mut b = [0; 64];
        b[..4].copy_from_slice(b"WKAS");
        b[4] = 1;
        b[5] = 4;
        for (i, n) in [
            (8, 42u32),
            (12, 2),
            (16, 2),
            (20, 2),
            (24, 2),
            (28, 1000),
            (32, 513),
            (40, 7),
        ] {
            b[i..i + 4].copy_from_slice(&n.to_le_bytes());
        }
        let s = Status::parse(&b).unwrap();
        assert!(s.transaction(42, 2, 7).is_ok());
        assert!(s.transaction(42, 1, 7).is_err());
        assert!(s.transaction(43, 2, 7).is_err());
        assert!(s.transaction(42, 2, 8).is_err());
        b[33] |= 1;
        assert!(Status::parse(&b).unwrap().safe().is_err());
    }
    #[test]
    fn malformed_status_rejected() {
        assert!(Status::parse(&[0; 64]).is_err());
        assert!(Status::parse(&[0; 63]).is_err());
    }
    #[test]
    fn staged_previous_status_is_pending_not_success() {
        let mut s = Status {
            phase: 4,
            result: 0,
            point: 0,
            nonce: 42,
            accepted: 2,
            submitted: 2,
            completed: 2,
            received: 2,
            remaining: 2000,
            flags: 513,
            invalidations: 0,
            epoch: 7,
        };
        assert_eq!(s.point_complete(42, 3, 7, 1), Ok(false));
        s.received = 3;
        assert_eq!(s.point_complete(42, 3, 7, 1), Ok(false));
        s.accepted = 3;
        s.point = 1;
        s.phase = 2;
        assert_eq!(s.point_complete(42, 3, 7, 1), Ok(false));
        s.submitted = 3;
        s.completed = 3;
        s.phase = 4;
        assert_eq!(s.point_complete(42, 3, 7, 1), Ok(true));
        s.completed = 4;
        assert!(s.point_complete(42, 3, 7, 1).is_err());
    }
    #[test]
    fn disarm_is_sequenced_and_has_no_point_or_input_payload() {
        for seq in 2..=7 {
            let b = request(3, 0, 42, seq).unwrap();
            assert_eq!(b[5], 3);
            assert_eq!(b[6], 0);
            assert!(b[16..].iter().all(|v| *v == 0));
        }
        assert!(request(3, 1, 42, 2).is_err());
        assert!(request(3, 0, 42, 8).is_err());
    }
    #[test]
    fn disarm_waits_for_hardware_not_only_logical_lease() {
        let mut bytes=[0;64];bytes[..4].copy_from_slice(b"WKAS");bytes[4]=1;
        bytes[32]=8;bytes[33]=2;
        let mut s=Status::parse(&bytes).unwrap();
        assert!(!s.input_idle());assert_eq!(s.disarm_complete(42),Ok(false));
        s.flags &= !8;assert_eq!(s.disarm_complete(42),Ok(true));
        s.nonce=43;assert!(s.disarm_complete(42).is_err());
    }
    #[test]
    fn descriptor_has_unnumbered_feature64() {
        let b = vendor_descriptor();
        assert_eq!(&b[b.len() - 7..], &[0x95, 64, 9, 0x64, 0xb1, 2, 0xc0]);
        assert!(!b.contains(&0x85));
    }

    #[test]
    fn only_reviewed_candidate_can_enable_hardware_entry() {
        assert!(reviewed_firmware(Some(REVIEWED_FIRMWARE_SHA)));
        assert!(!reviewed_firmware(None));
        assert!(!reviewed_firmware(Some("")));
        assert!(!reviewed_firmware(Some("5ab87176db14c1829246d18aa3169bc5afe1b3462282dd080e1a44ed8e3fe03c")));
        let mut changed = REVIEWED_FIRMWARE_SHA.as_bytes().to_vec();
        changed[63] ^= 1;
        assert!(!reviewed_firmware(Some(std::str::from_utf8(&changed).unwrap())));
    }
}
