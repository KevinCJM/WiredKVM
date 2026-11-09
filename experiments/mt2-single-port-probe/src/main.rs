use std::{
    io::{Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant, SystemTime},
};
use wk_mt2_single_port_probe::*;
#[cfg(target_os = "macos")]
mod mac;
static INTERRUPTED: AtomicBool = AtomicBool::new(false);
extern "C" fn interrupted(_: i32) {
    INTERRUPTED.store(true, Ordering::Relaxed);
}
#[cfg(unix)]
extern "C" {
    fn signal(sig: i32, handler: usize) -> usize;
}
fn check_interrupt() -> Result<()> {
    require(
        !INTERRUPTED.load(Ordering::Relaxed),
        "Interrupted; stopping probe",
    )
}
#[derive(Clone)]
struct Args {
    execute: bool,
    worker: bool,
    proof: Option<PathBuf>,
    association: String,
    out: Option<PathBuf>,
    parent: Option<u32>,
}
fn args() -> Result<Args> {
    let mut a = Args {
        execute: false,
        worker: false,
        proof: None,
        association: String::new(),
        out: None,
        parent: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(s) = it.next() {
        match s.as_str(){"--execute"=>a.execute=true,"--dry-run"=>{},"--worker"=>a.worker=true,"--flash-proof"=>a.proof=Some(it.next().ok_or("Missing proof path")?.into()),"--same-board"=>a.association=it.next().ok_or("Missing association")?,"--out"=>a.out=Some(it.next().ok_or("Missing output path")?.into()),"--parent-pid"=>a.parent=Some(it.next().ok_or("Missing parent pid")?.parse().map_err(|_|"Bad parent pid")?),"--help"=>return Err("Default: offline plan only. Execute requires --execute --flash-proof PATH --same-board A47C8F062A1A/ad21ad506c54c6c6. Optional --out NEW.json. Never stops controller or flashes firmware.".into()),_=>return Err(format!("Unknown argument: {s}"))}
    }
    require(!a.worker || a.execute, "Worker cannot run in dry-run mode")?;
    Ok(a)
}
// Drain pipes concurrently: a verbose child must not deadlock while parent waits.
// All external processes are bounded and killed/reaped on timeout or interruption.
fn bounded(
    mut cmd: Command,
    input: Option<Vec<u8>>,
    limit: Duration,
    maximum: usize,
) -> Result<Vec<u8>> {
    check_interrupt()?;
    cmd.stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        });
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Cannot spawn command: {e}"))?;
    let out = child.stdout.take().unwrap();
    let err = child.stderr.take().unwrap();
    let reader = move |p: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut b = vec![];
            p.take((maximum + 1) as u64).read_to_end(&mut b).map(|_| b)
        })
    };
    let stdout = reader(Box::new(out));
    let stderr = reader(Box::new(err));
    let writer = if let Some(bytes) = input {
        let mut pipe = child.stdin.take().unwrap();
        Some(std::thread::spawn(move || pipe.write_all(&bytes)))
    } else {
        None
    };
    let start = Instant::now();
    let status = loop {
        if INTERRUPTED.load(Ordering::Relaxed) || start.elapsed() > limit {
            let _ = child.kill();
            let _ = child.wait();
            break Err("Subprocess timed out or interrupted".to_string());
        }
        match child.try_wait() {
            Ok(Some(s)) => break Ok(s),
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(e.to_string());
            }
        }
    };
    let o = stdout
        .join()
        .map_err(|_| "Output reader panicked")?
        .map_err(|e| e.to_string())?;
    let e = stderr
        .join()
        .map_err(|_| "Error reader panicked")?
        .map_err(|e| e.to_string())?;
    if let Some(w) = writer {
        let _ = w.join();
    }
    let status = status?;
    require(
        o.len() <= maximum && e.len() <= maximum,
        "Subprocess output exceeded bound",
    )?;
    require(
        status.success(),
        &format!(
            "Subprocess failed: {} {}",
            String::from_utf8_lossy(&o),
            String::from_utf8_lossy(&e)
        ),
    )?;
    Ok(o)
}
#[cfg(target_os = "macos")]
fn registry() -> Result<Identity> {
    let mut c = Command::new("/usr/sbin/ioreg");
    c.args(["-r", "-c", "IOUSBHostDevice", "-l", "-w", "0", "-a"]);
    select(&mac::parse_plist(&bounded(
        c,
        None,
        Duration::from_secs(5),
        16 * 1024 * 1024,
    )?)?)
}
#[cfg(target_os = "macos")]
fn no_controller() -> Result<()> {
    let mut c = Command::new("/bin/ps");
    c.args(["-axo", "pid=,comm="]);
    let p = bounded(c, None, Duration::from_secs(2), 1024 * 1024)?;
    check_processes(std::str::from_utf8(&p).map_err(|_| "Invalid process names")?)
}
#[cfg(target_os = "macos")]
fn proof(a: &Args) -> Result<()> {
    let path = a.proof.as_ref().ok_or("--flash-proof required")?;
    let meta = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    require(
        meta.is_file() && meta.len() <= 65536,
        "Proof must be a bounded regular file, not symlink",
    )?;
    let modified = meta.modified().map_err(|e| e.to_string())?;
    let age = match SystemTime::now().duration_since(modified) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    };
    let raw = std::fs::read(path).map_err(|e| e.to_string())?;
    require(raw.len() <= 65536, "Proof grew")?;
    let mut c = Command::new("/usr/bin/plutil");
    c.args(["-convert", "xml1", "-o", "-", "--", "-"]);
    let xml = bounded(c, Some(raw), Duration::from_secs(2), 256 * 1024)?;
    validate_proof(&mac::parse_plist(&xml)?, age, &a.association)
}
#[cfg(target_os = "macos")]
fn worker(a: &Args) -> Result<String> {
    extern "C" {
        fn getppid() -> i32;
    }
    require(
        a.parent == Some(unsafe { getppid() } as u32) && a.parent != Some(1),
        "Worker must be supervised by the probe parent",
    )?;
    proof(a)?;
    no_controller()?;
    let identity = registry()?;
    let layout = mac::layout()?;
    mac::buttons_up()?;
    let hid = mac::Hid::open(&identity)?;
    let initial = hid.status()?;
    initial.safe()?;
    require(
        initial.input_idle(),
        "Existing probe lease/pending report",
    )?;
    require(registry()? == identity, "Target re-enumerated before ARM")?;
    no_controller()?;
    let mut random = [0u8; 4];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut random))
        .map_err(|e| e.to_string())?;
    let nonce = u32::from_le_bytes(random).max(1);
    let mut accepted = 1u32;
    let mut lease_started = false;
    let mut rows = vec![];
    let mut last_status = initial.evidence();
    let operation = (|| -> Result<()> {
        lease_started = true;
        hid.set(&request(1, 0, nonce, 1)?)?;
        let deadline = Instant::now() + Duration::from_millis(650);
        let armed = loop {
            check_interrupt()?;
            let s = hid.status()?;
            last_status = s.evidence();
            s.safe()?;
            require(s.nonce == 0 || s.nonce == nonce, "ARM unrelated lease")?;
            if s.nonce == nonce {
                require(s.result == 0, "ARM rejected")?;
            }
            if s.nonce == nonce
                && s.accepted == 1
                && s.received == 1
                && s.flags & 1 != 0
                && s.remaining > 0
            {
                break s;
            }
            require(Instant::now() < deadline, "ARM acceptance timeout")?;
            std::thread::sleep(Duration::from_millis(10));
        };
        let epoch = armed.epoch;
        for point in 0..5 {
            check_interrupt()?;
            no_controller()?;
            require(mac::layout()? == layout, "Display changed")?;
            mac::buttons_up()?;
            let seq = point as u32 + 2;
            hid.set(&request(2, point as u8, nonce, seq)?)?;
            let until = Instant::now() + Duration::from_millis(650);
            loop {
                check_interrupt()?;
                let s = hid.status()?;
                last_status = s.evidence();
                if s.point_complete(nonce, seq, epoch, point as u8)? {
                    accepted = seq;
                    break;
                }
                require(Instant::now() < until, "Point completion timeout")?;
                std::thread::sleep(Duration::from_millis(10));
            }
            std::thread::sleep(Duration::from_millis(70));
            mac::buttons_up()?;
            let observed = mac::position()?;
            let expected = coordinates(point, layout.width, layout.height)?;
            rows.push(format!("{{\"point\":{point},\"sequence\":{seq},\"expected\":[{},{}],\"observed\":[{},{}]}}",expected.0,expected.1,observed.x,observed.y));
            require(
                position_pass(expected, (observed.x, observed.y)),
                "Absolute coordinate mismatch; stopped further points",
            )?;
        }
        Ok(())
    })();
    // DISARM only our nonce. If a SET response was lost, read accepted sequence first.
    let cleanup = if lease_started {
        (|| -> Result<()> {
            let s = hid.status()?;
            if s.nonce == nonce && s.flags & 1 != 0 {
                accepted = s.accepted;
                hid.set(&request(3, 0, nonce, accepted + 1)?)?;
            }
            let deadline = Instant::now() + Duration::from_millis(650);
            loop {
                let done = hid.status()?;
                last_status = done.evidence();
                if done.disarm_complete(nonce)? {
                    break;
                }
                require(Instant::now() < deadline, "DISARM left pending input")?;
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(())
        })()
    } else {
        Ok(())
    };
    if let Err(error) = operation {
        return Err(format!("{error}; cleanup={cleanup:?}; evidence={{\"points\":[{}],\"last_status\":{last_status}}}",rows.join(",")));
    }
    if let Err(error) = cleanup {
        return Err(format!(
            "{error}; evidence={{\"points\":[{}],\"last_status\":{last_status}}}",
            rows.join(",")
        ));
    }
    require(registry()? == identity, "Target changed after probe")?;
    Ok(format!("{{\"status\":\"five_absolute_points_passed\",\"scope\":\"position only, not gestures or edge return\",\"points\":[{}]}}",rows.join(",")))
}
#[cfg(target_os = "macos")]
fn execute(a: &Args) -> Result<String> {
    proof(a)?;
    no_controller()?;
    let _ = registry()?;
    let _ = mac::layout()?;
    mac::buttons_up()?;
    let mut restore = mac::Restore::new()?;
    let mut c = Command::new(std::env::current_exe().map_err(|e| e.to_string())?);
    c.args([
        "--execute",
        "--worker",
        "--parent-pid",
        &std::process::id().to_string(),
        "--same-board",
        &a.association,
        "--flash-proof",
    ])
    .arg(a.proof.as_ref().unwrap());
    let child = bounded(c, None, Duration::from_secs(12), 65536);
    // A killed/stalled worker may have left a queued report. Wait past the fixed
    // 5s nonrenewing firmware lease before restoring the parent-owned cursor.
    if child.is_err() {
        std::thread::sleep(Duration::from_millis(5100));
    }
    let cleanup = restore.restore();
    let output = match (child, cleanup) {
        (Ok(output), Ok(())) => output,
        (Err(error), Ok(())) => return Err(format!("{error}; cursor restored")),
        (Ok(_), Err(error)) => return Err(error),
        (Err(error), Err(cleanup)) => {
            return Err(format!(
                "{error}; cursor restoration also failed: {cleanup}"
            ))
        }
    };
    let s = String::from_utf8(output).map_err(|_| "Invalid worker output")?;
    Ok(format!(
        "{{\"mode\":\"execute\",\"cursor_restored\":true,\"firmware_sha256\":{},\"worker\":{}}}",
        quote(FIRMWARE_SHA.unwrap_or("")),
        s.trim()
    ))
}
#[cfg(not(target_os = "macos"))]
fn execute(_: &Args) -> Result<String> {
    Err("Execution requires macOS Book".into())
}
fn run(a: &Args) -> Result<String> {
    if !a.execute {
        return Ok(format!("{{\"mode\":\"dry_run\",\"status\":\"offline_plan_only\",\"device_access\":false,\"input_injected\":false,\"firmware_bound\":{},\"points\":[[16384,16384],[8192,8192],[24576,8192],[8192,24576],[24576,24576]],\"scope\":\"five-point absolute positioning only; no scroll, four-finger, clipboard or edge-return acceptance\"}}",FIRMWARE_SHA.is_some()));
    }
    require(HARDWARE_EXECUTION_REVIEWED, "NOT_READY_NOT_FLASHED: build is not bound to the reviewed 2026-11-09 Book-only candidate")?;
    require(
        FIRMWARE_SHA.is_some(),
        "Execute disabled: compile with an independently verified candidate firmware SHA256",
    )?;
    #[cfg(target_os = "macos")]
    if a.worker {
        return worker(a);
    }
    execute(a)
}
fn main() {
    #[cfg(unix)]
    unsafe {
        for s in [1, 2, 15] {
            signal(s, interrupted as *const () as usize);
        }
    }
    let a = match args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2)
        }
    };
    let mut out = match &a.out {
        Some(p) => match std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(p)
        {
            Ok(f) => Some(f),
            Err(e) => {
                eprintln!("Cannot reserve evidence file: {e}");
                std::process::exit(2)
            }
        },
        None => None,
    };
    let result = run(&a);
    let success = result.is_ok();
    let json =
        result.unwrap_or_else(|e| format!("{{\"status\":\"failed\",\"error\":{}}}", quote(&e)));
    if let Some(f) = &mut out {
        if writeln!(f, "{json}").is_err() {
            eprintln!("Evidence write failed");
            std::process::exit(2)
        }
    }
    println!("{json}");
    if !success {
        std::process::exit(2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dry_run_does_not_read_even_invalid_proof() {
        let a = Args {
            execute: false,
            worker: false,
            proof: Some("/this-file-must-not-be-read".into()),
            association: "invalid".into(),
            out: None,
            parent: None,
        };
        let output = run(&a).unwrap();
        assert!(output.contains("\"device_access\":false"));
        assert!(output.contains("\"input_injected\":false"));
    }
    #[test]
    fn bounded_process_timeout_kills_and_reaps() {
        let mut c = Command::new("/bin/sleep");
        c.arg("1");
        let start = Instant::now();
        assert!(bounded(c, None, Duration::from_millis(20), 64).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn hardware_gate_fails_before_missing_proof_or_any_device_access() {
        let a = Args {
            execute: true,
            worker: false,
            proof: Some("/must-not-be-read".into()),
            association: ASSOCIATION.into(),
            out: None,
            parent: None,
        };
        let error = run(&a).unwrap_err();
        if HARDWARE_EXECUTION_REVIEWED {
            // Still stops at missing flash proof, before process/USB access.
            assert!(error.contains("No such file") || error.contains("os error 2"));
        } else {
            assert!(error.contains("NOT_READY_NOT_FLASHED"));
        }
    }
}
