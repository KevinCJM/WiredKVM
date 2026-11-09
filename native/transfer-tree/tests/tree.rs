use wiredkvm_transfer_tree::*;
use std::{fs, path::PathBuf, sync::{Arc, atomic::{AtomicU64, Ordering}}, os::unix::fs::{symlink, FileExt}};

static NEXT: AtomicU64 = AtomicU64::new(0);
// Keep fixtures for inspection; never run recursive test cleanup.
fn fixture() -> PathBuf {
    let root=std::env::temp_dir().join(format!("wk-tree-{}-{}", std::process::id(),NEXT.fetch_add(1,Ordering::Relaxed)));
    fs::create_dir(&root).unwrap(); root
}
fn token()->Arc<Cancellation>{Arc::new(Cancellation::default())}
fn capture(p:&[PathBuf])->Tree{Tree::capture(p,token()).unwrap()}

#[test] fn nested_multiple_roots_unicode_empty_and_binary() {
    let root=fixture(); let folder=root.join("照片 🎈"); fs::create_dir(&folder).unwrap();
    fs::create_dir(folder.join("empty")).unwrap(); fs::create_dir(folder.join("nested")).unwrap();
    fs::write(folder.join("nested/二进制.bin"),[0,255,3,4,0]).unwrap(); fs::write(folder.join("zero.txt"),[]).unwrap();
    let text=root.join("hello.txt"); fs::write(&text,b"hello\0world").unwrap();
    let tree=capture(&[folder,text]);
    let parsed=Manifest::decode(tree.manifest_bytes()).unwrap(); assert_eq!(parsed,tree.manifest);
    assert_eq!(parsed.roots,2); assert_eq!(parsed.entries.len(),6); assert_eq!(parsed.payload_size,16);
    let mut bytes=Vec::new(); let mut buf=[0;7];
    while bytes.len()<(tree.size() as usize){let n=tree.read(bytes.len() as u64,&mut buf).unwrap(); assert!(n>0);bytes.extend_from_slice(&buf[..n]);}
    assert_eq!(&bytes[..tree.manifest_bytes().len()],tree.manifest_bytes());
    assert_eq!(&bytes[tree.manifest_bytes().len()..],b"\x00\xff\x03\x04\x00hello\0world");
    assert_eq!(tree.read(tree.size(),&mut buf).unwrap(),0); tree.verify().unwrap();
}
#[test] fn sparse_large_offset_is_not_truncated() {
    let root=fixture(); let path=root.join("large.bin"); let f=fs::File::create(&path).unwrap();
    let offset=5u64*1024*1024*1024+7; f.set_len(offset+3).unwrap();f.write_all_at(b"end",offset).unwrap();drop(f);
    let tree=capture(&[path]);let mut bytes=[0;3];tree.read(tree.manifest_bytes().len() as u64+offset,&mut bytes).unwrap();assert_eq!(&bytes,b"end");
}
#[test] fn replacement_symlink_special_and_mutation_fail() {
    let root=fixture();let folder=root.join("folder");fs::create_dir(&folder).unwrap();let file=folder.join("data");fs::write(&file,b"safe").unwrap();
    let outside=root.join("outside");fs::write(&outside,b"secret").unwrap();let tree=capture(&[folder.clone()]);
    fs::rename(&file,folder.join("old")).unwrap();symlink(&outside,&file).unwrap();
    let mut out=[0;4];assert!(tree.read(tree.manifest_bytes().len() as u64,&mut out).is_err()); assert!(tree.verify().is_err());
    assert!(Tree::capture(&[folder],token()).is_err());
    let mutating=root.join("mutable");fs::write(&mutating,b"0000").unwrap();let tree=capture(&[mutating.clone()]);
    fs::write(&mutating,b"111111").unwrap();assert!(tree.read(tree.manifest_bytes().len() as u64,&mut out).is_err());
}
#[test] fn directory_replacement_never_follows_new_parent() {
    let root=fixture();let folder=root.join("folder");fs::create_dir(&folder).unwrap();fs::create_dir(folder.join("child")).unwrap();
    fs::write(folder.join("child/data"),b"safe").unwrap();let other=root.join("other");fs::create_dir(&other).unwrap();fs::write(other.join("data"),b"secret").unwrap();
    let tree=capture(&[folder.clone()]);fs::rename(folder.join("child"),folder.join("retired")).unwrap();symlink(other,folder.join("child")).unwrap();
    assert!(tree.read(tree.manifest_bytes().len() as u64,&mut [0;4]).is_err());
}
#[test] fn cancellation_does_not_block_new_transfer() {
    let root=fixture();let file=root.join("a");fs::write(&file,b"0123456789").unwrap();let t=token();let tree=Tree::capture(&[file.clone()],t.clone()).unwrap();
    t.cancel();assert!(matches!(tree.read(0,&mut[0;4]),Err(Error::Cancelled)));assert!(matches!(tree.verify(),Err(Error::Cancelled)));
    assert!(matches!(Tree::capture(&[file.clone()],t),Err(Error::Cancelled)));let next=capture(&[file]);assert!(next.read(0,&mut[0;4]).is_ok());
}
#[test] fn bad_manifests_duplicates_traversal_overflow_and_truncation() {
    let good=Manifest{roots:1,payload_size:5,entries:vec![Entry{path:"folder".into(),kind:Kind::Directory,size:0,offset:0},Entry{path:"folder/data".into(),kind:Kind::File,size:5,offset:0}]};
    let bytes=good.encode().unwrap();for n in 0..bytes.len(){assert!(Manifest::decode(&bytes[..n]).is_err());}
    let mut extra=bytes.clone();extra.push(0);assert!(Manifest::decode(&extra).is_err());
    for path in ["/abs","../parent","folder/../escape","folder//empty","folder/./dot","folder/evil\\name","folder/control\n"]{
        let mut m=good.clone();m.entries[1].path=path.into();assert!(m.encode().is_err(),"{path}");
    }
    let mut m=good.clone();m.entries[1].size=u64::MAX;m.payload_size=u64::MAX;assert!(m.encode().is_err());
    let mut m=good.clone();m.entries[1].offset=1;assert!(m.encode().is_err());
    let mut m=good.clone();m.entries.push(m.entries[1].clone());assert!(m.encode().is_err());
    let mut m=good.clone();m.entries[0].kind=Kind::File;assert!(m.encode().is_err());
    let mut m=good.clone();m.entries[1].path="missing/data".into();assert!(m.encode().is_err());
    let mut m=good.clone();m.roots=2;assert!(m.encode().is_err());
    let mut m=good.clone();m.entries[1].path=std::iter::repeat_n("a",65).collect::<Vec<_>>().join("/");assert!(m.encode().is_err());
    let mut m=good;m.entries[1].path="folder/".to_owned()+&"a".repeat(256);assert!(m.encode().is_err());
}
#[test] fn duplicates_and_case_aliases_rejected() {
    let root=fixture();let file=root.join("one");fs::write(&file,b"1").unwrap();assert!(Tree::capture(&[file.clone(),file],token()).is_err());
    let m=Manifest{roots:2,payload_size:0,entries:vec![Entry{path:"A".into(),kind:Kind::File,size:0,offset:0},Entry{path:"a".into(),kind:Kind::File,size:0,offset:0}]};assert!(m.encode().is_err());
}
#[test] fn invalid_utf8_special_file_and_read_bounds() {
    use std::ffi::CString;unsafe extern "C"{fn mkfifo(path:*const std::ffi::c_char,mode:u16)->i32;}
    let root=fixture();let fifo=root.join("pipe");let p=CString::new(fifo.to_str().unwrap()).unwrap();assert_eq!(unsafe{mkfifo(p.as_ptr(),0o600)},0);
    assert!(Tree::capture(&[fifo],token()).is_err());
    let file=root.join("ok");fs::write(&file,b"1").unwrap();let tree=capture(&[file]);assert!(tree.read(tree.size()+1,&mut[0;1]).is_err());assert!(tree.read(0,&mut vec![0;MAX_READ+1]).is_err());
    let mut m=tree.manifest_bytes().to_vec();*m.last_mut().unwrap()=0xff;assert!(Manifest::decode(&m).is_err());
}
#[test] fn decoder_malformed_fuzz_never_panics() {
    let m=Manifest{roots:1,payload_size:0,entries:vec![Entry{path:"file".into(),kind:Kind::File,size:0,offset:0}]};let wire=m.encode().unwrap();
    for i in 0..wire.len(){for b in [0,1,2,32,128,255]{let mut v=wire.clone();v[i]=b;let _=Manifest::decode(&v);}}
    let mut s=7u64;for n in 0..1000{let mut v=vec![0;n%256];for x in &mut v{s=s.wrapping_mul(6364136223846793005).wrapping_add(1);*x=(s>>32)as u8;}let _=Manifest::decode(&v);}
}
#[test] fn many_files_and_bounded_cross_file_reads() {
    let root=fixture();let folder=root.join("many");fs::create_dir(&folder).unwrap();
    for n in 0..1200{fs::write(folder.join(format!("{n:04}.bin")),[(n%251)as u8;9]).unwrap();}
    let tree=capture(&[folder]);assert_eq!(tree.manifest.entries.len(),1201);
    let mut all=vec![0;10800];let n=tree.read(tree.manifest_bytes().len()as u64,&mut all).unwrap();assert_eq!(n,all.len());
    for n in 0..1200{assert_eq!(&all[n*9..n*9+9],&[(n%251)as u8;9]);}tree.verify().unwrap();
}
