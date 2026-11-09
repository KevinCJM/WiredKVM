//! Bounded, identity-guarded USB/RCC observation. No Program::ReadMemory.
use anyhow::{Result, bail, ensure};
use nusb::MaybeFuture;
use serde_json::{Value, json};
use std::{env, fs::OpenOptions, io::Write, path::PathBuf, thread, time::{Duration, Instant}};
use wlink::{RiscvChip, commands::{self, Speed}, dmi::DebugModuleInterface,
            operations::ProbeSession, probe::{WchLink, WchLinkVariant}, regs::Dmstatus};

const SERIAL: &str = "A47C8F062A1A";
const CHIP_ID: u32 = 0x46740011;
const REGIONS: [(&str, u32, u32); 3] = [
    ("rcc", 0x40021000, 0x34),
    ("usbhs1_device", 0x40024000, 0x14),
    ("usbhs2_device", 0x40023400, 0x14),
];
const SAVED: [(bool, u16, &str); 4] = [
    (false, 0x1005, "x5"), (false, 0x1006, "x6"),
    (true, 0x20, "progbuf0"), (true, 0x21, "progbuf1"),
];

fn plan() -> Value {
    json!({"dry_run": true, "device_access": false,
        "probe": {"vid": "1a86", "pid": "8010", "serial": SERIAL},
        "expected_chip": "CH32V4X7 / 0x46740011",
        "expected_uid": "ad21ad506c54c6c6",
        "uid_verification": "not performed; independent identity evidence required",
        "regions_in_read_order": REGIONS.map(|(name, address, bytes)| json!({"name":name,"address":format!("0x{address:08x}"),"bytes":bytes})),
        "limits": ["AttachChip and halt can disturb the USB host's timing/state", "No reset, flash, Program::ReadMemory, GetChipInfo, or peripheral writes", "DMI loads use x5/x6 and progbuf0/1; save, restore, and verify before resume", "Resume and detach attempted on every ordinary error; disconnected probe or killed process can prevent cleanup", "Underlying USB API may block despite bounded DMI polling", "Does not stop live control applications; operator must do preflight"]})
}

fn verify_probe_list() -> Result<String> {
    let devices: Vec<_> = nusb::list_devices().wait()?
        .filter(|d| d.vendor_id() == 0x1a86 && d.product_id() == 0x8010).collect();
    ensure!(devices.len() == 1, "Expected exactly one 1a86:8010 probe, got {}", devices.len());
    ensure!(devices[0].serial_number() == Some(SERIAL), "Probe serial mismatch");
    Ok(format!("{:?}", devices[0].id()))
}

fn wait_dm(s: &mut ProbeSession, predicate: impl Fn(Dmstatus) -> bool, what: &str) -> Result<u32> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let raw = s.probe.dmi_read(0x11)?;
        if predicate(Dmstatus::from(raw)) { return Ok(raw); }
        if Instant::now() >= deadline { bail!("DMI {what} timed out: status=0x{raw:08x}"); }
        thread::sleep(Duration::from_millis(10));
    }
}

trait SavedRegisters {
    fn read_saved(&mut self, dmi: bool, register: u16) -> Result<u32>;
    fn write_saved(&mut self, dmi: bool, register: u16, value: u32) -> Result<()>;
}
impl SavedRegisters for ProbeSession {
    fn read_saved(&mut self, dmi: bool, r: u16) -> Result<u32> {
        Ok(if dmi { self.probe.dmi_read(r as u8)? } else { self.read_reg(r)? })
    }
    fn write_saved(&mut self, dmi: bool, r: u16, v: u32) -> Result<()> {
        if dmi { self.probe.dmi_write(r as u8, v)?; } else { self.write_reg(r, v)?; }
        Ok(())
    }
}

fn restore_and_verify(s: &mut impl SavedRegisters, saved: &[(bool, u16, &'static str, u32)]) -> Vec<String> {
    let mut errors = vec![];
    // Try all restores even if one fails. No peripheral memory is written.
    for &(dmi, r, name, v) in saved {
        if let Err(e) = s.write_saved(dmi, r, v) { errors.push(format!("restore {name}: {e}")); }
    }
    for &(dmi, r, name, v) in saved {
        match s.read_saved(dmi, r) {
            Ok(actual) if actual == v => (),
            Ok(actual) => errors.push(format!("verify {name}: expected {v:#x}, got {actual:#x}")),
            Err(e) => errors.push(format!("verify {name}: {e}")),
        }
    }
    errors
}

struct SessionGuard {
    session: ProbeSession,
    attached_attempted: bool,
    saved: Vec<(bool, u16, &'static str, u32)>,
    finished: bool,
}
impl SessionGuard {
    fn finish(&mut self) -> Value {
        if self.finished { return json!({"already_finished":true}); }
        let mut errors = restore_and_verify(&mut self.session, &self.saved);
        let restored = errors.is_empty();
        // Explicit bounded handshake; wlink ensure_mcu_resume can return Ok after failure.
        let resume = (|| -> Result<u32> {
            self.session.probe.dmi_write(0x10, 0x10000001)?; // acknowledge reset, clear halt request
            self.session.probe.dmi_write(0x10, 0x40000001)?; // resume request, not reset
            let status = wait_dm(&mut self.session, |d| d.allrunning() && d.anyrunning(), "resume")?;
            self.session.probe.dmi_write(0x10, 0x00000001)?;
            Ok(status)
        })();
        if let Err(ref e) = resume { errors.push(format!("resume: {e}")); }
        let detach = self.session.detach_chip();
        if let Err(e) = detach { errors.push(format!("detach: {e}")); }
        self.finished = true;
        json!({"registers_restored_and_verified":restored,
            "running_verified_before_detach":resume.is_ok(),
            "dmstatus_after_resume":resume.ok().map(|v|format!("0x{v:08x}")),
            "errors":errors})
    }
}
impl Drop for SessionGuard {
    fn drop(&mut self) {
        if self.attached_attempted && !self.finished { eprintln!("Emergency cleanup: {}", self.finish()); }
    }
}

fn collect(guard: &mut SessionGuard, report: &mut Value) -> Result<()> {
    let s = &mut guard.session;
    let speed_ok = s.probe.send_command(commands::SetSpeed { riscvchip:RiscvChip::CH32V4X7 as u8, speed:Speed::High })?;
    ensure!(speed_ok, "Probe rejected debug speed");
    guard.attached_attempted = true;
    let chip = s.probe.send_command(commands::control::AttachChip)?;
    report["attached_chip"] = json!({"family":format!("{:?}",chip.chip_family),"chip_id":format!("0x{:08x}",chip.chip_id)});
    ensure!(chip.chip_family == RiscvChip::CH32V4X7 && chip.chip_id == CHIP_ID, "Chip identity mismatch");
    // CH32V4X7 do_post_init is a no-op. No QueryInfo / Program read is used.
    s.probe.dmi_write(0x10, 0x80000001)?;
    report["dmstatus_after_halt"] = json!(format!("0x{:08x}",wait_dm(s,|d|d.allhalted() && d.anyhalted(),"halt")?));
    s.probe.dmi_write(0x10, 0x00000001)?;
    ensure!(s.probe.dmi_read(0x18)? == 0, "abstractauto was enabled; refuse read-side autoexecution");
    for (dmi, r, name) in SAVED {
        guard.saved.push((dmi,r,name,s.read_saved(dmi,r)?));
    }
    let mut regions = vec![];
    for (name,address,len) in REGIONS {
        let mut words = vec![];
        // Incremental report preserves completed regions after an error.
        for offset in (0..len).step_by(4) {
            let value = s.read_mem32(address+offset)?;
            let acs = s.probe.dmi_read(0x16)?;
            ensure!(acs & 0x1700 == 0, "abstract command busy/error after {:#x}: {:#x}",address+offset,acs);
            words.push(json!({"address":format!("0x{:08x}",address+offset),"value":format!("0x{value:08x}")}));
        }
        regions.push(json!({"name":name,"address":format!("0x{address:08x}"),"bytes":len,"words":words}));
        report["regions"] = json!(regions);
    }
    for (name,reg) in [("dpc",0x7b1),("mepc",0x341),("mcause",0x342),("mtval",0x343)] {
        report["core"][name]=json!(format!("0x{:08x}",s.read_reg(reg)?));
    }
    Ok(())
}

fn run() -> Result<()> {
    let mut args=env::args().skip(1);
    let mut dry=false; let mut out=None;
    while let Some(a)=args.next() {
        match a.as_str() {
            "--dry-run" => dry=true,
            "--out" => out=Some(PathBuf::from(args.next().ok_or_else(||anyhow::anyhow!("--out needs a new path"))?)),
            "--help"|"-h" => {println!("ch32-dmi-snapshot --dry-run [--out NEW.json]\nch32-dmi-snapshot --out NEW.json\nHardware mode halts/resumes the identified board. Requires current operator approval.");return Ok(());},
            _ => bail!("Unknown argument {a}"),
        }
    }
    let mut report=plan();
    // Reserve output before any hardware access; never overwrite old evidence.
    let mut file=if let Some(path)=out { Some(OpenOptions::new().write(true).create_new(true).open(path)?) }
        else { ensure!(dry,"Hardware mode requires --out NEW.json");None };
    if dry {
        let encoded=serde_json::to_string_pretty(&report)?;
        if let Some(f)=&mut file {writeln!(f,"{encoded}")?;}
        println!("{encoded}"); return Ok(());
    }
    report["dry_run"]=json!(false); report["device_access"]=json!(true);
    let operation=(|| -> Result<()> {
        let id=verify_probe_list()?;
        let probe=WchLink::open_nth(0)?;
        ensure!(verify_probe_list()? == id,"USB identity changed during open");
        ensure!(matches!(probe.info.variant,WchLinkVariant::ECh32v305),"Expected WCH-LinkE");
        let mut guard=SessionGuard {session:ProbeSession {probe,chip_family:RiscvChip::CH32V4X7,speed:Speed::High},attached_attempted:false,saved:vec![],finished:false};
        let result=collect(&mut guard,&mut report);
        if guard.attached_attempted {report["cleanup"]=guard.finish();}
        else {guard.finished=true;}
        result?;
        ensure!(report["cleanup"]["errors"].as_array().is_some_and(|v|v.is_empty()),"Cleanup was not fully verified");
        Ok(())
    })();
    report["success"]=json!(operation.is_ok());
    if let Err(ref e)=operation {report["error"]=json!(format!("{e:#}"));}
    let encoded=serde_json::to_string_pretty(&report)?;
    if let Some(f)=&mut file {writeln!(f,"{encoded}")?;f.sync_all()?;}
    println!("{encoded}"); operation
}
fn main(){if let Err(e)=run(){eprintln!("{e:#}");std::process::exit(1);}}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fake { writes:Vec<u16>,fail:Option<u16> }
    impl SavedRegisters for Fake {
        fn read_saved(&mut self,_:bool,r:u16)->Result<u32>{if self.fail==Some(r){bail!("failed")}Ok(r as u32)}
        fn write_saved(&mut self,_:bool,r:u16,_:u32)->Result<()>{self.writes.push(r);if self.fail==Some(r){bail!("failed")}Ok(())}
    }
    #[test] fn restore_attempts_every_register_despite_failure(){
        let saved:Vec<_>=SAVED.map(|(d,r,n)|(d,r,n,r as u32)).into();
        let mut f=Fake{writes:vec![],fail:Some(0x1005)};
        let e=restore_and_verify(&mut f,&saved);
        assert_eq!(f.writes,vec![0x1005,0x1006,0x20,0x21]); assert_eq!(e.len(),2);
    }
    #[test] fn clean_restore_verifies_all(){
        let saved:Vec<_>=SAVED.map(|(d,r,n)|(d,r,n,r as u32)).into();
        let mut f=Fake{writes:vec![],fail:None}; assert!(restore_and_verify(&mut f,&saved).is_empty());
    }
    #[test] fn reads_are_aligned_and_do_not_include_fifos(){
        assert_eq!(REGIONS[0].0,"rcc");
        for (_,base,len) in REGIONS {assert_eq!(base%4,0);assert_eq!(len%4,0);assert!(len<=0x34);}
    }
}
