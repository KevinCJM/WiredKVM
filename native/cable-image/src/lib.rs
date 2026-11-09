#![no_std]
//! Host-to-board volatile program image admission. One polling owner, no heap,
//! loops over at most one USB cell, and no flash erase/program operation.

pub const CELL: usize = 512;
pub const BODY: usize = 476;
pub const CAPACITY: u32 = 4 * 1024 * 1024;
pub const IMAGE_OFFSET: u32 = 4096;
pub const QUERY: u8 = 0;
pub const BEGIN: u8 = 1;
pub const DATA: u8 = 2;
pub const FINISH: u8 = 3;
pub const ABORT: u8 = 4;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code { Accepted, Sealed, Busy, Invalid, Unavailable, Stale, Integrity, Storage }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Reply { pub code: Code, pub session: u64, pub next: u32, pub total: u32, pub checksum: u32 }
impl Reply {
    pub fn encode(&self) -> [u8; CELL] {
        let mut b = [0; CELL]; b[..4].copy_from_slice(b"WKIA"); b[4] = 1; b[5] = self.code as u8;
        b[8..16].copy_from_slice(&self.session.to_le_bytes()); b[16..20].copy_from_slice(&self.next.to_le_bytes());
        b[20..24].copy_from_slice(&self.total.to_le_bytes());
        b[24..28].copy_from_slice(&self.checksum.to_le_bytes());
        let c = crc32(&b[..508]); b[508..].copy_from_slice(&c.to_le_bytes()); b
    }
    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() != CELL || &b[..4] != b"WKIA" || b[4] != 1 || b[6..8] != [0; 2] ||
            b[28..508].iter().any(|&v|v!=0) || crc32(&b[..508]) != u32le(&b[508..]) { return None; }
        let code = match b[5] { 0=>Code::Accepted,1=>Code::Sealed,2=>Code::Busy,3=>Code::Invalid,
            4=>Code::Unavailable,5=>Code::Stale,6=>Code::Integrity,7=>Code::Storage,_=>return None };
        Some(Self { code, session:u64::from_le_bytes(b[8..16].try_into().unwrap()), next:u32le(&b[16..]),total:u32le(&b[20..]),checksum:u32le(&b[24..]) })
    }
}

pub trait Memory {
    fn available(&self) -> bool;
    /// The adapter must bounds-check and read back each write before returning.
    fn write_verified(&mut self, offset: u32, bytes: &[u8]) -> bool;
}

fn u32le(b: &[u8]) -> u32 { u32::from_le_bytes(b[..4].try_into().unwrap()) }
fn update(mut crc: u32, bytes: &[u8]) -> u32 {
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 { crc = (crc >> 1) ^ (0xedb88320 & 0u32.wrapping_sub(crc & 1)); }
    }
    crc
}
pub fn crc32(bytes: &[u8]) -> u32 { !update(u32::MAX, bytes) }

pub struct Frame<'a> {
    pub operation: u8, pub session: u64, pub offset: u32,
    pub total: u32, pub checksum: u32, pub body: &'a [u8],
}
impl Frame<'_> {
    pub fn encode(&self) -> Option<[u8; CELL]> {
        if self.body.len() > BODY || self.operation > ABORT { return None; }
        let mut b = [0u8; CELL]; b[..4].copy_from_slice(b"WKIM"); b[4] = 1; b[5] = self.operation;
        b[8..16].copy_from_slice(&self.session.to_le_bytes());
        b[16..20].copy_from_slice(&self.offset.to_le_bytes());
        b[20..24].copy_from_slice(&self.total.to_le_bytes());
        b[24..28].copy_from_slice(&self.checksum.to_le_bytes());
        b[28..30].copy_from_slice(&(self.body.len() as u16).to_le_bytes());
        b[32..32+self.body.len()].copy_from_slice(self.body);
        let checksum = crc32(&b[..508]); b[508..].copy_from_slice(&checksum.to_le_bytes()); Some(b)
    }
    pub fn decode(b: &[u8]) -> Option<Frame<'_>> {
        if b.len() != CELL || &b[..4] != b"WKIM" || b[4] != 1 || b[5] > ABORT ||
            b[6..8] != [0; 2] || b[30..32] != [0; 2] || crc32(&b[..508]) != u32le(&b[508..]) { return None; }
        let n = usize::from(u16::from_le_bytes(b[28..30].try_into().unwrap()));
        if n > BODY || b[32+n..508].iter().any(|&v| v != 0) { return None; }
        Some(Frame { operation: b[5], session: u64::from_le_bytes(b[8..16].try_into().unwrap()),
            offset: u32le(&b[16..]), total: u32le(&b[20..]), checksum: u32le(&b[24..]), body: &b[32..32+n] })
    }
}

pub struct Upload {
    session: u64, total: u32, next: u32, expected: u32, crc: u32, payload_crc: u32,
    header: [u8; 24], sealed: bool, last_offset: u32, last_tag: u32,
}
impl Default for Upload { fn default() -> Self { Self::new() } }
impl Upload {
    pub const fn new() -> Self {
        Self { session: 0, total: 0, next: 0, expected: 0, crc: u32::MAX, payload_crc: u32::MAX,
               header: [0; 24], sealed: false, last_offset: u32::MAX, last_tag: 0 }
    }
    pub fn published_bytes(&self) -> Option<u32> { if self.sealed { Some(self.total) } else { None } }
    /// A disconnected uploader cannot leave a partial program visible. A sealed
    /// source volume stays immutable until the board loses power.
    pub fn disconnected(&mut self) { if !self.sealed { *self = Self::new(); } }
    fn reply(&self, code: Code) -> Reply { Reply { code, session: self.session, next: self.next, total: self.total, checksum: self.expected } }
    pub fn accept(&mut self, port: u8, cell: &[u8], memory: &mut impl Memory) -> Reply {
        if port != 0 { return self.reply(Code::Invalid); }
        let Some(f) = Frame::decode(cell) else { return self.reply(Code::Invalid); };
        if !memory.available() { return self.reply(Code::Unavailable); }
        if f.operation == QUERY {
            if f.offset != 0 || f.total != 0 || f.checksum != 0 || !f.body.is_empty() { return self.reply(Code::Invalid); }
            return self.reply(if self.sealed { Code::Sealed } else { Code::Accepted });
        }
        if f.session == 0 { return self.reply(Code::Invalid); }
        if f.operation == BEGIN {
            if !f.body.is_empty() || f.offset != 0 || f.total <= IMAGE_OFFSET || f.total > CAPACITY ||
                (f.total-IMAGE_OFFSET) % 512 != 0 { return self.reply(Code::Invalid); }
            if self.sealed || (self.session != 0 && (self.session != f.session || self.total != f.total || self.expected != f.checksum)) {
                return self.reply(Code::Busy);
            }
            if self.session == 0 {
                *self = Self::new(); self.session = f.session; self.total = f.total; self.expected = f.checksum;
            }
            return self.reply(Code::Accepted);
        }
        if self.session == 0 || f.session != self.session || f.total != self.total || f.checksum != self.expected {
            return self.reply(Code::Stale);
        }
        if self.sealed { return self.reply(if f.operation == FINISH && f.offset == self.total && f.body.is_empty() { Code::Sealed } else { Code::Busy }); }
        if f.operation == ABORT {
            if !f.body.is_empty() || f.offset != self.next { return self.reply(Code::Invalid); }
            *self = Self::new(); return self.reply(Code::Accepted);
        }
        if f.operation == DATA {
            if f.body.is_empty() { return self.reply(Code::Invalid); }
            let tag = u32le(&cell[508..]);
            if f.offset == self.last_offset && tag == self.last_tag { return self.reply(Code::Accepted); }
            if f.offset != self.next || f.body.len() as u32 > self.total-self.next { return self.reply(Code::Invalid); }
            if !memory.write_verified(self.next, f.body) {
                self.disconnected(); return self.reply(Code::Storage);
            }
            if self.next < 24 {
                let n = core::cmp::min(f.body.len(), 24-self.next as usize);
                self.header[self.next as usize..self.next as usize+n].copy_from_slice(&f.body[..n]);
            }
            self.crc = update(self.crc, f.body);
            let skip = IMAGE_OFFSET.saturating_sub(self.next) as usize;
            if skip < f.body.len() { self.payload_crc = update(self.payload_crc, &f.body[skip..]); }
            self.last_offset = self.next; self.last_tag = tag; self.next += f.body.len() as u32;
            return self.reply(Code::Accepted);
        }
        if f.operation == FINISH && f.body.is_empty() && f.offset == self.next && self.next == self.total {
            let h = &self.header;
            if !self.crc != self.expected || &h[..8] != b"WKDUAL01" || u32le(&h[8..]) != 1 ||
                u32le(&h[12..]) != self.total-IMAGE_OFFSET || u32le(&h[16..]) != !self.payload_crc ||
                u32le(&h[20..]) != crc32(&h[..20]) {
                self.disconnected(); return self.reply(Code::Integrity);
            }
            self.sealed = true; return self.reply(Code::Sealed);
        }
        self.reply(Code::Invalid)
    }
}
