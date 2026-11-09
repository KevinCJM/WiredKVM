use wiredkvm_cable_image::*;

struct Ram { bytes: Vec<u8>, writes: usize, available: bool, fail: bool }
impl Ram { fn new() -> Self { Self { bytes: vec![0; CAPACITY as usize], writes: 0, available: true, fail: false } } }
impl Memory for Ram {
    fn available(&self) -> bool { self.available }
    fn write_verified(&mut self, offset: u32, bytes: &[u8]) -> bool {
        if self.fail { return false; }
        self.writes += 1; self.bytes[offset as usize..offset as usize+bytes.len()].copy_from_slice(bytes); true
    }
}
fn asset() -> Vec<u8> {
    let image: Vec<_> = (0..6144).map(|n| n as u8).collect();
    let mut a = vec![255; IMAGE_OFFSET as usize]; a[..8].copy_from_slice(b"WKDUAL01");
    a[8..12].copy_from_slice(&1u32.to_le_bytes()); a[12..16].copy_from_slice(&(image.len() as u32).to_le_bytes());
    a[16..20].copy_from_slice(&crc32(&image).to_le_bytes());
    let check=crc32(&a[..20]); a[20..24].copy_from_slice(&check.to_le_bytes()); a.extend(image); a
}
fn frame(op: u8, nonce: u64, offset: u32, a: &[u8], body: &[u8]) -> [u8; CELL] {
    Frame { operation: op, session: nonce, offset, total: a.len() as u32, checksum: crc32(a), body }.encode().unwrap()
}
fn fill(u: &mut Upload, m: &mut Ram, a: &[u8], nonce: u64) {
    assert_eq!(u.accept(0,&frame(BEGIN,nonce,0,a,&[]),m).code,Code::Accepted);
    for (i, b) in a.chunks(BODY).enumerate() {
        assert_eq!(u.accept(0,&frame(DATA,nonce,(i*BODY) as u32,a,b),m).code,Code::Accepted);
    }
}

#[test] fn complete_asset_only_becomes_visible_after_integrity_checks_and_never_changes() {
    assert_eq!(crc32(b"123456789"),0xcbf43926);
    let a=asset(); let mut u=Upload::new();let mut m=Ram::new();fill(&mut u,&mut m,&a,91);
    assert_eq!(u.published_bytes(),None);
    let finish=frame(FINISH,91,a.len() as u32,&a,&[]);
    assert_eq!(u.accept(0,&finish,&mut m).code,Code::Sealed);
    assert_eq!(u.accept(0,&finish,&mut m).code,Code::Sealed);
    assert_eq!(u.published_bytes(),Some(a.len() as u32));assert_eq!(&m.bytes[..a.len()],a);
    u.disconnected();assert!(u.published_bytes().is_some());
    assert_eq!(u.accept(0,&frame(BEGIN,92,0,&a,&[]),&mut m).code,Code::Busy);
    assert_eq!(u.accept(0,&frame(ABORT,91,a.len() as u32,&a,&[]),&mut m).code,Code::Busy);
}
#[test] fn foreign_port_corruption_wrong_offset_and_replay_cannot_write_memory() {
    let a=asset();let mut u=Upload::new();let mut m=Ram::new();let begin=frame(BEGIN,2,0,&a,&[]);
    assert_eq!(u.accept(1,&begin,&mut m).code,Code::Invalid);
    u.accept(0,&begin,&mut m);
    let first=frame(DATA,2,0,&a,&a[..BODY]);u.accept(0,&first,&mut m);let writes=m.writes;
    assert_eq!(u.accept(0,&first,&mut m).code,Code::Accepted);assert_eq!(writes,m.writes);
    assert_eq!(u.accept(0,&frame(DATA,3,BODY as u32,&a,&a[BODY..BODY*2]),&mut m).code,Code::Stale);
    assert_eq!(u.accept(0,&frame(DATA,2,123,&a,&a[..BODY]),&mut m).code,Code::Invalid);
    let mut bad=first;bad[40]^=1;assert_eq!(u.accept(0,&bad,&mut m).code,Code::Invalid);
    assert_eq!(writes,m.writes);assert_eq!(u.published_bytes(),None);
}
#[test] fn disconnect_storage_fault_and_abort_allow_immediate_new_upload() {
    let a=asset();let mut u=Upload::new();let mut m=Ram::new();u.accept(0,&frame(BEGIN,1,0,&a,&[]),&mut m);
    u.disconnected();assert_eq!(u.accept(0,&frame(BEGIN,2,0,&a,&[]),&mut m).code,Code::Accepted);
    m.fail=true;assert_eq!(u.accept(0,&frame(DATA,2,0,&a,&a[..BODY]),&mut m).code,Code::Storage);m.fail=false;
    assert_eq!(u.accept(0,&frame(BEGIN,3,0,&a,&[]),&mut m).code,Code::Accepted);
    assert_eq!(u.accept(0,&frame(ABORT,3,0,&a,&[]),&mut m).code,Code::Accepted);
    fill(&mut u,&mut m,&a,4);assert_eq!(u.accept(0,&frame(FINISH,4,a.len() as u32,&a,&[]),&mut m).code,Code::Sealed);
}
#[test] fn malformed_inner_image_and_unavailable_ram_never_publish() {
    let mut a=asset();a[IMAGE_OFFSET as usize+2]^=1;
    let mut u=Upload::new();let mut m=Ram::new();m.available=false;
    assert_eq!(u.accept(0,&frame(BEGIN,1,0,&a,&[]),&mut m).code,Code::Unavailable);m.available=true;
    fill(&mut u,&mut m,&a,2);assert_eq!(u.accept(0,&frame(FINISH,2,a.len() as u32,&a,&[]),&mut m).code,Code::Integrity);
    assert_eq!(u.published_bytes(),None);
}
