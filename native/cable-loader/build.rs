use std::{env,path::PathBuf,process::Command};
fn main() {
    assert_eq!(env::var("CARGO_CFG_TARGET_OS").unwrap(),"macos");
    let out=PathBuf::from(env::var_os("OUT_DIR").unwrap());
    assert!(Command::new("cc").args(["-O2","-Wall","-Wextra","-Werror","-c","src/macos.c","-o"]).arg(out.join("macos.o")).status().unwrap().success());
    assert!(Command::new("ar").arg("rcs").arg(out.join("libwkloader.a")).arg(out.join("macos.o")).status().unwrap().success());
    println!("cargo:rustc-link-search=native={}",out.display());println!("cargo:rustc-link-lib=static=wkloader");
    for f in ["IOKit","CoreFoundation"]{println!("cargo:rustc-link-lib=framework={f}");}
    println!("cargo:rerun-if-changed=src/macos.c");
}
