#![no_std]
//! Experimental fixed-point probe. One polling owner; no allocation or I/O.
//! The dependency retains the existing MT2 ABI without changing its source.
pub use wiredkvm_mt2_protocol_draft as mt2;
#[cfg(not(target_os = "none"))]
extern crate std;

const LEASE_MS: u32 = 5000;
pub const HOST: u32 = 1;
const TARGET: u32 = 2;
pub const NORMAL_BUSY: u32 = 4;
pub const HELD: u32 = 8;
const OK: u8 = 0;
const INVALID: u8 = 1;
const BUSY: u8 = 2;
const UNSAFE: u8 = 3;
const NONCE: u8 = 4;
const SEQUENCE: u8 = 5;
const EXPIRED: u8 = 6;
const LIFECYCLE: u8 = 7;

#[derive(Clone, Copy, Debug, PartialEq)]
struct Request { op: u8, point: u8, nonce: u32, seq: u32 }
fn read32(b: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([b[offset], b[offset+1], b[offset+2], b[offset+3]])
}
fn put32(b: &mut [u8], offset: usize, value: u32) {
    b[offset..offset+4].copy_from_slice(&value.to_le_bytes());
}
impl Request {
    fn parse(b: &[u8]) -> Option<Self> {
        if b.len()!=64 || &b[..4]!=b"WKAP" || b[4]!=1 || b[7]!=0 || b[16..].iter().any(|v| *v!=0) { return None; }
        let r=Self { op:b[5], point:b[6], nonce:read32(b,8), seq:read32(b,12) };
        if r.nonce==0 || r.seq==0 || !(1..=3).contains(&r.op) || r.point>4 ||
            (r.op!=2 && r.point!=0) || (r.op==1 && r.seq!=1) { return None; }
        Some(r)
    }
}

struct Probe {
    stage: Option<Request>, last: Option<Request>, armed: bool,
    queued: bool, flight: bool, revoke: bool, quiescing: bool, nonce: u32, retired: u32,
    began: u32, now: u32, guards: u32, epoch: u32, invalidations: u32,
    accepted: u32, submitted: u32, completed: u32, received: u32,
    point: u8, result: u8,
}
impl Probe {
    const fn new() -> Self { Self { stage:None,last:None,armed:false,queued:false,flight:false,revoke:false,quiescing:false,
        nonce:0,retired:0,began:0,now:0,guards:0,epoch:0,invalidations:0,
        accepted:0,submitted:0,completed:0,received:0,point:255,result:OK } }
    fn invalidate(&mut self, why: u8) {
        self.revoke |= self.flight;
        if self.nonce!=0 { self.retired=self.nonce; }
        self.stage=None; self.last=None; self.armed=false; self.queued=false; self.flight=false;
        self.nonce=0; self.epoch=self.epoch.wrapping_add(1);
        self.invalidations=self.invalidations.wrapping_add(1); self.result=why;
    }
    // EP0 may validate and stage. It cannot arm, queue or submit a HID report.
    fn stage(&mut self, bytes: &[u8]) -> bool {
        let Some(r)=Request::parse(bytes) else { self.result=INVALID; return false; };
        self.received=r.seq;
        if let Some(p)=self.stage {
            if p==r { return true; }
            self.result=BUSY; return false;
        }
        self.stage=Some(r); true
    }
    fn poll(&mut self, now: u32, guards: u32) -> bool {
        self.now=now; self.guards=guards;
        let safe=guards==TARGET && !self.quiescing;
        if self.armed && !safe { self.invalidate(UNSAFE); }
        else if self.armed && now.wrapping_sub(self.began)>=LEASE_MS { self.invalidate(EXPIRED); }
        if let Some(r)=self.stage.take() {
            if !safe { self.result=UNSAFE; }
            else if self.last==Some(r) { self.result=OK; } // exact repeat never moves or renews lease
            else if r.op==1 {
                if self.armed || self.flight || self.queued { self.result=BUSY; }
                else if r.nonce==self.retired { self.result=NONCE; }
                else {
                    self.epoch=self.epoch.wrapping_add(1); self.nonce=r.nonce; self.began=now;
                    self.armed=true; self.accepted=1; self.submitted=0; self.completed=0;
                    self.point=255; self.last=Some(r); self.result=OK;
                }
            } else if !self.armed || r.nonce!=self.nonce { self.result=NONCE; }
            else if r.seq!=self.accepted+1 { self.result=SEQUENCE; }
            else if r.op==3 {
                // A correct DISARM cancels even a submitted, uncompleted point.
                self.accepted=r.seq; self.invalidate(OK); self.last=Some(r);
            } else if self.queued || self.flight { self.result=BUSY; }
            else if r.seq>6 { self.result=SEQUENCE; }
            else { self.point=r.point; self.accepted=r.seq; self.queued=true; self.last=Some(r); self.result=OK; }
        }
        let revoke=self.revoke; self.revoke=false; revoke
    }
    fn prepare(&self) -> Option<[u8;8]> {
        if !self.armed || !self.queued || self.flight || self.quiescing || self.guards!=TARGET { return None; }
        let (x,y): (u16,u16)=match self.point { 0=>(16384,16384),1=>(8192,8192),2=>(24576,8192),3=>(8192,24576),4=>(24576,24576),_=>return None };
        let [xl,xh]=x.to_le_bytes(); let [yl,yh]=y.to_le_bytes();
        Some([3,0,xl,xh,yl,yh,0,0])
    }
    fn submitted(&mut self) -> Option<(u32,u32)> {
        self.prepare()?; self.queued=false; self.flight=true; self.submitted=self.accepted;
        Some((self.epoch,self.submitted))
    }
    fn complete(&mut self, epoch:u32,seq:u32) {
        if self.armed && self.flight && self.epoch==epoch && self.submitted==seq {
            self.completed=seq; self.flight=false;
        }
    }
    fn status(&self, now:u32) -> [u8;64] {
        let mut b=[0u8;64]; b[..4].copy_from_slice(b"WKAS"); b[4]=1;
        b[5]=if !self.armed {0} else if self.flight {3} else if self.queued {2} else if self.completed!=0 {4} else {1};
        b[6]=self.result; b[7]=self.point;
        put32(&mut b,8,self.nonce); put32(&mut b,12,self.accepted); put32(&mut b,16,self.submitted);
        put32(&mut b,20,self.completed); put32(&mut b,24,self.received);
        put32(&mut b,28,if self.armed {LEASE_MS.saturating_sub(now.wrapping_sub(self.began))} else {0});
        put32(&mut b,32,(self.armed as u32)|((self.stage.is_some() as u32)<<1)|((self.flight as u32)<<2)|((self.quiescing as u32)<<3)|(self.guards<<8));
        put32(&mut b,36,self.invalidations); put32(&mut b,40,self.epoch); b
    }
}

// ABI is called only by the existing polling owner. No ISR or second thread.
#[cfg(feature="c-abi")]
mod ffi {
    use super::*;
    struct SingleOwner(core::cell::UnsafeCell<Probe>);
    // Existing main-loop owner serializes all calls; no IRQ/thread may enter.
    unsafe impl Sync for SingleOwner {}
    static PROBE: SingleOwner = SingleOwner(core::cell::UnsafeCell::new(Probe::new()));
    unsafe fn state()->&'static mut Probe { &mut *PROBE.0.get() }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_reset() { state().invalidate(LIFECYCLE); }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_stage(p:*const u8,n:usize)->i32 {
        if p.is_null() || n!=64 { return 0; } state().stage(core::slice::from_raw_parts(p,n)) as i32
    }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_poll(now:u32,guards:u32)->i32 { state().poll(now,guards) as i32 }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_quiescing(active:i32) { state().quiescing=active!=0; }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_prepare(p:*mut u8)->i32 {
        if p.is_null() { return 0; } if let Some(b)=state().prepare() { core::ptr::copy_nonoverlapping(b.as_ptr(),p,8); 1 } else {0}
    }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_submitted(epoch:*mut u32,seq:*mut u32)->i32 {
        if epoch.is_null() || seq.is_null() { return 0; }
        if let Some((e,s))=state().submitted() {*epoch=e;*seq=s;1} else {0}
    }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_complete(epoch:u32,seq:u32) { state().complete(epoch,seq); }
    #[no_mangle] pub unsafe extern "C" fn wkap_core_status(now:u32,p:*mut u8) {
        if !p.is_null() { let b=state().status(now);core::ptr::copy_nonoverlapping(b.as_ptr(),p,64); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn req(op:u8,point:u8,nonce:u32,seq:u32)->[u8;64] {
        let mut b=[0;64];b[..4].copy_from_slice(b"WKAP");b[4]=1;b[5]=op;b[6]=point;put32(&mut b,8,nonce);put32(&mut b,12,seq);b
    }
    fn arm(p:&mut Probe,now:u32) { assert!(p.stage(&req(1,0,123,1)));p.poll(now,TARGET);assert!(p.armed); }
    fn point(p:&mut Probe,point:u8,seq:u32,now:u32) { assert!(p.stage(&req(2,point,123,seq)));p.poll(now,TARGET); }
    #[test] fn ep0_stages_only_and_reports_exact_whitelist() {
        let mut p=Probe::new();assert!(p.stage(&req(1,0,123,1)));assert!(!p.armed);assert!(p.prepare().is_none());p.poll(10,TARGET);
        for i in 0..5 { point(&mut p,i,i as u32+2,100+i as u32);let b=p.prepare().unwrap();assert_eq!([b[0],b[1],b[6],b[7]],[3,0,0,0]);let (e,s)=p.submitted().unwrap();assert!(p.prepare().is_none());assert_ne!(p.completed,s);p.complete(e,s);assert_eq!(p.completed,s); }
        point(&mut p,0,7,200);assert_eq!(p.result,SEQUENCE);assert!(p.prepare().is_none());
    }
    #[test] fn duplicates_busy_and_order_do_not_replay() {
        let mut p=Probe::new();arm(&mut p,10);point(&mut p,0,2,20);let token=p.submitted().unwrap();
        point(&mut p,0,2,30);assert_eq!(p.result,OK);assert!(p.flight);assert!(p.prepare().is_none());
        point(&mut p,1,3,40);assert_eq!(p.result,BUSY);assert_eq!(p.accepted,2);
        point(&mut p,2,2,40);assert_eq!(p.result,SEQUENCE);p.complete(token.0,token.1);
        point(&mut p,1,3,50);assert!(p.queued);assert_eq!(p.accepted,3);
        assert!(p.stage(&req(2,2,123,4)));assert!(!p.stage(&req(2,3,123,5)));assert_eq!(p.result,BUSY);
    }
    #[test] fn malformed_or_wrong_nonce_never_queues() {
        let good=req(1,0,123,1);for i in [0,4,7,16,63] {let mut p=Probe::new();let mut b=good;b[i]^=0x80;assert!(!p.stage(&b));assert!(!p.armed);}
        for (op,point,nonce,seq) in [(0,0,1,1),(4,0,1,1),(2,5,1,2),(1,1,1,1),(1,0,0,1),(1,0,1,2),(3,0,1,0)] {assert!(!Probe::new().stage(&req(op,point,nonce,seq)));}
        let mut p=Probe::new();arm(&mut p,0);assert!(p.stage(&req(2,0,124,2)));p.poll(1,TARGET);assert_eq!(p.result,NONCE);assert!(p.prepare().is_none());
    }
    #[test] fn unsafe_guards_clear_pending_and_inflight_and_block_arm() {
        for guards in [0,HOST|TARGET,TARGET|NORMAL_BUSY,TARGET|HELD] {
            let mut p=Probe::new();assert!(p.stage(&req(1,0,123,1)));p.poll(1,guards);assert!(!p.armed);assert_eq!(p.result,UNSAFE);
            arm(&mut p,2);point(&mut p,0,2,3);let token=p.submitted().unwrap();assert!(p.poll(4,guards));assert!(!p.armed);p.complete(token.0,token.1);assert_eq!(p.completed,0);
            assert!(p.stage(&req(1,0,123,1)));p.poll(5,TARGET);assert!(!p.armed);assert_eq!(p.result,NONCE);
        }
    }
    #[test] fn lease_wrap_expiry_and_duplicate_arm_never_extends() {
        let mut p=Probe::new();let start=u32::MAX-20;arm(&mut p,start);
        assert!(p.stage(&req(1,0,123,1)));p.poll(200,TARGET);assert_eq!(p.began,start);
        p.poll(start.wrapping_add(4999),TARGET);assert!(p.armed);assert_eq!(read32(&p.status(start.wrapping_add(4999)),28),1);
        point(&mut p,0,2,start.wrapping_add(4999));p.submitted().unwrap();assert!(p.poll(start.wrapping_add(5000),TARGET));assert!(!p.armed);assert_eq!(p.result,EXPIRED);
    }
    #[test] fn reset_suspend_and_disarm_invalidate_old_completion_epoch() {
        let mut p=Probe::new();arm(&mut p,10);point(&mut p,0,2,11);let old=p.submitted().unwrap();
        p.invalidate(LIFECYCLE);assert!(p.poll(12,TARGET));assert!(p.stage(&req(1,0,456,1)));p.poll(13,TARGET);
        assert!(p.stage(&req(2,1,456,2)));p.poll(14,TARGET);let new=p.submitted().unwrap();assert_ne!(old.0,new.0);
        p.complete(old.0,old.1);assert_eq!(p.completed,0);assert!(p.flight);
        assert!(p.stage(&req(3,0,456,3)));assert!(p.poll(15,TARGET));assert!(!p.armed);p.complete(new.0,new.1);assert_eq!(p.completed,0);
        assert!(p.stage(&req(3,0,456,3)));p.poll(16,TARGET);assert_eq!(p.result,OK);assert!(!p.armed);
    }
    #[test] fn hardware_retirement_is_visible_and_blocks_new_lease() {
        let mut p=Probe::new();arm(&mut p,1);point(&mut p,0,2,2);p.submitted().unwrap();
        assert!(p.stage(&req(3,0,123,3)));assert!(p.poll(3,TARGET));
        p.quiescing=true;assert_eq!(read32(&p.status(3),32)&15,8);
        assert!(p.stage(&req(1,0,456,1)));p.poll(4,TARGET);assert!(!p.armed);assert!(p.prepare().is_none());
        p.invalidate(LIFECYCLE);assert_eq!(read32(&p.status(5),32)&8,8);
        p.quiescing=false;assert!(p.stage(&req(1,0,456,1)));p.poll(6,TARGET);assert!(p.armed);
    }
}
