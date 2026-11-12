use std::{
    collections::BTreeMap,
    ffi::CStr,
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use wiredkvm_control_service::{decide, hid_ready, same_process, Action, Device, Identity};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
#[repr(C)]
#[derive(Clone, Copy)]
struct RawDevice {
    entry: u64,
    location: u32,
    port: [i8; 256],
}
extern "C" {
    fn wk_devices(out: *mut RawDevice, capacity: i32) -> i32;
    fn wk_console_active() -> i32;
    fn wk_process(
        pid: i32,
        path: *mut i8,
        capacity: i32,
        sec: *mut u64,
        usec: *mut u64,
        parent: *mut i32,
    ) -> i32;
    fn wk_lock(fd: i32) -> i32;
    fn kill(pid: i32, sig: i32) -> i32;
    fn signal(sig: i32, handler: usize) -> usize;
}
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn on_stop(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}
fn devices() -> Result<Vec<Device>> {
    let mut rows = [RawDevice {
        entry: 0,
        location: 0,
        port: [0; 256],
    }; 16];
    let n = unsafe { wk_devices(rows.as_mut_ptr(), 16) };
    if !(0..=16).contains(&n) {
        return Err("USB inventory failed or too many boards".into());
    }
    Ok(rows[..n as usize]
        .iter()
        .map(|r| Device {
            entry: r.entry,
            location: r.location,
            port: unsafe { CStr::from_ptr(r.port.as_ptr()) }
                .to_string_lossy()
                .into_owned(),
        })
        .collect())
}
fn identity(pid: i32) -> Option<(Identity, i32)> {
    let mut path = [0i8; 4096];
    let (mut sec, mut usec, mut parent) = (0, 0, 0);
    if pid <= 1
        || unsafe {
            wk_process(
                pid,
                path.as_mut_ptr(),
                4096,
                &mut sec,
                &mut usec,
                &mut parent,
            )
        } == 0
    {
        return None;
    }
    Some((
        Identity {
            pid,
            sec,
            usec,
            path: unsafe { CStr::from_ptr(path.as_ptr()) }
                .to_string_lossy()
                .into_owned(),
        },
        parent,
    ))
}
fn alive(p: &Identity) -> bool {
    same_process(p, identity(p.pid).as_ref().map(|x| &x.0))
}
fn send(p: &Identity, sig: i32) {
    if alive(p) {
        unsafe {
            kill(p.pid, sig);
        }
    }
}
fn stamp(pid: i32, path: &str) -> Result<Identity> {
    let p = identity(pid).ok_or("Process disappeared")?.0;
    if p.path != path {
        return Err("Executable identity mismatch".into());
    }
    Ok(p)
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn atomic_write(path: &Path, text: &str) -> io::Result<()> {
    let temp = path.with_extension("new");
    let mut f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temp)?;
    f.write_all(text.as_bytes())?;
    fs::rename(temp, path)
}
fn tail(path: &Path, max: usize) -> String {
    let Ok(mut f) = File::open(path) else {
        return String::new();
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let _ = f.seek(SeekFrom::Start(len.saturating_sub(max as u64)));
    let mut bytes = Vec::new();
    let _ = f.take(max as u64).read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).into_owned()
}
struct Config {
    native: String,
    relay: String,
    capture: String,
    state: PathBuf,
    hashes: BTreeMap<String, String>,
    portable: Option<(String, String)>, // coordinator executable, pinned runtime JSON
}
impl Config {
    fn load(path: &Path) -> Result<Self> {
        let mut map = BTreeMap::new();
        for l in fs::read_to_string(path)?
            .lines()
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
        {
            let (k, v) = l.split_once('=').ok_or("Malformed config")?;
            if map.insert(k.to_string(), v.to_string()).is_some() {
                return Err("Duplicate config key".into());
            }
        }
        let get = |key: &str| -> Result<String> {
            map.get(key)
                .cloned()
                .ok_or_else(|| format!("Missing {key}").into())
        };
        let c = Self {
            native: get("native")?,
            relay: get("relay")?,
            capture: get("capture")?,
            state: PathBuf::from(get("state_dir")?),
            hashes: map.clone(),
            portable: match (map.get("portable_host"),map.get("portable_runtime")) {
                (None,None)=>None,
                (Some(host),Some(runtime))=>Some((host.clone(),runtime.clone())),
                _=>return Err("Portable host and runtime must be configured together".into()),
            },
        };
        let mut paths=vec![&c.native,&c.relay,&c.capture];
        if let Some((host,runtime))=&c.portable { paths.extend([host,runtime]); }
        for p in paths {
            if !Path::new(p).is_absolute() || p.contains(['\n', '\t']) {
                return Err("Invalid executable path".into());
            }
        }
        if !c.state.is_absolute() {
            return Err("State path must be absolute".into());
        }
        fs::create_dir_all(&c.state)?;
        fs::set_permissions(&c.state, fs::Permissions::from_mode(0o700))?;
        Ok(c)
    }
    fn allowed(&self, p: &str) -> bool {
        p == self.native || p == self.relay || p == self.capture || self.portable.as_ref().is_some_and(|(host,_)|p==host)
    }
    fn required_paths(&self) -> Vec<&str> {
        match &self.portable {
            Some((host,_))=>vec![host.as_str(),self.native.as_str(),self.capture.as_str()],
            None=>vec![self.native.as_str(),self.relay.as_str(),self.capture.as_str()],
        }
    }
    fn verify(&self) -> Result<()> {
        let mut entries=vec![
            ("native_sha256", &self.native),
            ("capture_sha256", &self.capture),
        ];
        if let Some((host,runtime))=&self.portable { entries.extend([("portable_host_sha256",host),("portable_runtime_sha256",runtime)]); }
        else {entries.push(("relay_sha256",&self.relay));}
        for (key,path) in entries {
            let (ok, out) = bounded(self, "/usr/bin/shasum", &["-a", "256", path], 5)
                .map_err(|e| format!("Hash check failed for {key}: {e}"))?;
            if !ok || out.split_whitespace().next() != self.hashes.get(key).map(String::as_str) {
                return Err(format!("Binary hash mismatch: {key}").into());
            }
        }
        Ok(())
    }
}
// Files instead of piped stdout prevent a noisy child deadlocking the supervisor.
fn bounded(c: &Config, exe: &str, args: &[&str], seconds: u64) -> Result<(bool, String)> {
    let path = c.state.join("probe.log");
    let log = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&path)?;
    let mut p = Command::new(exe)
        .args(args)
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()?;
    let end = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(s) = p.try_wait()? {
            return Ok((s.success(), tail(&path, 65536)));
        }
        if STOP.load(Ordering::Relaxed) || Instant::now() >= end {
            let _ = p.kill();
            let _ = p.wait();
            return Err("Probe cancelled or timed out".into());
        }
        thread::sleep(Duration::from_millis(40));
    }
}
fn processes(c: &Config) -> Result<Vec<(Identity, i32)>> {
    // comm can be truncated to 15 bytes. Read only PIDs from ps, then use the
    // existing kernel ABI for full paths and birth times; never infer identity
    // from a displayed command or a basename.
    let (ok, text) = bounded(c, "/bin/ps", &["-axo", "pid="], 3)?;
    if !ok {
        return Err("Process inventory failed".into());
    }
    let mut found = Vec::new();
    for l in text.lines() {
        if let Ok(pid)=l.trim().parse() {
            if let Some(i)=identity(pid) {
                if c.allowed(&i.0.path) { found.push(i); }
            }
        }
    }
    Ok(found)
}
struct Session {
    device: Device,
    members: Vec<Identity>,
    children: Vec<Child>,
}
impl Session {
    fn save(&self, c: &Config) -> Result<()> {
        let d = &self.device;
        let mut text = format!("device\t{}\t{}\t{}\n", d.entry, d.location, d.port);
        for p in &self.members {
            text += &format!("process\t{}\t{}\t{}\t{}\n", p.pid, p.sec, p.usec, p.path)
        }
        atomic_write(&c.state.join("session.tsv"), &text)?;
        Ok(())
    }
    fn load(c: &Config) -> Result<Option<Self>> {
        let path = c.state.join("session.tsv");
        if !path.exists() {
            return Ok(None);
        }
        let data = fs::read_to_string(path)?;
        let mut lines = data.lines();
        let h: Vec<_> = lines.next().ok_or("Empty session")?.split('\t').collect();
        if h.len() != 4 || h[0] != "device" || !h[3].starts_with("/dev/cu.") {
            return Err("Invalid session device".into());
        }
        let mut s = Self {
            device: Device {
                entry: h[1].parse()?,
                location: h[2].parse()?,
                port: h[3].into(),
            },
            members: vec![],
            children: vec![],
        };
        for l in lines {
            let f: Vec<_> = l.split('\t').collect();
            if f.len() != 5 || f[0] != "process" || !c.allowed(f[4]) {
                return Err("Invalid session process".into());
            }
            let p = Identity {
                pid: f[1].parse()?,
                sec: f[2].parse()?,
                usec: f[3].parse()?,
                path: f[4].into(),
            };
            if alive(&p) {
                s.members.push(p)
            }
        }
        if s.members.is_empty() {
            fs::remove_file(c.state.join("session.tsv"))?;
            Ok(None)
        } else {
            Ok(Some(s))
        }
    }
    fn healthy(&mut self, c: &Config) -> bool {
        for p in &mut self.children {
            let _ = p.try_wait();
        }
        if let Some((host,_))=&c.portable {
            let Some(root)=self.members.iter().find(|p|p.path==*host&&alive(p)).cloned() else{return false;};
            let mut changed=false;
            for (p,parent) in processes(c).unwrap_or_default() {
                if p.pid==root.pid||self.members.iter().any(|old|old==&p){continue;}
                let direct=(p.path==c.native||p.path==c.relay)&&parent==root.pid;
                let capture=p.path==c.capture&&self.members.iter().any(|old|old.path==c.native&&old.pid==parent&&alive(old));
                if direct||capture {
                    self.members.push(p);changed=true;
                }
            }
            if changed && self.save(c).is_err(){return false;}
        }
        c.required_paths().iter().all(|path|self.members.iter().any(|p|p.path==*path&&alive(p)))
    }
    fn stop(&mut self, c: &Config) {
        // Capture's SIGTERM handler restores the local pointer. Do not KILL it first.
        for p in &self.members {
            send(p, 15)
        }
        let end = Instant::now() + Duration::from_secs(3);
        while Instant::now() < end && self.members.iter().any(alive) {
            for p in &mut self.children {
                let _ = p.try_wait();
            }
            thread::sleep(Duration::from_millis(30));
        }
        for p in &self.members {
            send(p, 9)
        }
        for p in &mut self.children {
            let _ = p.wait();
        }
        let _ = fs::remove_file(c.state.join("session.tsv"));
    }
}
// Read-only admission, also usable from launchd before replacing a live service.
// It does not enumerate/open USB, start input capture, or acquire a service lock.
fn preflight(c: &Config) -> Result<()> {
    c.verify()?;
    let (ok, out) = bounded(c, &c.capture, &["--check-permission"], 5)?;
    if !ok || !out.contains("ACCESSIBILITY_TRUSTED=true") {
        return Err("Accessibility permission unavailable".into());
    }
    Ok(())
}
fn start(c: &Config, d: &Device) -> Result<Session> {
    preflight(c)?;
    let (ok, held) = bounded(c, "/usr/sbin/lsof", &["-t", &d.port], 3)?;
    if ok || !held.trim().is_empty() {
        return Err("USB control port is occupied or cannot be checked".into());
    }
    let transport = format!("cdc:{}", d.port);
    let (ok, out) = bounded(
        c,
        &c.native,
        &[
            "--transport",
            &transport,
            "--source",
            "check-hid",
            "--absolute-mouse",
        ],
        10,
    )?;
    if !hid_ready(ok, &out) {
        return Err("Waiting for target USB HID".into());
    }
    if devices()?.as_slice() != [d.clone()] || unsafe { wk_console_active() } == 0 {
        return Err("USB or login changed during probe".into());
    }
    if c.portable.is_some(){return start_portable(c,d);}
    // A new path isolates reconnects from stale local sockets and pending messages.
    let ipc = PathBuf::from(format!(
        "/private/tmp/wk-auto-{}-{}",
        std::process::id(),
        now()
    ));
    fs::create_dir(&ipc)?;
    fs::set_permissions(&ipc, fs::Permissions::from_mode(0o700))?;
    let sock = ipc.join("input.sock");
    let sock = sock.to_str().ok_or("Socket path encoding")?;
    let mut s = Session {
        device: d.clone(),
        members: vec![],
        children: vec![],
    };
    let result = (|| -> Result<()> {
        let args = vec![
            "--transport",
            &transport,
            "--source",
            "macos",
            "--target",
            "desktop",
            "--absolute-mouse",
            "--position",
            "right",
            "--invert-scroll",
            "--capture",
            &c.capture,
            "--input-socket",
            sock,
        ];
        for (exe, args, logname) in [
            (&c.native, args, "control.log"),
            (
                &c.relay,
                vec![
                    "--role",
                    "host",
                    "--socket",
                    sock,
                    "--input-only",
                    "--headless",
                ],
                "input-relay.log",
            ),
        ] {
            let path = c.state.join(logname);
            if path.exists() {
                fs::rename(&path, c.state.join(format!("{logname}.previous")))?;
            }
            let log = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(path)?;
            let child = Command::new(exe)
                .args(args)
                .stdin(Stdio::null())
                .stdout(log.try_clone()?)
                .stderr(log)
                .spawn()?;
            let pid = child.id() as i32;
            s.children.push(child);
            // std::process::spawn waits for exec; verify the real executable and birth time.
            s.members.push(stamp(pid, exe)?);
            s.save(c)?;
        }
        let end = Instant::now() + Duration::from_secs(8);
        while Instant::now() < end && !STOP.load(Ordering::Relaxed) {
            if s.children
                .iter_mut()
                .any(|p| !matches!(p.try_wait(), Ok(None)))
            {
                return Err("Input controller exited".into());
            }
            if tail(&c.state.join("control.log"), 16384).contains("GESTURE_CAPTURE_READY ready=1") {
                let native = s.members.iter().find(|p| p.path == c.native).unwrap().pid;
                let captures: Vec<_> = processes(c)?
                    .into_iter()
                    .filter(|(p, parent)| p.path == c.capture && *parent == native)
                    .collect();
                if captures.len() == 1 {
                    s.members.push(captures[0].0.clone());
                    s.save(c)?;
                    return Ok(());
                }
            }
            thread::sleep(Duration::from_millis(100));
        }
        Err("Input capture did not become ready".into())
    })();
    if let Err(e) = result {
        s.stop(c);
        return Err(e);
    }
    Ok(s)
}
fn start_portable(c:&Config,d:&Device)->Result<Session> {
    let (host,runtime)=c.portable.as_ref().ok_or("Portable configuration missing")?;
    let path=c.state.join("control.log");
    if path.exists(){fs::rename(&path,c.state.join("control.log.previous"))?;}
    let log=OpenOptions::new().create_new(true).write(true).mode(0o600).open(path)?;
    let mut child=Command::new(host).args(["--runtime-config",runtime]).stdin(Stdio::null())
        .stdout(log.try_clone()?).stderr(log).spawn()?;
    let id=match stamp(child.id() as i32,host){Ok(id)=>id,Err(e)=>{let _=child.kill();let _=child.wait();return Err(e);}};
    let mut s=Session{device:d.clone(),members:vec![id],children:vec![child]};
    let result=(||->Result<()> {
        s.save(c)?;let deadline=Instant::now()+Duration::from_secs(8);
        while Instant::now()<deadline&&!STOP.load(Ordering::Relaxed) {
            if s.children.iter_mut().any(|p|!matches!(p.try_wait(),Ok(None))){return Err("Portable coordinator exited".into());}
            if tail(&c.state.join("control.log"),16384).lines().any(|l|l=="CH32_INPUT_READY")&&s.healthy(c){return Ok(());}
            thread::sleep(Duration::from_millis(100));
        }
        Err("Portable input capture did not become ready".into())
    })();
    if let Err(e)=result{s.stop(c);return Err(e);}Ok(s)
}
fn state(c: &Config, status: &str, detail: &str) {
    let message = format!(
        "time_ms={}\nstatus={}\ndetail={}\n",
        now(),
        status,
        detail.replace(['\n', '\r'], " ")
    );
    let _ = atomic_write(&c.state.join("status.txt"), &message);
    eprintln!("{message}");
}
fn run(c: Config) -> Result<()> {
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(c.state.join("service.lock"))?;
    if unsafe { wk_lock(lock.as_raw_fd()) } != 0 {
        return Err("Another supervisor is running".into());
    }
    unsafe {
        signal(2, on_stop as *const () as usize);
        signal(15, on_stop as *const () as usize);
    }
    c.verify()?;
    let mut session = Session::load(&c)?;
    if session.is_some() {
        state(&c, "adopted", "Existing authorized runtime retained")
    }
    let mut last = String::new();
    let mut next_start = Instant::now();
    while !STOP.load(Ordering::Relaxed) {
        let inventory = devices();
        // A transient IOKit query error is not proof of a detach. The existing controller's heartbeat remains authoritative.
        let Ok(ds) = inventory else {
            thread::sleep(Duration::from_millis(500));
            continue;
        };
        let console = unsafe { wk_console_active() } != 0;
        let healthy = session.as_mut().map(|s| s.healthy(&c)).unwrap_or(false);
        let action = decide(
            console,
            &ds,
            session.as_ref().map(|s| &s.device),
            healthy,
            false,
        );
        let message = match action {
            Action::Stop => {
                if let Some(mut s) = session.take() {
                    s.stop(&c)
                }
                next_start = Instant::now();
                "waiting: previous input session released".into()
            }
            Action::Keep => "running: keyboard mouse and automatic edge return".into(),
            Action::Wait => {
                if !console {
                    "waiting: user login".into()
                } else if ds.is_empty() {
                    "waiting: USB1 connection".into()
                } else {
                    "waiting: multiple matching boards".into()
                }
            }
            Action::Start => {
                if Instant::now() < next_start {
                    thread::sleep(Duration::from_millis(200));
                    continue;
                }
                next_start = Instant::now() + Duration::from_secs(3);
                match processes(&c) {
                    Ok(p) if p.is_empty() => match start(&c, &ds[0]) {
                        Ok(s) => {
                            session = Some(s);
                            "running: input capture ready".into()
                        }
                        Err(e) => format!("waiting: {e}"),
                    },
                    Ok(_) => "waiting: another control process exists".into(),
                    Err(e) => format!("waiting: {e}"),
                }
            }
        };
        if message != last {
            state(
                &c,
                if session.is_some() {
                    "running"
                } else {
                    "waiting"
                },
                &message,
            );
            last = message;
        }
        thread::sleep(Duration::from_millis(500));
    }
    if let Some(mut s) = session {
        s.stop(&c)
    }
    state(&c, "stopped", "Input released");
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("inventory")=>{println!("console_active={}",unsafe{wk_console_active()});for d in devices()?{println!("{}\t{}\t{}",d.entry,d.location,d.port)}Ok(())},
        Some("check") if args.len()==3=>{
            let c=Config::load(Path::new(&args[2]))?;
            preflight(&c)?;
            println!("PREFLIGHT_READY no_usb_access=true no_input_capture=true");Ok(())
        },
        Some("run") if args.len()==3=>run(Config::load(Path::new(&args[2]))?),
        Some("seed-portable") if args.len()==4=>{
            let c=Config::load(Path::new(&args[2]))?;c.verify()?;
            let lock=OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(c.state.join("service.lock"))?;
            if unsafe{wk_lock(lock.as_raw_fd())}!=0{return Err("Stop the supervisor before adopting a runtime".into());}
            let host=&c.portable.as_ref().ok_or("Portable mode required")?.0;
            if c.state.join("session.tsv").exists(){return Err("Existing session must not be overwritten".into());}
            let ds=devices()?;if ds.len()!=1{return Err("Expected one host interface".into());}
            let root=stamp(args[3].parse()?,host)?;
            let mut session=Session{device:ds[0].clone(),members:vec![root],children:vec![]};
            if !session.healthy(&c){let _=fs::remove_file(c.state.join("session.tsv"));return Err("Portable input process tree is incomplete".into());}
            let (ok,held)=bounded(&c,"/usr/sbin/lsof",&["-t",&ds[0].port],3)?;
            let holders:Vec<i32>=held.lines().filter_map(|s|s.parse().ok()).collect();
            if !ok||holders.is_empty()||holders.iter().any(|pid|!session.members.iter().any(|p|p.pid==*pid)){
                let _=fs::remove_file(c.state.join("session.tsv"));
                return Err("Selected USB port is not exclusively held by the verified runtime".into());
            }
            session.save(&c)?;println!("Portable runtime adoption recorded");Ok(())
        },
        Some("seed") if args.len()==6=>{
            let c=Config::load(Path::new(&args[2]))?; c.verify()?;
            if c.portable.is_some(){return Err("Use seed-portable for a portable coordinator".into());}
            if c.state.join("session.tsv").exists(){return Err("Existing session record must not be overwritten".into())}
            let ds=devices()?; if ds.len()!=1{return Err("Expected one host control interface".into())}
            let mut members=vec![];
            for(a,path)in args[3..].iter().zip([&c.native,&c.relay,&c.capture]){members.push(stamp(a.parse()?,path)?)}
            let(ok,held)=bounded(&c,"/usr/sbin/lsof",&["-t",&ds[0].port],3)?;
            let holders:Vec<i32>=held.lines().filter_map(|s|s.parse().ok()).collect();
            if !ok||!holders.contains(&members[0].pid)||holders.iter().any(|pid|!members.iter().any(|p|p.pid==*pid)){
                return Err("Existing controller does not own the selected USB port".into())
            }
            if identity(members[2].pid).map(|p|p.1)!=Some(members[0].pid){return Err("Capture parent mismatch".into())}
            Session{device:ds[0].clone(),members,children:vec![]}.save(&c)?;println!("Existing runtime adoption recorded");Ok(())
        },
        _=>Err("Usage: wiredkvm-control-service inventory | check CONFIG | run CONFIG | seed CONFIG NATIVE_PID RELAY_PID CAPTURE_PID".into())
    }
}

#[cfg(test)]
mod platform_tests {
    use super::*;
    fn config(name: &str) -> Config {
        let state = std::env::temp_dir().join(format!(
            "wk-service-test-{}-{}-{}",
            std::process::id(),
            now(),
            name
        ));
        fs::create_dir(&state).unwrap();
        Config {
            native: "/usr/bin/true".into(),
            relay: "/usr/bin/false".into(),
            capture: "/bin/sleep".into(),
            state,
            hashes: BTreeMap::new(),
            portable: None,
        }
    }
    #[test]
    fn bounded_probe_success_failure_and_timeout() {
        let c = config("probe");
        assert!(bounded(&c, "/usr/bin/true", &[], 2).unwrap().0);
        assert!(!bounded(&c, "/usr/bin/false", &[], 2).unwrap().0);
        let start = Instant::now();
        assert!(bounded(&c, "/bin/sleep", &["10"], 1).is_err());
        assert!(start.elapsed() < Duration::from_secs(3));
    }
    #[test]
    fn lock_is_single_instance() {
        let c = config("lock");
        // Keep the owning descriptor in another process. Parallel tests may
        // fork between locking and close; their transient inherited fd must
        // not change what this test considers the lock owner's lifetime.
        let mut child=Command::new(std::env::current_exe().unwrap())
            .args(["--exact","platform_tests::lock_holder_process"])
            .env("WK_TEST_LOCK_ROOT",&c.state).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        let result=(||->Result<()> {
            let deadline=Instant::now()+Duration::from_secs(5);
            while !c.state.join("ready").exists() {
                if child.try_wait()?.is_some() || Instant::now()>=deadline { return Err("Lock fixture did not become ready".into()); }
                thread::sleep(Duration::from_millis(10));
            }
            let b=OpenOptions::new().write(true).open(c.state.join("lock"))?;
            if unsafe {wk_lock(b.as_raw_fd())}==0 {return Err("A second process acquired the held lock".into());}
            fs::write(c.state.join("release"),b"release")?;
            let deadline=Instant::now()+Duration::from_secs(5);
            loop {
                if let Some(status)=child.try_wait()? {if !status.success(){return Err("Lock fixture failed".into());}break;}
                if Instant::now()>=deadline {return Err("Lock fixture did not exit".into());}
                thread::sleep(Duration::from_millis(10));
            }
            if unsafe {wk_lock(b.as_raw_fd())}!=0 {return Err("Lock did not release after owner exit".into());}
            Ok(())
        })();
        let _=child.kill();let _=child.wait();result.unwrap();
    }
    #[test]
    fn lock_holder_process() {
        let Some(root)=std::env::var_os("WK_TEST_LOCK_ROOT") else{return};let root=PathBuf::from(root);
        let owner=OpenOptions::new().create_new(true).write(true).open(root.join("lock")).unwrap();
        assert_eq!(unsafe {wk_lock(owner.as_raw_fd())},0);fs::write(root.join("ready"),b"ready").unwrap();
        let deadline=Instant::now()+Duration::from_secs(5);
        while !root.join("release").exists() {assert!(Instant::now()<deadline,"Lock fixture release timeout");thread::sleep(Duration::from_millis(10));}
    }
    #[test]
    fn stale_pid_cannot_be_adopted_and_live_session_roundtrips() {
        let mut c = config("session");
        let me = identity(std::process::id() as i32).unwrap().0;
        c.native = me.path.clone();
        let s = Session {
            device: Device {
                entry: 44,
                location: 1,
                port: "/dev/cu.test".into(),
            },
            members: vec![me.clone()],
            children: vec![],
        };
        s.save(&c).unwrap();
        assert_eq!(
            Session::load(&c).unwrap().unwrap().members,
            vec![me.clone()]
        );
        let mut reused = me;
        reused.sec += 1;
        Session {
            members: vec![reused],
            ..s
        }
        .save(&c)
        .unwrap();
        assert!(Session::load(&c).unwrap().is_none());
    }
    #[test]
    fn graceful_stop_signals_only_recorded_child() {
        let c = config("stop");
        let child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let id = stamp(child.id() as i32, "/bin/sleep").unwrap();
        let mut s = Session {
            device: Device {
                entry: 1,
                location: 1,
                port: "/dev/cu.test".into(),
            },
            members: vec![id.clone()],
            children: vec![child],
        };
        s.save(&c).unwrap();
        s.stop(&c);
        assert!(!alive(&id));
        assert!(!c.state.join("session.tsv").exists());
    }
    #[test]
    fn portable_config_is_explicit_and_requires_both_pinned_paths() {
        let c=config("portable-config");let path=c.state.join("config.txt");
        let base=format!("native=/usr/bin/true\nrelay=/usr/bin/false\ncapture=/bin/sleep\nstate_dir={}\n",c.state.display());
        fs::write(&path,format!("{base}portable_host=/bin/cat\n")).unwrap();assert!(Config::load(&path).is_err());
        fs::write(&path,format!("{base}portable_host=/bin/cat\nportable_runtime=/tmp/wk-test-runtime.json\n")).unwrap();
        let parsed=Config::load(&path).unwrap();assert!(parsed.allowed("/bin/cat"));assert!(!parsed.allowed("/tmp/wk-test-runtime.json"));
        assert_eq!(parsed.required_paths(),vec!["/bin/cat","/usr/bin/true","/bin/sleep"]);
        fs::write(&path,format!("{base}portable_host=relative\nportable_runtime=/tmp/wk-test-runtime.json\n")).unwrap();assert!(Config::load(&path).is_err());
    }
    #[test]
    fn portable_adoption_tracks_exact_parent_roles_and_keeps_foreign_children() {
        let mut c=config("portable-tree");let me=identity(std::process::id() as i32).unwrap().0;
        c.portable=Some((me.path.clone(),"/tmp/wk-fixture.json".into()));c.native="/bin/zsh".into();c.capture="/bin/sleep".into();
        let foreign=Command::new("/bin/sleep").arg("30").spawn().unwrap();let foreign_id=stamp(foreign.id() as i32,"/bin/sleep").unwrap();
        let native=Command::new("/bin/zsh").args(["-c","/bin/sleep 30 & wait"]).spawn().unwrap();
        let mut s=Session{device:Device{entry:1,location:1,port:"/dev/cu.test".into()},members:vec![me.clone()],children:vec![native]};
        let deadline=Instant::now()+Duration::from_secs(3);let mut ready=false;
        while Instant::now()<deadline{if s.healthy(&c){ready=true;break;}thread::sleep(Duration::from_millis(30));}
        let foreign_was_excluded=!s.members.iter().any(|p|p==&foreign_id);
        s.members.retain(|p|p!=&me);s.stop(&c);let foreign_survived=alive(&foreign_id);
        let mut foreign=foreign;let _=foreign.kill();let _=foreign.wait();
        assert!(ready);assert!(foreign_was_excluded);assert!(foreign_survived);
    }
    #[test]
    fn unavailable_portable_clipboard_does_not_block_verified_input_startup() {
        let mut c=config("portable-input-priority");let runtime=c.state.join("runtime.json");fs::write(&runtime,"{}").unwrap();
        c.relay="/private/tmp/wk-no-such-component".into();c.portable=Some((std::env::current_exe().unwrap().to_str().unwrap().into(),runtime.to_str().unwrap().into()));
        let (host,json)=c.portable.as_ref().unwrap();
        for (key,path) in [("native_sha256",&c.native),("capture_sha256",&c.capture),("portable_host_sha256",host),("portable_runtime_sha256",json)] {
            let output=Command::new("/usr/bin/shasum").args(["-a","256",path]).output().unwrap();assert!(output.status.success());
            c.hashes.insert(key.into(),String::from_utf8(output.stdout).unwrap().split_whitespace().next().unwrap().into());
        }
        assert!(c.verify().is_ok());c.portable=None;assert!(c.verify().is_err());
    }
    #[test]
    fn preflight_rejects_bad_pins_and_permission_without_starting_input() {
        let mut c=config("preflight");
        let capture=c.state.join("capture-fixture");
        fs::write(&capture,"#!/bin/sh\n[ \"$1\" = --check-permission ] || exit 7\nprintf 'ACCESSIBILITY_TRUSTED=true\\n'\n").unwrap();
        fs::set_permissions(&capture,fs::Permissions::from_mode(0o700)).unwrap();
        c.capture=capture.to_str().unwrap().into();
        for (key,path) in [("native_sha256",&c.native),("relay_sha256",&c.relay),("capture_sha256",&c.capture)] {
            let output=Command::new("/usr/bin/shasum").args(["-a","256",path]).output().unwrap();
            assert!(output.status.success());c.hashes.insert(key.into(),String::from_utf8(output.stdout).unwrap().split_whitespace().next().unwrap().into());
        }
        assert!(preflight(&c).is_ok());
        for name in ["service.lock","session.tsv","control.log","status.txt"] { assert!(!c.state.join(name).exists()); }
        c.hashes.insert("native_sha256".into(),"0".repeat(64));
        assert!(preflight(&c).unwrap_err().to_string().contains("native_sha256"));
        c.capture="/usr/bin/false".into();
        let output=Command::new("/usr/bin/shasum").args(["-a","256",&c.native]).output().unwrap();
        c.hashes.insert("native_sha256".into(),String::from_utf8(output.stdout).unwrap().split_whitespace().next().unwrap().into());
        let digest=c.hashes["relay_sha256"].clone();c.hashes.insert("capture_sha256".into(),digest);
        assert!(preflight(&c).unwrap_err().to_string().contains("Accessibility permission unavailable"));
    }
}
