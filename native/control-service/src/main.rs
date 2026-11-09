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
        };
        for p in [&c.native, &c.relay, &c.capture] {
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
        p == self.native || p == self.relay || p == self.capture
    }
    fn verify(&self) -> Result<()> {
        for (key, path) in [
            ("native_sha256", &self.native),
            ("relay_sha256", &self.relay),
            ("capture_sha256", &self.capture),
        ] {
            let (ok, out) = bounded(self, "/usr/bin/shasum", &["-a", "256", path], 5)?;
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
    let (ok, text) = bounded(c, "/bin/ps", &["-axo", "pid=,comm="], 3)?;
    if !ok {
        return Err("Process inventory failed".into());
    }
    let mut found = Vec::new();
    for l in text.lines() {
        let Some((p, cmd)) = l.trim().split_once(char::is_whitespace) else {
            continue;
        };
        let name = Path::new(cmd.trim())
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        if ["wiredkvm-native", "wiredkvm-companion", "macos-capture"].contains(&name) {
            if let Ok(pid) = p.parse() {
                if let Some(i) = identity(pid) {
                    found.push(i)
                }
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
        [&c.native, &c.relay, &c.capture]
            .iter()
            .all(|path| self.members.iter().any(|p| &p.path == *path && alive(p)))
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
fn start(c: &Config, d: &Device) -> Result<Session> {
    c.verify()?;
    let (ok, out) = bounded(c, &c.capture, &["--check-permission"], 5)?;
    if !ok || !out.contains("ACCESSIBILITY_TRUSTED=true") {
        return Err("Accessibility permission unavailable".into());
    }
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
        state(&c, "adopted", "Existing input-only runtime retained")
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
        Some("run") if args.len()==3=>run(Config::load(Path::new(&args[2]))?),
        Some("seed") if args.len()==6=>{
            let c=Config::load(Path::new(&args[2]))?; c.verify()?;
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
        _=>Err("Usage: wiredkvm-control-service inventory | run CONFIG | seed CONFIG NATIVE_PID RELAY_PID CAPTURE_PID".into())
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
        let p = c.state.join("lock");
        let a = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&p)
            .unwrap();
        let b = OpenOptions::new().write(true).open(&p).unwrap();
        assert_eq!(unsafe { wk_lock(a.as_raw_fd()) }, 0);
        assert_ne!(unsafe { wk_lock(b.as_raw_fd()) }, 0);
        drop(a);
        assert_eq!(unsafe { wk_lock(b.as_raw_fd()) }, 0);
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
}
