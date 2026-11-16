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
#[derive(Debug)]
struct ReplyFailure { reply: Reply }
impl std::fmt::Display for ReplyFailure {
    fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result {
        write!(f,"program reply {:?} at offset={} total={}; no image was published",
            self.reply.code,self.reply.next,self.reply.total)
    }
}
impl std::error::Error for ReplyFailure {}
const IO_TIMEOUT:Duration=Duration::from_secs(3);
const RECOVERY_POLL:Duration=Duration::from_millis(20);

/// Finish every submitted cell's response before allowing another command.
/// A valid Storage reply is retained while later cells in that window drain.
fn transact(file:&mut File,cells:&[[u8;CELL]],session:Option<u64>,last:u32,want:Code)->Result<Reply> {
    let replies=exchange(file,cells)?;
    let mut failure=None;
    for (cell,reply) in cells.iter().zip(&replies) {
        let sent=Frame::decode(cell).ok_or("invalid outgoing program cell")?;
        if session.is_some_and(|id|id!=reply.session) {
            // A stale reply must never become permission to reset memory.
            if failure.is_none(){return Err("stale program acknowledgement".into());}
            continue;
        }
        if reply.code!=want {
            if failure.is_none() {
                if reply.total!=sent.total||reply.checksum!=sent.checksum||
                    (reply.code==Code::Storage&&reply.next!=sent.offset) {
                    return Err("program acknowledgement identity mismatch".into());
                }
                failure=Some(*reply);
            }
        } else if failure.is_none() && sent.operation!=ABORT {
            let next=sent.offset+sent.body.len() as u32;
            if reply.total!=sent.total||reply.checksum!=sent.checksum||reply.next!=next {
                return Err("program acknowledgement content mismatch".into());
            }
        }
    }
    if let Some(reply)=failure{return Err(Box::new(ReplyFailure{reply}));}
    let reply=*replies.last().ok_or("missing program reply")?;
    if reply.next!=last{return Err("program offset mismatch".into());}Ok(reply)
}
fn exchange(file:&mut File,cells:&[[u8;CELL]])->Result<Vec<Reply>> {
    exchange_until(file,cells,Instant::now()+IO_TIMEOUT)
}
fn exchange_until(file:&mut File,cells:&[[u8;CELL]],deadline:Instant)->Result<Vec<Reply>> {
    let responses=exchange_bytes_until(file,cells,deadline)?;
    responses.iter().map(|b|Reply::decode(b).ok_or_else(||"invalid program acknowledgement".into())).collect()
}
fn exchange_bytes_until(file:&mut File,cells:&[[u8;CELL]],deadline:Instant)->Result<Vec<[u8;CELL]>> {
    let bytes:Vec<u8>=cells.iter().flatten().copied().collect();let mut written=0;let mut incoming=Vec::new();
    let mut responses=Vec::new();let mut buffer=[0;CELL*16];
    while written<bytes.len()||responses.len()<cells.len() {
        if Instant::now()>=deadline{return Err("program channel timeout; input channel was not opened".into());}
        let mut moved=false;
        if written<bytes.len(){match file.write(&bytes[written..]){
            Ok(0)=>return Err("program USB disconnected".into()),Ok(n)=>{written+=n;moved=true},
            Err(e)if matches!(e.kind(),ErrorKind::WouldBlock|ErrorKind::Interrupted)=>(),Err(e)=>return Err(e.into())}}
        match file.read(&mut buffer){Ok(n)if n>0=>{incoming.extend_from_slice(&buffer[..n]);moved=true},Ok(_)=>(),
            Err(e)if matches!(e.kind(),ErrorKind::WouldBlock|ErrorKind::Interrupted)=>(),Err(e)=>return Err(e.into())}
        while incoming.len()>=CELL {
            responses.push(incoming[..CELL].try_into().unwrap());incoming.drain(..CELL);
            if responses.len()>cells.len(){return Err("unexpected extra program reply".into());}
        }
        if !moved{thread::sleep(Duration::from_millis(1));}
    }
    if !incoming.is_empty(){return Err("partial extra program reply".into());}
    Ok(responses)
}
fn zero_cell(operation:u8)->[u8;CELL] {
    Frame{operation,session:0,offset:0,total:0,checksum:0,body:&[]}.encode().unwrap()
}
fn idle(reply:&Reply)->bool {reply.session==0&&reply.next==0&&reply.total==0&&reply.checksum==0}
fn query(file:&mut File)->Result<Reply> {query_until(file,Instant::now()+IO_TIMEOUT)}
fn query_until(file:&mut File,deadline:Instant)->Result<Reply> {
    let reply=exchange_until(file,&[zero_cell(QUERY)],deadline)?[0];
    if reply.code==Code::Unavailable && !idle(&reply){return Err("invalid unavailable snapshot".into());}
    Ok(reply)
}
fn open_port(port:Option<&str>)->Result<File> {
    let path=if let Some(p)=port{p.to_owned()}else{
        let mut p=[0i8;256];if unsafe{wk_image_path(p.as_mut_ptr(),p.len())}!=1{return Err("one verified CH32 host file port is required".into());}
        unsafe{CStr::from_ptr(p.as_ptr())}.to_str()?.to_owned()
    };
    let p=CString::new(path)?;let fd=unsafe{wk_image_open(p.as_ptr())};if fd<0{return Err("verified program port unavailable or already owned".into());}
    Ok(unsafe{File::from_raw_fd(fd)})
}
fn diagnostic(file:&mut File)->Result<[u32;DIAGNOSTIC_WORDS]> {diagnostic_until(file,Instant::now()+IO_TIMEOUT)}
fn diagnostic_until(file:&mut File,deadline:Instant)->Result<[u32;DIAGNOSTIC_WORDS]> {
    let ack=exchange_bytes_until(file,&[zero_cell(DIAGNOSTIC)],deadline)?;
    let d=decode_diagnostic(&ack[0]).ok_or("RAM diagnostic unsupported or incomplete")?;
    println!("CABLE_RAM_STATUS version={} ready={} stage={} fault_offset={} expected={} actual={} clock={} ctrl={:#x} timing={:#x} latency={:#x} cmd1={:#x} mr0={:#x} mr2={:#x} mr4={:#x} blocks={} extra_register={:#x}",
        d[0],d[1],d[2],d[3],d[4],d[5],d[6],d[7],d[8],d[9],d[10],d[11],d[12],d[13],d[14],d[15]);Ok(d)
}
fn recovery_supported(d:&[u32;DIAGNOSTIC_WORDS])->Result<()> {
    if d[0]<3{return Err("automatic RAM recovery requires updated firmware; input remains active".into());}
    if d[1]!=0||!matches!(d[2],1|2|4|5){return Err("RAM recovery unavailable or budget exhausted; input remains active".into());}
    Ok(())
}
fn recover(file:&mut File,attempts:&mut usize)->Result<()> {
    while *attempts<MAX_RECOVERIES as usize {
        let d=diagnostic(file)?;
        if d[0]>=3&&d[1]==1&&d[2]==3 {
            // The polling firmware may finish between QUERY and DIAGNOSTIC.
            let reply=query(file)?;
            if reply.code==Code::Accepted&&idle(&reply){return Ok(());}
            return Err("RAM became ready with a different source state".into());
        }
        recovery_supported(&d)?;
        *attempts+=1;
        let reply=exchange(file,&[zero_cell(RECOVER)])?[0];
        if !idle(&reply)||!matches!(reply.code,Code::Accepted|Code::Busy) {
            return Err("RAM recovery refused; source volume was not reset".into());
        }
        println!("CABLE_RAM_RECOVERY attempt={} started=true",*attempts);
        let deadline=Instant::now()+IO_TIMEOUT;
        loop {
            if Instant::now()>=deadline{return Err("RAM recovery timed out; input remains active".into());}
            let reply=query_until(file,deadline)?;
            if reply.code==Code::Accepted && idle(&reply) {
                println!("CABLE_RAM_RECOVERY attempt={} ready=true",*attempts);return Ok(());
            }
            if reply.code!=Code::Unavailable{return Err("RAM recovery state changed; refusing to overwrite source volume".into());}
            let d=diagnostic_until(file,deadline)?;
            if d[0]>=3&&d[1]==1&&d[2]==3{continue;}
            recovery_supported(&d)?;
            if d[2]!=5{break;}
            thread::sleep(RECOVERY_POLL);
        }
    }
    Err("RAM recovery attempts exhausted; input remains active".into())
}
fn upload(file:&mut File,a:&[u8],session:u64)->Result<()> {
    let total=a.len() as u32;let checksum=crc32(a);
    let frame=|operation,offset,body|Frame{operation,session,offset,total,checksum,body}.encode().unwrap();
    transact(file,&[frame(BEGIN,0,&[])],Some(session),0,Code::Accepted)?;
    let mut offset=0;
    for batch in a.chunks(BODY*16) {
        let cells:Vec<_>=batch.chunks(BODY).enumerate().map(|(n,b)|frame(DATA,offset+(n*BODY) as u32,b)).collect();
        offset+=batch.len() as u32;transact(file,&cells,Some(session),offset,Code::Accepted)?;
    }
    transact(file,&[frame(FINISH,total,&[])],Some(session),total,Code::Sealed)?;Ok(())
}
fn load_on_port(file:&mut File,a:&[u8])->Result<()> {
    let total=a.len() as u32;let checksum=crc32(a);let mut attempts=0;
    let started=Instant::now();
    let nonce=(SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos() as u64).max(1);
    loop {
        // A published source is immutable, including across controller restarts.
        let old=query(file)?;
        match old.code {
            Code::Sealed=>{
                if old.total==total&&old.checksum==checksum&&old.next==total&&old.session!=0 {
                    println!("CABLE_IMAGE_READY bytes={total} reused=true");return Ok(());
                }
                return Err("a different program is in use; refusing to replace its mounted source volume".into());
            }
            Code::Unavailable=>{recover(file,&mut attempts)?;continue;}
            Code::Accepted=>(),
            _=>return Err(format!("unexpected program snapshot: {:?}",old.code).into()),
        }
        if old.session!=0 {
            let abort=Frame{operation:ABORT,session:old.session,offset:old.next,total:old.total,checksum:old.checksum,body:&[]}.encode().unwrap();
            let reply=transact(file,&[abort],None,0,Code::Accepted)?;
            if !idle(&reply){return Err("incomplete upload abort was not confirmed".into());}
        } else if !idle(&old) {return Err("invalid empty program snapshot".into());}
        let session=nonce.wrapping_add(attempts as u64).max(1);
        match upload(file,a,session) {
            Ok(())=>{println!("CABLE_IMAGE_READY bytes={total} seconds={:.3} reused=false",started.elapsed().as_secs_f64());return Ok(());}
            Err(error)=>{
                // Only a CRC-valid, same-session Storage response after draining
                // its bounded window permits recovery. I/O/stale/format errors do not.
                if error.downcast_ref::<ReplyFailure>().is_some_and(|e|e.reply.code==Code::Storage) {
                    recover(file,&mut attempts)?;
                } else {return Err(error);}
            }
        }
    }
}
fn load(a:&[u8],port:Option<&str>)->Result<()> {load_on_port(&mut open_port(port)?,a)}
fn run()->Result<()> {
    let args:Vec<_>=std::env::args().skip(1).collect();
    if args==["--diagnose"]{return diagnostic(&mut open_port(None)?).map(|_|());}
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
                b.write_all(&Reply{code:if i==2{Code::Storage}else{Code::Accepted},session:71,next:if i==2{f.offset}else{f.offset+f.body.len() as u32},total:f.total,checksum:9}.encode()).unwrap();
            }
            let mut cell=[0;CELL];b.read_exact(&mut cell).unwrap();assert_eq!(Frame::decode(&cell).unwrap().operation,DIAGNOSTIC);
            b.write_all(&diagnostic_reply(&[0;DIAGNOSTIC_WORDS])).unwrap();
        });
        let body=[0;BODY];let cells:Vec<_>=(0..16).map(|i|Frame{operation:DATA,session:71,offset:i*BODY as u32,total:20000,checksum:9,body:&body}.encode().unwrap()).collect();
        let error=transact(&mut file,&cells,Some(71),16*BODY as u32,Code::Accepted).unwrap_err().to_string();
        assert!(error.contains("Storage at offset=952"));diagnostic(&mut file).unwrap();worker.join().unwrap();
    }

    #[derive(Default)]
    struct DeviceConfig {
        initial_fault:bool, failures:usize, old_firmware:bool, recovery_fails:bool,
        sealed:bool, different_sealed:bool, stale_storage:bool, corrupt_reply:bool, stall_reply:bool,
        complete_on_diagnostic:bool,
    }
    #[derive(Default,Debug)]
    struct DeviceStats { recoveries:usize, begins:usize, first_offsets:Vec<u32>, image:Vec<u8> }
    struct DeviceMemory { bytes:Vec<u8>, ready:bool, failures:usize, starts:Vec<u32> }
    impl Memory for DeviceMemory {
        fn available(&self)->bool{self.ready}
        fn write_verified(&mut self,at:u32,data:&[u8])->bool{
            if at==0{self.starts.push(at);}
            if self.failures>0&&at>=BODY as u32 {
                self.failures-=1;self.ready=false;return false;
            }
            self.bytes[at as usize..at as usize+data.len()].copy_from_slice(data);true
        }
    }
    fn test_asset()->Vec<u8> {
        let payload:Vec<_>=(0..6144).map(|n|(n*37) as u8).collect();
        let mut a=vec![255;IMAGE_OFFSET as usize];a[..8].copy_from_slice(b"WKDUAL01");
        a[8..12].copy_from_slice(&1u32.to_le_bytes());a[12..16].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        a[16..20].copy_from_slice(&crc32(&payload).to_le_bytes());let check=crc32(&a[..20]);
        a[20..24].copy_from_slice(&check.to_le_bytes());a.extend(payload);a
    }
    fn device_test(config:DeviceConfig)->(Result<()>,DeviceStats) {
        let asset=test_asset();validate(&asset).unwrap();let expected=asset.clone();
        let (a,mut b)=UnixStream::pair().unwrap();a.set_nonblocking(true).unwrap();
        b.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut file=unsafe{File::from_raw_fd(a.into_raw_fd())};
        let worker=thread::spawn(move||{
            let mut upload=Upload::new();let mut stats=DeviceStats::default();let mut pending=0;
            let mut memory=DeviceMemory{bytes:vec![0;CAPACITY as usize],ready:!config.initial_fault,failures:config.failures,starts:vec![]};
            if config.sealed {
                memory.ready=true;
                let total=expected.len() as u32;let checksum=crc32(&expected);
                let frame=|operation,offset,body|Frame{operation,session:71,offset,total,checksum,body}.encode().unwrap();
                upload.accept(0,&frame(BEGIN,0,&[]),&mut memory);
                for(i,data)in expected.chunks(BODY).enumerate(){upload.accept(0,&frame(DATA,(i*BODY) as u32,data),&mut memory);}
                assert_eq!(upload.accept(0,&frame(FINISH,total,&[]),&mut memory).code,Code::Sealed);
                memory.starts.clear();
            }
            loop {
                let mut cell=[0;CELL];
                match b.read_exact(&mut cell) {
                    Ok(())=>(),Err(error)if error.kind()==ErrorKind::UnexpectedEof=>break,
                    Err(error)=>panic!("device socket: {error}"),
                }
                let frame=Frame::decode(&cell).unwrap();
                let ack=if frame.operation==DIAGNOSTIC {
                    if config.complete_on_diagnostic&&pending>0 {pending=0;memory.ready=true;}
                    let mut d=[0;DIAGNOSTIC_WORDS];d[0]=if config.old_firmware{2}else{3};d[1]=memory.ready as u32;
                    d[2]=if pending>0{5}else if memory.ready{3}else if stats.recoveries>=MAX_RECOVERIES as usize{6}else{4};
                    diagnostic_reply(&d)
                }else if frame.operation==RECOVER {
                    assert_eq!((frame.session,frame.offset,frame.total,frame.checksum,frame.body.len()),(0,0,0,0,0));
                    assert!(!config.old_firmware);assert!(upload.published_bytes().is_none());stats.recoveries+=1;
                    pending=2;Reply{code:Code::Busy,session:0,next:0,total:0,checksum:0}.encode()
                }else {
                    if frame.operation==QUERY&&pending>0 {
                        pending-=1;
                        if pending==0{memory.ready=!config.recovery_fails;}
                    }
                    if frame.operation==BEGIN{stats.begins+=1;}
                    let mut reply=upload.accept(0,&cell,&mut memory);
                    if config.different_sealed&&reply.code==Code::Sealed{reply.checksum^=1;}
                    if config.stale_storage&&reply.code==Code::Storage{reply.session=reply.session.wrapping_add(1);}
                    let mut ack=reply.encode();
                    if config.corrupt_reply&&frame.operation==BEGIN{ack[19]^=1;}
                    if config.stall_reply&&frame.operation==BEGIN {
                        // A short closed response is an I/O failure, not evidence
                        // that a hardware reset is safe.
                        b.write_all(&ack[..7]).unwrap();break;
                    }
                    ack
                };
                for part in ack.chunks(73){if b.write_all(part).is_err(){break;}}
            }
            stats.first_offsets=memory.starts;stats.image=memory.bytes[..expected.len()].to_vec();stats
        });
        let result=load_on_port(&mut file,&asset);drop(file);(result,worker.join().unwrap())
    }
    #[test]
    fn latched_initial_fault_recovers_then_uploads_complete_image() {
        let (result,stats)=device_test(DeviceConfig{initial_fault:true,..Default::default()});
        result.unwrap();assert_eq!(stats.recoveries,1);assert_eq!(stats.begins,1);
        assert_eq!(stats.image,test_asset());
    }
    #[test]
    fn recovery_completing_between_query_and_diagnostic_is_not_rejected() {
        let (result,stats)=device_test(DeviceConfig{initial_fault:true,complete_on_diagnostic:true,..Default::default()});
        result.unwrap();assert_eq!(stats.recoveries,1);assert_eq!(stats.begins,1);
        assert_eq!(stats.image,test_asset());
    }
    #[test]
    fn mid_window_storage_failure_is_drained_and_restarts_at_zero() {
        let (result,stats)=device_test(DeviceConfig{failures:1,..Default::default()});
        result.unwrap();assert_eq!(stats.recoveries,1);assert_eq!(stats.begins,2);
        assert_eq!(stats.first_offsets,vec![0,0]);assert_eq!(stats.image,test_asset());
    }
    #[test]
    fn repeated_storage_faults_exhaust_local_recovery_budget() {
        let (result,stats)=device_test(DeviceConfig{failures:3,..Default::default()});
        assert!(result.unwrap_err().to_string().contains("attempts exhausted"));
        assert_eq!(stats.recoveries,MAX_RECOVERIES as usize);assert_eq!(stats.begins,3);
    }
    #[test]
    fn persistent_initialization_fault_is_bounded() {
        let (result,stats)=device_test(DeviceConfig{initial_fault:true,recovery_fails:true,..Default::default()});
        assert!(result.is_err());assert_eq!(stats.recoveries,MAX_RECOVERIES as usize);assert_eq!(stats.begins,0);
    }
    #[test]
    fn sealed_source_is_reused_without_recovery_or_write() {
        let (result,stats)=device_test(DeviceConfig{sealed:true,..Default::default()});
        result.unwrap();assert_eq!(stats.recoveries,0);assert_eq!(stats.begins,0);
        assert_eq!(stats.first_offsets.len(),0);assert_eq!(stats.image,test_asset());
    }
    #[test]
    fn different_sealed_source_is_refused_without_recovery_or_write() {
        let (result,stats)=device_test(DeviceConfig{sealed:true,different_sealed:true,..Default::default()});
        assert!(result.unwrap_err().to_string().contains("different program is in use"));
        assert_eq!(stats.recoveries,0);assert_eq!(stats.begins,0);assert_eq!(stats.image,test_asset());
    }
    #[test]
    fn old_firmware_is_reported_without_sending_reset() {
        let (result,stats)=device_test(DeviceConfig{initial_fault:true,old_firmware:true,..Default::default()});
        assert!(result.unwrap_err().to_string().contains("requires updated firmware"));assert_eq!(stats.recoveries,0);
    }
    #[test]
    fn stale_storage_reply_does_not_authorize_memory_recovery() {
        let (result,stats)=device_test(DeviceConfig{failures:1,stale_storage:true,..Default::default()});
        assert!(result.is_err());assert_eq!(stats.recoveries,0);assert_eq!(stats.begins,1);
    }
    #[test]
    fn corrupt_reply_does_not_authorize_memory_recovery() {
        let (result,stats)=device_test(DeviceConfig{corrupt_reply:true,..Default::default()});
        assert!(result.is_err());assert_eq!(stats.recoveries,0);assert_eq!(stats.begins,1);
    }
    #[test]
    fn partial_response_timeout_does_not_authorize_memory_recovery() {
        let started=Instant::now();
        let (result,stats)=device_test(DeviceConfig{stall_reply:true,..Default::default()});
        assert!(result.is_err());assert_eq!(stats.recoveries,0);assert!(started.elapsed()<Duration::from_secs(4));
    }
}
