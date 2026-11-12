//! Explicit memory-only diagnostic. Blocking OS I/O provides backpressure;
//! no 1 ms timer, file I/O, clipboard, input injection or sleeping body loop.
use std::{fs::File,io::{Read,Write},time::Instant};
#[cfg(target_os="macos")]
use std::os::fd::{AsRawFd,FromRawFd};
type Result<T>=std::result::Result<T,Box<dyn std::error::Error>>;
#[cfg(target_os="macos")]
extern "C" {fn wk_probe_open(role:u32)->i32;fn wk_probe_wait(fd:i32,writing:i32,milliseconds:i32)->i32;fn alarm(seconds:u32)->u32;}
#[cfg(target_os="macos")]
extern "C" {
    fn wk_probe_raw_open(role:u32)->*mut std::ffi::c_void;
    fn wk_probe_raw_close(port:*mut std::ffi::c_void);
    fn wk_probe_raw_read(port:*mut std::ffi::c_void,bytes:*mut u8,size:u32,milliseconds:u32)->i64;
    fn wk_probe_raw_write(port:*mut std::ffi::c_void,bytes:*const u8,size:u32,milliseconds:u32)->i64;
}
trait ProbeIO:Read+Write {fn timeout(&mut self,milliseconds:u32)->std::io::Result<()>;}
#[cfg(target_os="macos")]
struct Port {file:File,milliseconds:u32}
#[cfg(target_os="macos")]
impl Port {
    fn wait(&self,writing:bool)->std::io::Result<()> {
        match unsafe{wk_probe_wait(self.file.as_raw_fd(),i32::from(writing),self.milliseconds as i32)} {
            1=>Ok(()),0=>Err(std::io::Error::new(std::io::ErrorKind::TimedOut,"USB file endpoint made no progress")),
            _=>Err(std::io::Error::last_os_error())
        }
    }
}
#[cfg(target_os="macos")]
impl Read for Port {
    fn read(&mut self,bytes:&mut [u8])->std::io::Result<usize>{loop{match self.file.read(bytes){Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>self.wait(false)?,Err(e) if e.kind()==std::io::ErrorKind::Interrupted=>continue,other=>return other}}}
}
#[cfg(target_os="macos")]
impl Write for Port {
    fn write(&mut self,bytes:&[u8])->std::io::Result<usize>{loop{match self.file.write(bytes){Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>self.wait(true)?,Err(e) if e.kind()==std::io::ErrorKind::Interrupted=>continue,other=>return other}}}
    fn flush(&mut self)->std::io::Result<()>{self.file.flush()}
}
#[cfg(target_os="macos")]
impl ProbeIO for Port {fn timeout(&mut self,milliseconds:u32)->std::io::Result<()>{self.milliseconds=milliseconds;Ok(())}}
#[cfg(target_os="macos")]
struct RawPort {handle:*mut std::ffi::c_void,milliseconds:u32}
#[cfg(target_os="macos")]
impl Drop for RawPort {fn drop(&mut self){unsafe{wk_probe_raw_close(self.handle)}}}
#[cfg(target_os="macos")]
impl Read for RawPort {
    fn read(&mut self,bytes:&mut[u8])->std::io::Result<usize>{
        if bytes.is_empty(){return Ok(0);}
        let started=Instant::now();
        loop {
            let left=self.milliseconds.saturating_sub(started.elapsed().as_millis().min(u128::from(u32::MAX)) as u32);
            if left==0{return Err(std::io::Error::new(std::io::ErrorKind::TimedOut,"raw Bulk read made no progress"));}
            let n=unsafe{wk_probe_raw_read(self.handle,bytes.as_mut_ptr(),bytes.len().min(65536) as u32,left)};
            if n<0{return Err(std::io::Error::last_os_error());}
            // A USB ZLP terminates a transfer; it is not a serial-stream EOF.
            if n>0{return Ok(n as usize);}
        }
    }
}
#[cfg(target_os="macos")]
impl Write for RawPort {
    fn write(&mut self,bytes:&[u8])->std::io::Result<usize>{
        if bytes.is_empty(){return Ok(0);}
        let n=unsafe{wk_probe_raw_write(self.handle,bytes.as_ptr(),bytes.len().min(65536) as u32,self.milliseconds)};
        if n<0{Err(std::io::Error::last_os_error())}else{Ok(n as usize)}
    }
    fn flush(&mut self)->std::io::Result<()>{Ok(())}
}
#[cfg(target_os="macos")]
impl ProbeIO for RawPort {fn timeout(&mut self,milliseconds:u32)->std::io::Result<()>{self.milliseconds=milliseconds;Ok(())}}
#[cfg(target_os="macos")]
enum Backend {Tty(Port),Raw(RawPort)}
#[cfg(target_os="macos")]
impl Read for Backend {fn read(&mut self,b:&mut[u8])->std::io::Result<usize>{match self{Self::Tty(p)=>p.read(b),Self::Raw(p)=>p.read(b)}}}
#[cfg(target_os="macos")]
impl Write for Backend {
    fn write(&mut self,b:&[u8])->std::io::Result<usize>{match self{Self::Tty(p)=>p.write(b),Self::Raw(p)=>p.write(b)}}
    fn flush(&mut self)->std::io::Result<()>{match self{Self::Tty(p)=>p.flush(),Self::Raw(p)=>p.flush()}}
}
#[cfg(target_os="macos")]
impl ProbeIO for Backend {fn timeout(&mut self,ms:u32)->std::io::Result<()>{match self{Self::Tty(p)=>p.timeout(ms),Self::Raw(p)=>p.timeout(ms)}}}
#[cfg(test)]
impl ProbeIO for std::os::unix::net::UnixStream {
    fn timeout(&mut self,milliseconds:u32)->std::io::Result<()>{let t=Some(std::time::Duration::from_millis(u64::from(milliseconds)));self.set_read_timeout(t)?;self.set_write_timeout(t)}
}
const BYTES:u64=64*1024*1024;
const BRIDGE_FORWARD:u64=0x574b425000000004;
const BRIDGE_REVERSE:u64=0x574b425000000005;
fn crc(bytes:&[u8])->u32 {let mut c=!0u32;for b in bytes{c^=u32::from(*b);for _ in 0..8{c=(c>>1)^if c&1!=0{0xedb88320}else{0};}}!c}
fn get64(b:&[u8],at:usize)->u64{u64::from_le_bytes(b[at..at+8].try_into().unwrap())}
fn command(mode:u8,nonce:u64,total:u64)->[u8;64]{
    let mut b=[0u8;64];b[..4].copy_from_slice(b"WKBP");b[4]=1;b[5]=mode;b[8..16].copy_from_slice(&nonce.to_le_bytes());b[16..24].copy_from_slice(&total.to_le_bytes());
    let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());b
}
#[derive(Debug)]
struct Report {code:u8,mode:u8,port:u8,nonce:u64,total:u64,received:u64,sent:u64,started:u32,ended:u32}
impl Report {
    fn decode(b:&[u8])->Result<Self>{
        if b.len()!=64||&b[..4]!=b"WKBR"||b[4]!=1||!(1..=4).contains(&b[5])||![0,1,2,4,5].contains(&b[6])||b[7]>1||b[48..60].iter().any(|x|*x!=0)||crc(&b[..60])!=u32::from_le_bytes(b[60..64].try_into()?){return Err("invalid benchmark reply".into());}
        let r=Self{code:b[5],mode:b[6],port:b[7],nonce:get64(b,8),total:get64(b,16),received:get64(b,24),sent:get64(b,32),started:u32::from_le_bytes(b[40..44].try_into()?),ended:u32::from_le_bytes(b[44..48].try_into()?)};
        if r.total>512*1024*1024||r.total%512!=0||r.received>r.total||r.sent>r.total{return Err("invalid benchmark counts".into());}Ok(r)
    }
    fn read(file:&mut impl Read)->Result<Self>{let mut b=[0;64];file.read_exact(&mut b)?;Self::decode(&b).map_err(|e|format!("{e}; reply header={:02x?}",&b[..8]).into())}
}
#[derive(Debug)]
struct StageTiming {
    admission_seconds:f64,first_byte_wait_seconds:f64,seconds:f64,mbps:f64,
    first_read_bytes:u64,timed_bytes:u64,completion_wait_seconds:f64,
    end_to_end_seconds:f64,firmware_milliseconds:u32,
    body_io_seconds:f64,body_plus_completion_seconds:f64,
}
fn stage(file:&mut impl ProbeIO,port:u8,mode:u8,nonce:u64,total:u64,physical:bool)->Result<()> {
    let origin=Instant::now();
    stage_with_clock(file,port,mode,nonce,total,physical,&mut||origin.elapsed().as_secs_f64()).map(|_|())
}
fn stage_with_clock(file:&mut impl ProbeIO,port:u8,mode:u8,nonce:u64,total:u64,physical:bool,clock:&mut impl FnMut()->f64)->Result<StageTiming> {
    println!("{{\"kind\":\"stage\",\"port\":{port},\"mode\":{mode},\"phase\":\"admission\",\"bytes\":{total}}}");
    std::io::stdout().flush()?;
    file.timeout(if mode==4||mode==5{70000}else{10000})?;
    let admission_began=clock();
    file.write_all(&command(mode,nonce,total)).map_err(|e|format!("port {port} mode {mode} command: {e}"))?;
    let start=Report::read(file).map_err(|e|format!("port {port} mode {mode} admission: {e}"))?;
    if start.code!=1||start.mode!=mode||start.port!=port||start.nonce!=nonce||start.total!=total{return Err(format!("benchmark admission rejected: {start:?}").into());}
    let admission_ended=clock();
    let phase=if mode==5{"rendezvous"}else{"body"};
    println!("{{\"kind\":\"stage\",\"port\":{port},\"mode\":{mode},\"phase\":\"{phase}\",\"bytes\":{total}}}");
    std::io::stdout().flush()?;
    // Receiver READY means only that this port is admitted. The sender may
    // still be completing its local stages: retain the rendezvous lease until
    // the first real body bytes arrive, then use the ordinary idle timeout.
    file.timeout(if mode==5{70000}else{10000})?;
    let sending=mode==1||mode==4;
    let mut body_started=None;let mut body_ended=admission_ended;let mut first_read_bytes=0;
    let mut remaining=total;let mut block=[0xa5;65536];
    let mut next_progress=16*1024*1024;
    while remaining>0 {
        let n=remaining.min(block.len() as u64) as usize;
        let transferred=if sending {
            if body_started.is_none(){body_started=Some(clock());}
            file.write_all(&block[..n]).map_err(|e|format!("port {port} mode {mode} send after {} bytes: {e}",total-remaining))?;
            body_ended=clock();n
        }else{
            // Inspect each OS read immediately. read_exact previously hid a
            // short abort report inside a 64 KiB request until the hard limit.
            let read=match file.read(&mut block[..n]){Err(e) if e.kind()==std::io::ErrorKind::Interrupted=>continue,value=>value.map_err(|e|format!("port {port} mode {mode} receive after {} bytes: {e}",total-remaining))?};
            if read==0{return Err(format!("benchmark body ended after {} of {total} bytes",total-remaining).into());}
            let read_returned=clock();
            if body_started.is_none(){body_started=Some(read_returned);first_read_bytes=read as u64;}
            body_ended=read_returned;
            if let Some(at)=block[..read].iter().position(|b|*b!=0xa5){
                let observed=total-remaining+at as u64;
                if block[at]==b'W'{
                    let mut marker=[0;64];let have=(read-at).min(marker.len());marker[..have].copy_from_slice(&block[at..at+have]);
                    if have<4{file.read_exact(&mut marker[have..4]).map_err(|e|format!("invalid body after {observed} bytes; partial marker: {e}"))?;}
                    if &marker[..4]==b"WKBR"{
                        let have=have.max(4);if have<64{file.read_exact(&mut marker[have..]).map_err(|e|format!("invalid body after {observed} bytes; partial report: {e}"))?;}
                        let report=Report::decode(&marker)?;
                        return Err(format!("benchmark body invalid or aborted after {observed} of {total} bytes; early device report: {report:?}").into());
                    }
                }
                return Err(format!("benchmark body invalid or aborted after {observed} of {total} bytes; prefix={:02x?}",&block[at..read.min(at+8)]).into());
            }read
        };
        if mode==5&&remaining==total{
            file.timeout(10000)?;
            println!("{{\"kind\":\"stage\",\"port\":{port},\"mode\":{mode},\"phase\":\"body\",\"bytes\":{total}}}");
            std::io::stdout().flush()?;
        }
        remaining-=transferred as u64;
        if total-remaining>=next_progress {
            println!("{{\"kind\":\"progress\",\"port\":{port},\"mode\":{mode},\"bytes\":{},\"total\":{total}}}",total-remaining);
            std::io::stdout().flush()?;next_progress+=16*1024*1024;
        }
    }
    println!("{{\"kind\":\"stage\",\"port\":{port},\"mode\":{mode},\"phase\":\"completion\",\"bytes\":{total}}}");
    std::io::stdout().flush()?;
    let finish=Report::read(file).map_err(|e|format!("port {port} mode {mode} completion: {e}"))?;
    let finished=clock();
    if finish.code!=2||finish.mode!=mode||finish.port!=port||finish.nonce!=nonce||finish.total!=total||
        (if mode==1||mode==4{finish.received}else{finish.sent})!=total{return Err(format!("benchmark did not complete: {finish:?}").into());}
    let body_started=body_started.unwrap_or(body_ended);
    let body_io_seconds=(body_ended-body_started).max(0.0);
    let body_plus_completion_seconds=(finished-body_started).max(0.0);
    // A successful OS write can only mean queued bytes. The default sender
    // rate must wait for the validated device completion report as well.
    let seconds=if sending{body_plus_completion_seconds}else{body_io_seconds};
    // The first receiver read may contain already queued data. Exclude it from
    // both the measured interval and its numerator instead of inflating MB/s.
    // A one-read boundary probe has no sustained-rate sample.
    let timed_bytes=if sending{total}else{total-first_read_bytes};
    let measured=timed_bytes>0&&seconds>0.0;
    let timing=StageTiming{
        admission_seconds:(admission_ended-admission_began).max(0.0),
        first_byte_wait_seconds:if sending{0.0}else{(body_started-admission_ended).max(0.0)},
        seconds,mbps:if measured{timed_bytes as f64/seconds/1e6}else{0.0},
        first_read_bytes,timed_bytes,completion_wait_seconds:(finished-body_ended).max(0.0),
        end_to_end_seconds:(finished-admission_began).max(0.0),
        firmware_milliseconds:finish.ended.wrapping_sub(finish.started),
        body_io_seconds,body_plus_completion_seconds,
    };
    let window=if sending{"first_write_call_to_validated_completion_report"}else{"first_read_return_to_last_read_return_excluding_first_read_bytes"};
    println!(concat!("{{\"kind\":\"memory-usb\",\"port\":{},\"mode\":{},\"bytes\":{},",
        "\"seconds\":{:.9},\"MBps\":{:.6},\"timedBytes\":{},\"firstReadBytes\":{},",
        "\"admissionSeconds\":{:.9},\"firstByteWaitSeconds\":{:.9},\"completionWaitSeconds\":{:.9},\"endToEndSeconds\":{:.9},",
        "\"bodyIOSeconds\":{:.9},\"bodyPlusCompletionSeconds\":{:.9},",
        "\"firmwareMilliseconds\":{},\"firmwareWindow\":\"device_ready_ack_to_device_body_completion\",\"firmwareIncludesRendezvous\":{},",
        "\"bodyWindow\":\"{}\",\"bodyRateMeasured\":{},\"measurementCompleted\":true,\"rateIncludesHostSchedulingAndValidation\":true,",
        "\"integrityLimit\":\"constant_A5_fixture_only_device_sink_counts_no_sequence_check\",\"hostPatternValidated\":{},\"sequenceIntegrityProven\":false,",
        "\"physicalUSB\":{},\"hardwareCeilingProven\":false}}"),
        port,mode,total,timing.seconds,timing.mbps,timing.timed_bytes,timing.first_read_bytes,
        timing.admission_seconds,timing.first_byte_wait_seconds,timing.completion_wait_seconds,timing.end_to_end_seconds,
        timing.body_io_seconds,timing.body_plus_completion_seconds,
        timing.firmware_milliseconds,mode==5,window,measured,!sending,physical);
    std::io::stdout().flush()?;Ok(timing)
}
fn query(file:&mut impl ProbeIO,port:u8,mode:u8)->Result<()> {
    file.timeout(10000)?;
    let mut b=command(7,0,0);b[6]=port;b[7]=mode;let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());file.write_all(&b)?;
    let r=Report::read(file)?;
    if r.code!=4||r.mode!=mode||r.port!=port||r.total!=BYTES||r.nonce!=1+u64::from(port)*256+u64::from(mode){return Err("peer link result unavailable".into());}
    let bytes=if mode==1{r.received}else{r.sent};let ms=r.ended.wrapping_sub(r.started);
    if bytes!=BYTES||ms==0{return Err("peer link result incomplete".into());}
    println!("{{\"kind\":\"peer-memory-usb\",\"port\":{port},\"mode\":{mode},\"bytes\":{bytes},\"firmwareMilliseconds\":{ms},\"MBps\":{:.6},\"hardwareCeilingProven\":false}}",bytes as f64/(ms as f64/1000.0)/1e6);Ok(())
}
fn run()->Result<()> {
    let args:Vec<_>=std::env::args().skip(1).collect();
    if args==["--describe"] {println!("{{\"deviceAccess\":false,\"clipboardAccess\":false,\"installed\":false,\"bytesPerStage\":{BYTES},\"maxSeconds\":240,\"backend\":\"CDC ACM / USB Bulk\"}}");return Ok(());}
    if args.len()!=3||args[0]!="--role"||!["host","target"].contains(&args[1].as_str())||!["--all","--raw-all","--local","--raw-local","--packet-boundaries","--peer-results"].contains(&args[2].as_str())||(args[2]=="--peer-results"&&args[1]!="host"){return Err("usage: --describe | --role host|target --all|--raw-all|--local|--raw-local|--packet-boundaries | --role host --peer-results".into());}
    let port=if args[1]=="host"{0}else{1};
    #[cfg(target_os="macos")]
    let mut file=unsafe{
        alarm(240);
        if args[2]=="--raw-local"||args[2]=="--raw-all" {
            let handle=wk_probe_raw_open(port.into());
            if handle.is_null(){return Err(format!("verified raw FILE interface unavailable (no seize attempted): {}",std::io::Error::last_os_error()).into());}
            println!("{{\"kind\":\"backend\",\"backend\":\"IOKit raw Bulk\",\"fileInterfaceOnly\":true,\"seize\":false}}");
            Backend::Raw(RawPort{handle,milliseconds:10000})
        } else {
            let fd=wk_probe_open(port.into());if fd<0{return Err("verified file interface unavailable or already owned".into());}
            Backend::Tty(Port{file:File::from_raw_fd(fd),milliseconds:10000})
        }
    };
    #[cfg(not(target_os="macos"))]
    return Err("diagnostic runner supports macOS only".into());
    #[cfg(target_os="macos")]
    {
        if args[2]=="--peer-results"{query(&mut file,1,1)?;query(&mut file,1,2)?;return Ok(());}
        if args[2]=="--packet-boundaries"{
            for total in [512,1024,4096]{stage(&mut file,port,2,0x57000000+total,total,true)?;}
            println!("{{\"kind\":\"packet-boundaries-complete\",\"port\":{port},\"bridgeMeasured\":false}}");return Ok(());
        }
        // A relay may start with one full packet rather than a 4 KiB burst.
        // Check that target case explicitly before the sustained measurements.
        if port==1&&(args[2]=="--all"||args[2]=="--raw-all"){stage(&mut file,port,2,0x57000200,512,true)?;}
        for mode in [1,2]{stage(&mut file,port,mode,1+u64::from(port)*256+u64::from(mode),BYTES,true)?;}
        if args[2]=="--local"||args[2]=="--raw-local"{println!("{{\"kind\":\"local-complete\",\"port\":{port},\"bridgeMeasured\":false}}");return Ok(());}
        if port==0{stage(&mut file,port,4,BRIDGE_FORWARD,BYTES,true)?;stage(&mut file,port,5,BRIDGE_REVERSE,BYTES,true)?;query(&mut file,1,1)?;query(&mut file,1,2)?;}
        else{stage(&mut file,port,5,BRIDGE_FORWARD,BYTES,true)?;stage(&mut file,port,4,BRIDGE_REVERSE,BYTES,true)?;}
        println!("{{\"kind\":\"complete\",\"port\":{port},\"allStagesPassed\":true}}");
    }
    Ok(())
}
fn main(){if let Err(e)=run(){eprintln!("USB_PROBE_ERROR {e}");std::process::exit(1);}}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(target_os="macos")]
    fn raw_backend_rejects_invalid_requests_without_device_access(){
        unsafe {
            assert!(wk_probe_raw_open(2).is_null());
            assert_eq!(wk_probe_raw_read(std::ptr::null_mut(),std::ptr::null_mut(),512,1000),-1);
            assert_eq!(wk_probe_raw_write(std::ptr::null_mut(),std::ptr::null(),512,1000),-1);
            wk_probe_raw_close(std::ptr::null_mut());
        }
    }
    #[test]fn checksum_standard_vector(){assert_eq!(crc(b"123456789"),0xcbf43926);}
    #[test]
    #[cfg(target_os="macos")]
    fn os_readiness_wait_times_out_when_no_bytes_move(){
        use std::os::{fd::IntoRawFd,unix::net::UnixStream};
        let (client,_peer)=UnixStream::pair().unwrap();client.set_nonblocking(true).unwrap();
        let mut port=Port{file:unsafe{File::from_raw_fd(client.into_raw_fd())},milliseconds:30};
        let mut byte=[0];assert_eq!(port.read(&mut byte).unwrap_err().kind(),std::io::ErrorKind::TimedOut);
        // A stopped reader must also bound a writer under real OS backpressure.
        let block=[0xa5;65536];let mut stopped=false;
        for _ in 0..512{if let Err(e)=port.write_all(&block){assert_eq!(e.kind(),std::io::ErrorKind::TimedOut);stopped=true;break;}}
        assert!(stopped,"write did not encounter OS backpressure");
    }
    #[test]fn command_is_fixed_and_reserved_fields_are_empty(){let b=command(4,91,BYTES);assert_eq!(&b[..4],b"WKBP");assert_eq!(get64(&b,8),91);assert_eq!(get64(&b,16),BYTES);assert!(b[24..60].iter().all(|b|*b==0));assert_eq!(crc(&b[..60]),u32::from_le_bytes(b[60..64].try_into().unwrap()));}
    #[test]fn malformed_reply_never_becomes_success(){for n in [0,1,63,64,65,512]{assert!(Report::decode(&vec![0;n]).is_err());}let mut b=[0;64];b[..4].copy_from_slice(b"WKBR");b[4]=1;b[5]=2;b[6]=1;let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());assert!(Report::decode(&b).is_ok());b[24]=1;let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());assert!(Report::decode(&b).is_err());}
    #[test]fn short_abort_is_reported_without_waiting_for_the_rest_of_body(){
        use std::{os::unix::net::UnixStream,thread};
        let (mut client,mut peer)=UnixStream::pair().unwrap();
        client.set_read_timeout(Some(std::time::Duration::from_millis(500))).unwrap();
        let helper=thread::spawn(move||{
            let mut cmd=[0;64];peer.read_exact(&mut cmd).unwrap();
            let mut ready=[0;64];ready[..4].copy_from_slice(b"WKBR");ready[4]=1;ready[5]=1;ready[6]=2;
            ready[8..16].copy_from_slice(&91u64.to_le_bytes());ready[16..24].copy_from_slice(&65536u64.to_le_bytes());
            let c=crc(&ready[..60]);ready[60..64].copy_from_slice(&c.to_le_bytes());peer.write_all(&ready).unwrap();
            peer.write_all(&[0xa5;512]).unwrap();
            let mut abort=ready;abort[5]=3;let c=crc(&abort[..60]);abort[60..64].copy_from_slice(&c.to_le_bytes());peer.write_all(&abort).unwrap();
            // Keep the peer open: EOF must not be needed to detect this abort.
            let mut until_client_drops=[0;1];assert_eq!(peer.read(&mut until_client_drops).unwrap(),0);
        });
        let error=stage(&mut client,0,2,91,65536,false).unwrap_err().to_string();
        assert!(error.contains("body invalid or aborted"),"{error}");
        drop(client);helper.join().unwrap();
    }
    #[test]
    fn bridge_receiver_keeps_rendezvous_timeout_until_first_body_bytes(){
        // No sleeping: the scripted peer requires a 20 s admission-to-body gap.
        // A 10 s first-body timeout fails deterministically; completion must
        // return to the ordinary timeout once the first data is accepted.
        struct LatePeer{reads:usize,timeouts:Vec<u32>,written:Vec<u8>}
        fn report(code:u8)->[u8;64]{
            let mut b=[0;64];b[..4].copy_from_slice(b"WKBR");b[4]=1;b[5]=code;b[6]=5;b[7]=1;
            b[8..16].copy_from_slice(&91u64.to_le_bytes());b[16..24].copy_from_slice(&512u64.to_le_bytes());
            if code==2{b[32..40].copy_from_slice(&512u64.to_le_bytes());}
            let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());b
        }
        impl Read for LatePeer{
            fn read(&mut self,b:&mut [u8])->std::io::Result<usize>{
                let n=match self.reads{
                    0=>{assert_eq!(b.len(),64);b.copy_from_slice(&report(1));64},
                    1=>{
                        if self.timeouts.last().copied().unwrap_or(0)<20000{
                            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut,"peer still in local stage"));
                        }
                        assert_eq!(b.len(),512);b.fill(0xa5);512
                    },
                    2=>{assert_eq!(self.timeouts.last(),Some(&10000));assert_eq!(b.len(),64);b.copy_from_slice(&report(2));64},
                    _=>panic!("unexpected extra read")
                };self.reads+=1;Ok(n)
            }
        }
        impl Write for LatePeer{
            fn write(&mut self,b:&[u8])->std::io::Result<usize>{self.written.extend_from_slice(b);Ok(b.len())}
            fn flush(&mut self)->std::io::Result<()>{Ok(())}
        }
        impl ProbeIO for LatePeer{
            fn timeout(&mut self,ms:u32)->std::io::Result<()>{self.timeouts.push(ms);Ok(())}
        }
        let mut peer=LatePeer{reads:0,timeouts:Vec::new(),written:Vec::new()};
        let mut samples=[0.0,0.001,20.001,20.003].into_iter();
        let t=stage_with_clock(&mut peer,1,5,91,512,false,&mut||samples.next().unwrap()).unwrap();
        assert_eq!(t.timed_bytes,0);assert_eq!(t.first_read_bytes,512);
        assert_eq!(t.seconds,0.0);assert_eq!(t.mbps,0.0);
        assert!((t.body_plus_completion_seconds-0.002).abs()<1e-9);
        assert!(samples.next().is_none());
        assert_eq!(peer.timeouts,[70000,70000,10000]);
        assert_eq!(peer.written,command(5,91,512));assert_eq!(peer.reads,3);
    }
    #[test]
    fn bridge_rate_excludes_twenty_second_peer_wait(){
        // Injected monotonic samples model 20 s waiting and 0.1 s receiving.
        // The test does no waiting and exercises the same report calculation.
        struct Peer{reads:usize,timeout:u32}
        fn report(code:u8)->[u8;64]{
            let mut b=[0;64];b[..4].copy_from_slice(b"WKBR");b[4]=1;b[5]=code;b[6]=5;b[7]=1;
            b[8..16].copy_from_slice(&91u64.to_le_bytes());b[16..24].copy_from_slice(&1024u64.to_le_bytes());
            b[40..44].copy_from_slice(&100u32.to_le_bytes());
            if code==2{b[32..40].copy_from_slice(&1024u64.to_le_bytes());b[44..48].copy_from_slice(&20200u32.to_le_bytes());}
            let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());b
        }
        impl Read for Peer{
            fn read(&mut self,b:&mut [u8])->std::io::Result<usize>{
                let n=match self.reads{
                    0=>{b.copy_from_slice(&report(1));64},
                    1=>{assert_eq!(self.timeout,70000);b[..512].fill(0xa5);512},
                    2=>{assert_eq!(self.timeout,10000);b[..512].fill(0xa5);512},
                    3=>{b.copy_from_slice(&report(2));64},
                    _=>panic!("unexpected read")
                };self.reads+=1;Ok(n)
            }
        }
        impl Write for Peer{
            fn write(&mut self,b:&[u8])->std::io::Result<usize>{Ok(b.len())}
            fn flush(&mut self)->std::io::Result<()>{Ok(())}
        }
        impl ProbeIO for Peer{
            fn timeout(&mut self,ms:u32)->std::io::Result<()>{self.timeout=ms;Ok(())}
        }
        let mut peer=Peer{reads:0,timeout:0};
        let mut samples=[0.0,0.001,20.001,20.101,20.103].into_iter();
        let t=stage_with_clock(&mut peer,1,5,91,1024,false,&mut||samples.next().unwrap()).unwrap();
        assert!((t.admission_seconds-0.001).abs()<1e-9);
        assert!((t.first_byte_wait_seconds-20.0).abs()<1e-9);
        assert!((t.seconds-0.1).abs()<1e-9);
        assert_eq!(t.timed_bytes,512);assert_eq!(t.first_read_bytes,512);
        assert!((t.mbps-0.00512).abs()<1e-9);
        assert!((t.completion_wait_seconds-0.002).abs()<1e-9);
        assert!((t.end_to_end_seconds-20.103).abs()<1e-9);
        assert_eq!(t.firmware_milliseconds,20100);assert!(samples.next().is_none());
    }
    #[test]
    fn sender_rate_waits_for_validated_completion_not_only_os_write(){
        struct Peer{reads:usize,writes:usize}
        impl Read for Peer{
            fn read(&mut self,b:&mut [u8])->std::io::Result<usize>{
                assert_eq!(b.len(),64);b.fill(0);b[..4].copy_from_slice(b"WKBR");b[4]=1;
                b[5]=if self.reads==0{1}else{2};b[6]=1;
                b[8..16].copy_from_slice(&91u64.to_le_bytes());b[16..24].copy_from_slice(&512u64.to_le_bytes());
                if self.reads==1{b[24..32].copy_from_slice(&512u64.to_le_bytes());}
                let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());self.reads+=1;Ok(64)
            }
        }
        impl Write for Peer{
            fn write(&mut self,b:&[u8])->std::io::Result<usize>{self.writes+=1;Ok(b.len())}
            fn flush(&mut self)->std::io::Result<()>{Ok(())}
        }
        impl ProbeIO for Peer{fn timeout(&mut self,_ms:u32)->std::io::Result<()>{Ok(())}}
        let mut peer=Peer{reads:0,writes:0};
        let mut samples=[0.0,0.001,0.002,0.003,0.103].into_iter();
        let t=stage_with_clock(&mut peer,0,1,91,512,false,&mut||samples.next().unwrap()).unwrap();
        assert!((t.body_io_seconds-0.001).abs()<1e-9);
        assert!((t.seconds-0.101).abs()<1e-9);
        assert!((t.completion_wait_seconds-0.100).abs()<1e-9);
        assert!((t.mbps-512.0/0.101/1e6).abs()<1e-9);
        assert_eq!(t.timed_bytes,512);assert_eq!(t.first_read_bytes,0);
        assert_eq!(peer.writes,2);assert_eq!(peer.reads,2);assert!(samples.next().is_none());
    }
    #[test]fn blocking_io_handles_fragmented_replies_and_checks_body(){
        use std::{os::unix::net::UnixStream,thread};
        for mode in [1,2,4,5]{
            let (mut client,mut peer)=UnixStream::pair().unwrap();let total=65536+512;
            let helper=thread::spawn(move||{
                let mut cmd=[0;64];peer.read_exact(&mut cmd).unwrap();assert_eq!(cmd,command(mode,91,total));
                let report=|code|{let mut b=[0;64];b[..4].copy_from_slice(b"WKBR");b[4]=1;b[5]=code;b[6]=mode;b[8..16].copy_from_slice(&91u64.to_le_bytes());b[16..24].copy_from_slice(&total.to_le_bytes());if code==2{let at=if mode==1||mode==4{24}else{32};b[at..at+8].copy_from_slice(&total.to_le_bytes());}let c=crc(&b[..60]);b[60..64].copy_from_slice(&c.to_le_bytes());b};
                for b in report(1).chunks(3){peer.write_all(b).unwrap();}
                let mut remaining=total;let mut b=[0xa5;509];
                while remaining>0{let n=remaining.min(b.len() as u64) as usize;if mode==1||mode==4{peer.read_exact(&mut b[..n]).unwrap();assert!(b[..n].iter().all(|b|*b==0xa5));}else{peer.write_all(&b[..n]).unwrap();}remaining-=n as u64;}
                for b in report(2).chunks(7){peer.write_all(b).unwrap();}
            });
            stage(&mut client,0,mode,91,total,false).unwrap();helper.join().unwrap();
        }
    }
}
