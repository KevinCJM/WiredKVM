use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=src/dir_list.c");
    let out=PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let target=env::var("TARGET").unwrap();
    let object=out.join("dir_list.o");let archive=out.join("libwk_tree_directory.a");
    let mut cc=Command::new("cc");cc.args(["-O2","-fPIC","-c","src/dir_list.c","-o"]).arg(&object);
    if target.contains("apple-darwin"){cc.args(["-target",&target]);}
    assert!(cc.status().unwrap().success(),"directory ABI adapter failed");
    assert!(Command::new("ar").arg("crs").arg(&archive).arg(&object).status().unwrap().success());
    println!("cargo:rustc-link-search=native={}",out.display());
    println!("cargo:rustc-link-lib=static=wk_tree_directory");
}
