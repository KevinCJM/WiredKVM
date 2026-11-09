#![cfg(all(feature="c-abi",feature="ram-setup"))]
use std::sync::Mutex;
use wiredkvm_cable_image::*;
use wiredkvm_mt2_protocol_draft::ram_setup::*;
static RAM:Mutex<Vec<u8>>=Mutex::new(Vec::new());
static FORWARDED:Mutex<Vec<u8>>=Mutex::new(Vec::new());
#[no_mangle] extern "C" fn wk_cable_platform_ready()->i32{1}
#[no_mangle] unsafe extern "C" fn wk_cable_platform_diagnostic(p:*mut u32,n:usize){
    assert_eq!(n,16);let out=std::slice::from_raw_parts_mut(p,n);out.fill(0);out[0]=1;out[3]=476;
}
#[no_mangle] unsafe extern "C" fn wk_cable_platform_write(at:u32,p:*const u8,n:usize)->i32{
    RAM.lock().unwrap()[at as usize..at as usize+n].copy_from_slice(std::slice::from_raw_parts(p,n));1
}
#[no_mangle] unsafe extern "C" fn wk_cable_forward(p:*const u8,n:usize){FORWARDED.lock().unwrap().extend_from_slice(std::slice::from_raw_parts(p,n));}

#[test] fn fragmented_program_cells_and_normal_bulk_remain_separate() {
    *RAM.lock().unwrap()=vec![0;CAPACITY as usize];
    let diag=Frame{operation:DIAGNOSTIC,session:0,offset:0,total:0,checksum:0,body:&[]}.encode().unwrap();
    unsafe{wk_cable_setup_input(diag.as_ptr(),CELL);}
    let mut status=[0;CELL];assert_eq!(unsafe{wk_cable_setup_ack(status.as_mut_ptr(),CELL)},CELL);
    assert_eq!(decode_diagnostic(&status).unwrap()[3],476);assert_eq!(wk_cable_setup_size(),0);
    wk_cable_setup_ack_submitted();
    let image=vec![0x93;1536];let mut a=vec![255;IMAGE_OFFSET as usize];a[..8].copy_from_slice(b"WKDUAL01");
    a[8..12].copy_from_slice(&1u32.to_le_bytes());a[12..16].copy_from_slice(&(image.len() as u32).to_le_bytes());
    a[16..20].copy_from_slice(&crc32(&image).to_le_bytes());let c=crc32(&a[..20]);a[20..24].copy_from_slice(&c.to_le_bytes());a.extend(image);
    let make=|op,at,body:&[u8]|Frame{operation:op,session:371,offset:at,total:a.len() as u32,checksum:crc32(&a),body}.encode().unwrap();
    let mut normal=[0x27;CELL];normal[..4].copy_from_slice(b"WKS5");
    unsafe{wk_cable_setup_input(normal.as_ptr(),17);wk_cable_setup_input(normal[17..].as_ptr(),CELL-17);}
    assert_eq!(*FORWARDED.lock().unwrap(),normal);assert_eq!(wk_cable_setup_pending(),0);
    let mut cells=vec![make(BEGIN,0,&[])];
    for (n,b) in a.chunks(BODY).enumerate(){cells.push(make(DATA,(n*BODY) as u32,b));}
    cells.push(make(FINISH,a.len() as u32,&[]));
    for (index,cell) in cells.iter().enumerate(){
        for (n,chunk) in cell.chunks(61).enumerate(){
            unsafe{wk_cable_setup_input(chunk.as_ptr(),chunk.len());}
            if index==1&&n==2{wk_cable_setup_peer_reset();}
        }
        let mut ack=[0;CELL];assert_eq!(unsafe{wk_cable_setup_ack(ack.as_mut_ptr(),CELL)},CELL);
        let reply=Reply::decode(&ack).unwrap();assert_eq!(reply.session,371);
        assert_eq!(reply.code,if index+1==cells.len(){Code::Sealed}else{Code::Accepted});wk_cable_setup_ack_submitted();
        unsafe{wk_cable_setup_input(normal.as_ptr(),CELL);}
    }
    assert_eq!(&RAM.lock().unwrap()[..a.len()],a);
    assert_eq!(wk_cable_setup_size(),a.len() as u32);assert_eq!(wk_cable_setup_changed(),a.len() as u32);assert_eq!(wk_cable_setup_changed(),0);
    wk_cable_setup_reset();assert_eq!(wk_cable_setup_size(),a.len() as u32);
    assert_eq!(FORWARDED.lock().unwrap().len(),(cells.len()+1)*CELL);
    unsafe{wk_cable_setup_input(normal.as_ptr(),17);}
    wk_cable_setup_peer_reset();
    unsafe{wk_cable_setup_input(normal.as_ptr(),CELL);}
    assert_eq!(FORWARDED.lock().unwrap().len(),(cells.len()+2)*CELL);
}
