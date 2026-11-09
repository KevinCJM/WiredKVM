use std::{ffi::{CString,CStr},fs::File,io::{Read,Write,ErrorKind},os::fd::FromRawFd,path::Path,
          thread,time::{Duration,Instant,SystemTime,UNIX_EPOCH}};
use wiredkvm_cable_image::*;
type Result<T>=std::result::Result<T,Box<dyn std::error::Error>>;
extern "C" {fn wk_image_path(out:*mut i8,n:usize)->i32;fn wk_image_open(path:*const i8)->i32;}
fn read_asset(path:&Path)->Result<Vec<u8>> {
    let mut file=File::open(path)?;let mut bytes=Vec::new();Read::by_ref(&mut file).take(u64::from(CAPACITY)+1).read_to_end(&mut bytes)?;
    if bytes.len()<=IMAGE_OFFSET as usize||bytes.len()>CAPACITY as usize{return Err("program asset size invalid".into());}
    Ok(bytes)
}
struct Sim(Vec<u8>);
impl Memory for Sim {
    fn available(&self)->bool{true}
    fn write_verified(&mut self,at:u32,b:&[u8])->bool{self.0[at as usize..at as usize+b.len()].copy_from_slice(b);true}
}
fn validate(a:&[u8])->Result<()> {
    let mut u=Upload::new();let mut ram=Sim(vec![0;a.len()]);let checksum=crc32(a);
    let f=|operation,offset,body|Frame{operation,session:1,offset,total:a.len() as u32,checksum,body}.encode().unwrap();
    if u.accept(0,&f(BEGIN,0,&[]),&mut ram).code!=Code::Accepted{return Err("program envelope rejected".into());}
    for (n,b) in a.chunks(BODY).enumerate(){if u.accept(0,&f(DATA,(n*BODY) as u32,b),&mut ram).code!=Code::Accepted{return Err("program payload rejected".into());}}
    if u.accept(0,&f(FINISH,a.len() as u32,&[]),&mut ram).code!=Code::Sealed||ram.0!=a{return Err("program integrity check failed".into());}
    Ok(())
}
fn transact(file:&mut File,cells:&[[u8;CELL]],session:Option<u64>,last:u32,want:Code)->Result<Reply> {
    let bytes:Vec<u8>=cells.iter().flatten().copied().collect();let mut written=0;let mut incoming=Vec::new();let mut replies=0;
    let deadline=Instant::now()+Duration::from_secs(3);let mut last_reply=None;let mut buffer=[0;CELL*16];let mut failure=None;
    while written<bytes.len()||replies<cells.len() {
        if Instant::now()>=deadline{return Err("program channel timeout; input channel was not opened".into());}
        let mut moved=false;
        if written<bytes.len(){match file.write(&bytes[written..]){Ok(0)=>return Err("program USB disconnected".into()),Ok(n)=>{written+=n;moved=true},Err(e)if e.kind()==ErrorKind::WouldBlock=>(),Err(e)=>return Err(e.into())}}
        match file.read(&mut buffer){Ok(n)if n>0=>{incoming.extend_from_slice(&buffer[..n]);moved=true},Ok(_)=>(),Err(e)if e.kind()==ErrorKind::WouldBlock=>(),Err(e)=>return Err(e.into())}
        while incoming.len()>=CELL {
            let reply=Reply::decode(&incoming[..CELL]).ok_or("invalid program acknowledgement")?;incoming.drain(..CELL);
            if (session.is_some_and(|id|id!=reply.session)||reply.code!=want)&&failure.is_none(){
                failure=Some(format!("program reply {:?} at offset={} total={}; no image was published",reply.code,reply.next,reply.total));
            }
            replies+=1;if replies>cells.len(){return Err("unexpected extra program reply".into());}last_reply=Some(reply);
        }
        if !moved{thread::sleep(Duration::from_millis(1));}
    }
    if let Some(error)=failure{return Err(error.into());}
    let reply=last_reply.ok_or("missing program reply")?;
    if reply.next!=last{return Err("program offset mismatch".into());}Ok(reply)
}
fn open_port(port:Option<&str>)->Result<File> {
    let path=if let Some(p)=port{p.to_owned()}else{
        let mut p=[0i8;256];if unsafe{wk_image_path(p.as_mut_ptr(),p.len())}!=1{return Err("one verified CH32 host file port is required".into());}
        unsafe{CStr::from_ptr(p.as_ptr())}.to_str()?.to_owned()
    };
    let p=CString::new(path)?;let fd=unsafe{wk_image_open(p.as_ptr())};if fd<0{return Err("verified program port unavailable or already owned".into());}
    Ok(unsafe{File::from_raw_fd(fd)})
}
fn diagnostic(file:&mut File)->Result<()> {
    let query=Frame{operation:DIAGNOSTIC,session:0,offset:0,total:0,checksum:0,body:&[]}.encode().unwrap();
    file.write_all(&query)?;let mut ack=[0;CELL];let mut used=0;
    let deadline=Instant::now()+Duration::from_secs(3);
    while used<CELL&&Instant::now()<deadline {
        match file.read(&mut ack[used..]){Ok(n)=>used+=n,Err(e)if e.kind()==ErrorKind::WouldBlock=>(),Err(e)=>return Err(e.into())}
        if used<CELL{thread::sleep(Duration::from_millis(1));}
    }
    let d=decode_diagnostic(&ack).ok_or("RAM diagnostic unsupported or incomplete")?;
    println!("CABLE_RAM_STATUS version={} ready={} stage={} fault_offset={} expected={} actual={} clock={} ctrl={:#x} timing={:#x} latency={:#x} cmd1={:#x} mr0={:#x} mr2={:#x} mr4={:#x} blocks={} extra_register={:#x}",
        d[0],d[1],d[2],d[3],d[4],d[5],d[6],d[7],d[8],d[9],d[10],d[11],d[12],d[13],d[14],d[15]);Ok(())
}
fn checked(file:&mut File,cells:&[[u8;CELL]],session:Option<u64>,last:u32,want:Code)->Result<Reply> {
    match transact(file,cells,session,last,want) {
        Ok(reply)=>Ok(reply),Err(error)=>{if let Err(e)=diagnostic(file){eprintln!("CABLE_RAM_DIAGNOSTIC_ERROR {e}");}Err(error)}
    }
}
fn load(a:&[u8],port:Option<&str>)->Result<()> {
    let mut file=open_port(port)?;let total=a.len() as u32;let checksum=crc32(a);
    // QUERY may return either a fresh or an immutable existing image. Read it
    // separately so a reconnect can reuse the exact same published program.
    let query=Frame{operation:QUERY,session:0,offset:0,total:0,checksum:0,body:&[]}.encode().unwrap();
    file.write_all(&query)?;
    let deadline=Instant::now()+Duration::from_secs(3);let mut ack=[0;CELL];let mut used=0;
    while used<CELL&&Instant::now()<deadline{match file.read(&mut ack[used..]){Ok(n)=>used+=n,Err(e)if e.kind()==ErrorKind::WouldBlock=>(),Err(e)=>return Err(e.into())}if used<CELL{thread::sleep(Duration::from_millis(1));}}
    let old=Reply::decode(&ack).ok_or("program query failed; firmware support required")?;
    if old.code==Code::Sealed {
        if old.total==total&&old.checksum==checksum{println!("CABLE_IMAGE_READY bytes={total} reused=true");return Ok(());}
        return Err("a different program is in use; refusing to replace its mounted source volume".into());
    }
    if old.code!=Code::Accepted{let _=diagnostic(&mut file);return Err(format!("program RAM unavailable: {:?}",old.code).into());}
    if old.session!=0 {
        let abort=Frame{operation:ABORT,session:old.session,offset:old.next,total:old.total,checksum:old.checksum,body:&[]}.encode().unwrap();
        checked(&mut file,&[abort],None,0,Code::Accepted)?;
    }
    let session=(SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos() as u64).max(1);
    let frame=|operation,offset,body|Frame{operation,session,offset,total,checksum,body}.encode().unwrap();
    checked(&mut file,&[frame(BEGIN,0,&[])],Some(session),0,Code::Accepted)?;
    let started=Instant::now();let mut offset=0;
    for batch in a.chunks(BODY*16) {
        let cells:Vec<_>=batch.chunks(BODY).enumerate().map(|(n,b)|frame(DATA,offset+(n*BODY) as u32,b)).collect();
        offset+=batch.len() as u32;checked(&mut file,&cells,Some(session),offset,Code::Accepted)?;
    }
    checked(&mut file,&[frame(FINISH,total,&[])],Some(session),total,Code::Sealed)?;
    println!("CABLE_IMAGE_READY bytes={total} seconds={:.3} reused=false",started.elapsed().as_secs_f64());Ok(())
}
fn run()->Result<()> {
    let args:Vec<_>=std::env::args().skip(1).collect();
    if args==["--diagnose"]{return diagnostic(&mut open_port(None)?);}
    if args.len()!=2&&args.len()!=4{return Err("usage: wiredkvm-cable-loader --check-image ASSET | --load ASSET [--port VERIFIED_CH32_FILE_PORT]".into());}
    if !["--check-image","--load"].contains(&args[0].as_str())||args.len()==4&&(args[0]!="--load"||args[2]!="--port"){return Err("invalid loader options".into());}
    let asset=read_asset(Path::new(&args[1]))?;validate(&asset)?;
    if args[0]=="--check-image"{println!("CABLE_IMAGE_VALID bytes={} usb_opened=false",asset.len());Ok(())}
    else{load(&asset,args.get(3).map(String::as_str))}
}
fn main(){if let Err(e)=run(){eprintln!("CABLE_IMAGE_ERROR {e}");std::process::exit(1);}}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::{fd::IntoRawFd,unix::net::UnixStream};
    #[test]
    fn windowed_upload_handles_fragmented_acknowledgements() {
        let (a,mut b)=UnixStream::pair().unwrap();a.set_nonblocking(true).unwrap();
        let mut file=unsafe{File::from_raw_fd(a.into_raw_fd())};
        let worker=thread::spawn(move||{
            for _ in 0..16 {
                let mut cell=[0;CELL];b.read_exact(&mut cell).unwrap();let f=Frame::decode(&cell).unwrap();
                let ack=Reply{code:Code::Accepted,session:f.session,next:f.offset+f.body.len() as u32,total:f.total,checksum:f.checksum}.encode();
                for part in ack.chunks(73){b.write_all(part).unwrap();}
            }
        });
        let body=[9;BODY];let cells:Vec<_>=(0..16).map(|n|Frame{operation:DATA,session:17,offset:n*BODY as u32,total:16*BODY as u32,checksum:123,body:&body}.encode().unwrap()).collect();
        let reply=transact(&mut file,&cells,Some(17),16*BODY as u32,Code::Accepted).unwrap();
        assert_eq!(reply.next,16*BODY as u32);worker.join().unwrap();
    }
    #[test]
    fn a_stale_reply_cannot_complete_a_new_upload() {
        let (a,mut b)=UnixStream::pair().unwrap();a.set_nonblocking(true).unwrap();let mut file=unsafe{File::from_raw_fd(a.into_raw_fd())};
        let worker=thread::spawn(move||{let mut cell=[0;CELL];b.read_exact(&mut cell).unwrap();
            b.write_all(&Reply{code:Code::Accepted,session:16,next:0,total:4096,checksum:123}.encode()).unwrap();});
        let cell=Frame{operation:BEGIN,session:17,offset:0,total:4096,checksum:123,body:&[]}.encode().unwrap();
        assert!(transact(&mut file,&[cell],Some(17),0,Code::Accepted).is_err());worker.join().unwrap();
    }
    #[test]
    fn storage_failure_reports_offset_and_drains_the_bounded_window() {
        let (a,mut b)=UnixStream::pair().unwrap();a.set_nonblocking(true).unwrap();let mut file=unsafe{File::from_raw_fd(a.into_raw_fd())};
        let worker=thread::spawn(move||{
            for i in 0..16 {
                let mut cell=[0;CELL];b.read_exact(&mut cell).unwrap();let f=Frame::decode(&cell).unwrap();
                b.write_all(&Reply{code:if i==2{Code::Storage}else{Code::Accepted},session:71,next:f.offset,total:f.total,checksum:9}.encode()).unwrap();
            }
            let mut cell=[0;CELL];b.read_exact(&mut cell).unwrap();assert_eq!(Frame::decode(&cell).unwrap().operation,DIAGNOSTIC);
            b.write_all(&diagnostic_reply(&[0;DIAGNOSTIC_WORDS])).unwrap();
        });
        let body=[0;BODY];let cells:Vec<_>=(0..16).map(|i|Frame{operation:DATA,session:71,offset:i*BODY as u32,total:20000,checksum:9,body:&body}.encode().unwrap()).collect();
        let error=transact(&mut file,&cells,Some(71),16*BODY as u32,Code::Accepted).unwrap_err().to_string();
        assert!(error.contains("Storage at offset=952"));diagnostic(&mut file).unwrap();worker.join().unwrap();
    }
}
