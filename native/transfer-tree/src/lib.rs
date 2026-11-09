//! A bounded, read-only snapshot plan for a multi-selection or directory tree.
//! Manifest first, then concatenated file data; never creates an archive on disk.
//! The caller transports these bytes using the existing binary Bulk engine.
//! Enumeration and reads belong on a cancellable disk worker, never an input/UI queue.

#[cfg(not(unix))]
compile_error!("The initial transfer-tree source adapter requires Unix file descriptors");

use std::{collections::{HashMap, HashSet}, ffi::{CString, CStr, c_char, c_int},
    fs::{self, File}, io, os::unix::{ffi::OsStrExt, fs::{MetadataExt, FileExt, OpenOptionsExt},
    io::{AsRawFd, FromRawFd}}, path::{Path, PathBuf}, sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}};

pub const MAX_ENTRIES: usize = 100_000;
pub const MAX_ROOTS: usize = 128;
pub const MAX_DEPTH: usize = 64;
pub const MAX_MANIFEST: usize = 8 * 1024 * 1024;
pub const MAX_TOTAL: u64 = 64 * 1024 * 1024 * 1024;
pub const MAX_READ: usize = 65_536;
const MAGIC: &[u8; 8] = b"WKTB0001";

#[derive(Debug)]
pub enum Error { Invalid, Limit, Changed, Cancelled, Unsupported, Io(io::Error) }
impl From<io::Error> for Error { fn from(e: io::Error) -> Self { Self::Io(e) } }
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Default)]
pub struct Cancellation(AtomicBool);
impl Cancellation {
    pub fn cancel(&self) { self.0.store(true, Ordering::Release); }
    pub fn check(&self) -> Result<()> {
        if self.0.load(Ordering::Acquire) { Err(Error::Cancelled) } else { Ok(()) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind { Directory = 1, File = 2 }
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry { pub path: String, pub kind: Kind, pub size: u64, pub offset: u64 }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest { pub entries: Vec<Entry>, pub roots: u32, pub payload_size: u64 }

fn path_key(path: &str) -> Result<String> {
    if path.is_empty() || path.len() > 4096 || path.contains('\\') || path.chars().any(char::is_control) {
        return Err(Error::Invalid);
    }
    let mut depth = 0;
    for p in path.split('/') {
        depth += 1;
        if p.is_empty() || p == "." || p == ".." || p.len() > 255 { return Err(Error::Invalid); }
    }
    if depth > MAX_DEPTH { return Err(Error::Limit); }
    Ok(path.to_lowercase())
}

impl Manifest {
    pub fn validate(&self) -> Result<()> {
        if self.entries.is_empty() || self.entries.len() > MAX_ENTRIES || self.roots == 0 || self.roots as usize > MAX_ROOTS {
            return Err(Error::Limit);
        }
        let mut seen = HashMap::new();
        let mut keys = HashSet::new();
        let mut roots = 0; let mut offset: u64 = 0; let mut wire_len: usize = 32;
        for e in &self.entries {
            let key = path_key(&e.path)?;
            if !keys.insert(key) || seen.contains_key(&e.path) { return Err(Error::Invalid); }
            if let Some((parent, _)) = e.path.rsplit_once('/') {
                if seen.get(parent) != Some(&Kind::Directory) { return Err(Error::Invalid); }
            } else { roots += 1; }
            if e.offset != offset || (e.kind == Kind::Directory && e.size != 0) { return Err(Error::Invalid); }
            offset = offset.checked_add(e.size).ok_or(Error::Limit)?;
            wire_len = wire_len.checked_add(24 + e.path.len()).ok_or(Error::Limit)?;
            if offset > MAX_TOTAL || wire_len > MAX_MANIFEST { return Err(Error::Limit); }
            seen.insert(e.path.clone(), e.kind);
        }
        if roots != self.roots || offset != self.payload_size { return Err(Error::Invalid); }
        if offset.checked_add(wire_len as u64).ok_or(Error::Limit)? > MAX_TOTAL { return Err(Error::Limit); }
        Ok(())
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let mut out = Vec::new(); out.extend_from_slice(MAGIC);
        out.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        out.extend_from_slice(&self.roots.to_le_bytes());
        out.extend_from_slice(&self.payload_size.to_le_bytes()); out.extend_from_slice(&[0; 8]);
        for e in &self.entries {
            out.extend_from_slice(&[e.kind as u8, 0, 0, 0]);
            out.extend_from_slice(&(e.path.len() as u32).to_le_bytes());
            out.extend_from_slice(&e.size.to_le_bytes()); out.extend_from_slice(&e.offset.to_le_bytes());
            out.extend_from_slice(e.path.as_bytes());
        }
        Ok(out)
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 32 || bytes.len() > MAX_MANIFEST || &bytes[..8] != MAGIC || bytes[24..32] != [0; 8] { return Err(Error::Invalid); }
        let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        if count == 0 || count > MAX_ENTRIES { return Err(Error::Limit); }
        let mut out = Self { entries: Vec::new(), roots: u32::from_le_bytes(bytes[12..16].try_into().unwrap()),
            payload_size: u64::from_le_bytes(bytes[16..24].try_into().unwrap()) };
        let mut pos = 32usize;
        for _ in 0..count {
            if bytes.len() - pos < 24 || bytes[pos+1..pos+4] != [0; 3] { return Err(Error::Invalid); }
            let kind = match bytes[pos] { 1 => Kind::Directory, 2 => Kind::File, _ => return Err(Error::Invalid) };
            let len = u32::from_le_bytes(bytes[pos+4..pos+8].try_into().unwrap()) as usize;
            let size = u64::from_le_bytes(bytes[pos+8..pos+16].try_into().unwrap());
            let offset = u64::from_le_bytes(bytes[pos+16..pos+24].try_into().unwrap()); pos += 24;
            if len > 4096 || len > bytes.len() - pos { return Err(Error::Invalid); }
            let path = std::str::from_utf8(&bytes[pos..pos+len]).map_err(|_| Error::Invalid)?.to_owned(); pos += len;
            out.entries.push(Entry { path, kind, size, offset });
        }
        if pos != bytes.len() { return Err(Error::Invalid); }
        out.validate()?; Ok(out)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity { dev: u64, ino: u64, size: u64, mode: u32, mt: (i64,i64), ct: (i64,i64) }
impl Identity {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata()?;
        Ok(Self { dev: m.dev(), ino: m.ino(), size: m.size(), mode: m.mode(),
            mt: (m.mtime(),m.mtime_nsec()), ct: (m.ctime(),m.ctime_nsec()) })
    }
    fn kind(&self) -> Result<Kind> {
        match self.mode & 0o170000 { 0o100000 => Ok(Kind::File), 0o040000 => Ok(Kind::Directory), _ => Err(Error::Unsupported) }
    }
}

#[cfg(target_os = "macos")]
const OPEN_FLAGS: i32 = 0x00000100 | 0x01000000 | 0x00000004; // NOFOLLOW | CLOEXEC | NONBLOCK
#[cfg(not(target_os = "macos"))]
const OPEN_FLAGS: i32 = 0x00020000 | 0x00080000 | 0x00000800;
unsafe extern "C" { fn openat(fd: c_int, path: *const c_char, flags: c_int, ...) -> c_int; }
unsafe extern "C" {
    fn wk_tree_dir_open(fd: c_int) -> *mut std::ffi::c_void;
    fn wk_tree_dir_next(dir: *mut std::ffi::c_void, output: *mut u8, capacity: u32) -> c_int;
    fn wk_tree_dir_close(dir: *mut std::ffi::c_void);
}
struct Directory(*mut std::ffi::c_void);
impl Drop for Directory { fn drop(&mut self) { unsafe { wk_tree_dir_close(self.0) } } }
#[cfg(target_os = "macos")]
unsafe extern "C" { fn fgetxattr(fd: c_int, name: *const c_char, value: *mut u8, size: usize, position: u32, options: c_int) -> isize; }

fn resource_fork(file: &File) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let n = unsafe { fgetxattr(file.as_raw_fd(), c"com.apple.ResourceFork".as_ptr(), std::ptr::null_mut(), 0, 0, 0) };
        if n > 0 { return Err(Error::Unsupported); }
        // ENOATTR and ENOTSUP are ordinary absence. Other errors must not silently drop data.
        if n < 0 && !matches!(io::Error::last_os_error().raw_os_error(), Some(93) | Some(45)) { return Err(io::Error::last_os_error().into()); }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = file;
    Ok(())
}
fn child(parent: &File, name: &str) -> Result<File> {
    if name.contains('/') || name.is_empty() || name == "." || name == ".." { return Err(Error::Invalid); }
    let name = CString::new(name).map_err(|_| Error::Invalid)?;
    let fd = unsafe { openat(parent.as_raw_fd(), name.as_ptr(), OPEN_FLAGS) };
    if fd < 0 { return Err(io::Error::last_os_error().into()); }
    let file = unsafe { File::from_raw_fd(fd) }; Identity::of(&file)?.kind()?; resource_fork(&file)?; Ok(file)
}

struct Source { root: usize, relative: Vec<String>, identity: Identity }
pub struct Tree {
    roots: Vec<File>, sources: Vec<Source>, file_indices: Vec<usize>,
    pub manifest: Manifest, encoded: Vec<u8>, cancellation: Arc<Cancellation>,
    cache: Mutex<Option<(usize, File)>>,
}
impl Tree {
    pub fn capture(paths: &[PathBuf], cancellation: Arc<Cancellation>) -> Result<Self> {
        if paths.is_empty() || paths.len() > MAX_ROOTS { return Err(Error::Limit); }
        let mut tree = Self { roots: Vec::new(), sources: Vec::new(), file_indices: Vec::new(),
            manifest: Manifest { entries: Vec::new(), roots: paths.len() as u32, payload_size: 0 },
            encoded: Vec::new(), cancellation, cache: Mutex::new(None) };
        let mut estimate = 32usize;
        for path in paths {
            tree.cancellation.check()?;
            let name = path.file_name().and_then(|s| s.to_str()).ok_or(Error::Invalid)?.to_owned(); path_key(&name)?;
            let file = fs::OpenOptions::new().read(true).custom_flags(OPEN_FLAGS).open(path)?;
            Identity::of(&file)?.kind()?; resource_fork(&file)?;
            let index = tree.roots.len(); tree.roots.push(file.try_clone()?);
            tree.walk(file, index, Vec::new(), name, &mut estimate)?;
        }
        tree.encoded = tree.manifest.encode()?;
        tree.verify()?; Ok(tree)
    }
    fn walk(&mut self, file: File, root: usize, relative: Vec<String>, path: String, estimate: &mut usize) -> Result<()> {
        self.cancellation.check()?; path_key(&path)?;
        if self.sources.len() >= MAX_ENTRIES { return Err(Error::Limit); }
        *estimate = estimate.checked_add(24 + path.len()).ok_or(Error::Limit)?;
        if *estimate > MAX_MANIFEST { return Err(Error::Limit); }
        let identity = Identity::of(&file)?; let kind = identity.kind()?;
        let size = if kind == Kind::File { identity.size } else { 0 };
        let offset = self.manifest.payload_size;
        self.manifest.payload_size = offset.checked_add(size).ok_or(Error::Limit)?;
        if self.manifest.payload_size > MAX_TOTAL { return Err(Error::Limit); }
        if kind == Kind::File && size != 0 { self.file_indices.push(self.sources.len()); }
        self.manifest.entries.push(Entry { path: path.clone(), kind, size, offset });
        self.sources.push(Source { root, relative: relative.clone(), identity: identity.clone() });
        if kind == Kind::Directory {
            // Enumerate through the pinned descriptor. Never follow a replaced parent path.
            let mut names = Vec::new();
            let raw = unsafe { wk_tree_dir_open(file.as_raw_fd()) };
            if raw.is_null() { return Err(io::Error::last_os_error().into()); }
            let directory = Directory(raw);
            loop {
                self.cancellation.check()?;
                let mut bytes = [0; 256];
                let count = unsafe { wk_tree_dir_next(directory.0, bytes.as_mut_ptr(), bytes.len() as u32) };
                if count < 0 { return Err(io::Error::from_raw_os_error(-count).into()); }
                if count == 0 { break; }
                if names.len() + self.sources.len() >= MAX_ENTRIES { return Err(Error::Limit); }
                let name = std::str::from_utf8(&bytes[..count as usize]).map_err(|_| Error::Unsupported)?.to_owned();
                path_key(&name)?; names.push(name);
            }
            names.sort();
            for name in names {
                self.cancellation.check()?;
                let next = child(&file, &name)?;
                let mut parts = relative.clone(); parts.push(name.clone());
                self.walk(next, root, parts, format!("{path}/{name}"), estimate)?;
            }
            if Identity::of(&file)? != identity { return Err(Error::Changed); }
        }
        Ok(())
    }
    fn open_source(&self, index: usize) -> Result<File> {
        let s = &self.sources[index]; let mut f = self.roots[s.root].try_clone()?;
        for name in &s.relative { self.cancellation.check()?; f = child(&f, name)?; }
        if Identity::of(&f)? != s.identity { return Err(Error::Changed); }
        Ok(f)
    }
    pub fn manifest_bytes(&self) -> &[u8] { &self.encoded }
    pub fn size(&self) -> u64 { self.encoded.len() as u64 + self.manifest.payload_size }
    pub fn cancel(&self) { self.cancellation.cancel(); }
    pub fn verify(&self) -> Result<()> {
        for i in 0..self.sources.len() { self.cancellation.check()?; self.open_source(i)?; }
        Ok(())
    }
    pub fn read(&self, mut offset: u64, out: &mut [u8]) -> Result<usize> {
        self.cancellation.check()?;
        if out.len() > MAX_READ || offset > self.size() { return Err(Error::Invalid); }
        let wanted = out.len().min((self.size() - offset) as usize); let mut used = 0usize;
        if offset < self.encoded.len() as u64 {
            let n = wanted.min(self.encoded.len() - offset as usize);
            out[..n].copy_from_slice(&self.encoded[offset as usize..offset as usize+n]); offset += n as u64; used += n;
        }
        let mut cache = self.cache.lock().map_err(|_| Error::Changed)?;
        while used < wanted {
            self.cancellation.check()?;
            let pos = offset - self.encoded.len() as u64;
            let j = self.file_indices.partition_point(|&i| self.manifest.entries[i].offset + self.manifest.entries[i].size <= pos);
            let &index = self.file_indices.get(j).ok_or(Error::Invalid)?;
            let e = &self.manifest.entries[index];
            if pos < e.offset { return Err(Error::Invalid); }
            if cache.as_ref().map(|(i,_)| *i) != Some(index) { *cache = Some((index, self.open_source(index)?)); }
            let file = &cache.as_ref().unwrap().1;
            if Identity::of(file)? != self.sources[index].identity { return Err(Error::Changed); }
            let within = pos - e.offset; let n = (wanted-used).min((e.size-within) as usize);
            file.read_exact_at(&mut out[used..used+n], within)?;
            if Identity::of(file)? != self.sources[index].identity { return Err(Error::Changed); }
            self.cancellation.check()?; used += n; offset += n as u64;
        }
        Ok(used)
    }
}

// C ABI for the existing macOS adapter. Handles are owned by the Swift wrapper;
// no handle may be freed concurrently with a call using it. Cancellation is atomic.
fn code(e: Error) -> i32 { match e { Error::Invalid=>1, Error::Limit=>2, Error::Changed=>3, Error::Cancelled=>4, Error::Unsupported=>5, Error::Io(_)=>6 } }
fn guarded<T>(f: impl FnOnce()->Result<T>) -> std::result::Result<T,i32> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).map_err(|_| 7)?.map_err(code)
}
#[no_mangle] pub extern "C" fn wk_tree_cancel_new() -> *mut Arc<Cancellation> { Box::into_raw(Box::new(Arc::new(Cancellation::default()))) }
#[no_mangle] pub unsafe extern "C" fn wk_tree_cancel_set(p: *const Arc<Cancellation>) { if let Some(c) = p.as_ref() { c.cancel(); } }
#[no_mangle] pub unsafe extern "C" fn wk_tree_cancel_free(p: *mut Arc<Cancellation>) { if !p.is_null() { drop(Box::from_raw(p)); } }
#[no_mangle] pub unsafe extern "C" fn wk_tree_create(paths: *const *const c_char, count: usize, token: *const Arc<Cancellation>, error: *mut i32) -> *mut Tree {
    let result = guarded(|| {
        if paths.is_null() || token.is_null() || count == 0 || count > MAX_ROOTS { return Err(Error::Invalid); }
        let mut names = Vec::new();
        for &p in std::slice::from_raw_parts(paths, count) {
            if p.is_null() { return Err(Error::Invalid); }
            names.push(Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(p).to_bytes())).to_owned());
        }
        Tree::capture(&names, (*token).clone())
    });
    match result { Ok(t)=>{ if !error.is_null(){*error=0;} Box::into_raw(Box::new(t)) }, Err(e)=>{if !error.is_null(){*error=e;} std::ptr::null_mut()} }
}
#[no_mangle] pub unsafe extern "C" fn wk_tree_free(p: *mut Tree) { if !p.is_null(){drop(Box::from_raw(p));} }
#[no_mangle] pub unsafe extern "C" fn wk_tree_size(p: *const Tree)->u64 { p.as_ref().map_or(0, Tree::size) }
#[no_mangle] pub unsafe extern "C" fn wk_tree_manifest_size(p: *const Tree)->usize { p.as_ref().map_or(0, |t|t.encoded.len()) }
#[no_mangle] pub unsafe extern "C" fn wk_tree_manifest_copy(p: *const Tree, out: *mut u8, size: usize)->i32 {
    if let Some(t)=p.as_ref(){if !out.is_null() && size==t.encoded.len(){std::ptr::copy_nonoverlapping(t.encoded.as_ptr(),out,size);return 0;}} 1
}
#[no_mangle] pub unsafe extern "C" fn wk_tree_verify(p: *const Tree)->i32 {
    guarded(||p.as_ref().ok_or(Error::Invalid)?.verify()).err().unwrap_or(0)
}
#[no_mangle] pub unsafe extern "C" fn wk_tree_read(p: *const Tree, offset:u64, out:*mut u8, capacity:usize)->isize {
    let result=guarded(||{if out.is_null() || capacity>MAX_READ{return Err(Error::Invalid);}
        p.as_ref().ok_or(Error::Invalid)?.read(offset,std::slice::from_raw_parts_mut(out,capacity))});
    match result{Ok(n)=>n as isize,Err(e)=>-(e as isize)}
}
#[no_mangle] pub unsafe extern "C" fn wk_tree_manifest_validate(data:*const u8, size:usize, total:u64)->i32 {
    guarded(||{if data.is_null() || size>MAX_MANIFEST{return Err(Error::Invalid);}
        let m=Manifest::decode(std::slice::from_raw_parts(data,size))?;
        if m.payload_size.checked_add(size as u64)!=Some(total){return Err(Error::Invalid);} Ok(())}).err().unwrap_or(0)
}
