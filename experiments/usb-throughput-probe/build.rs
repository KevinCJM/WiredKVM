use std::{env,path::PathBuf,process::Command};
fn main() {
    if env::var("CARGO_CFG_TARGET_OS").unwrap()!="macos" { return; }
    let out=PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let arch=if env::var("CARGO_CFG_TARGET_ARCH").unwrap()=="aarch64" {"arm64"} else {"x86_64"};
    assert!(Command::new("cc").args(["-arch",arch,"-mmacosx-version-min=13.0","-O2","-Wall","-Wextra","-Werror","-c","src/macos.c","-o"]).arg(out.join("macos.o")).status().unwrap().success());
    assert!(Command::new("cc").args(["-arch",arch,"-mmacosx-version-min=13.0","-O2","-Wall","-Wextra","-Werror","-Wno-deprecated-declarations","-c","src/raw_macos.c","-o"]).arg(out.join("raw_macos.o")).status().unwrap().success());
    assert!(Command::new("ar").arg("rcs").arg(out.join("libwkprobe.a")).arg(out.join("macos.o")).arg(out.join("raw_macos.o")).status().unwrap().success());
    println!("cargo:rustc-link-search=native={}",out.display());println!("cargo:rustc-link-lib=static=wkprobe");
    for f in ["IOKit","CoreFoundation"] { println!("cargo:rustc-link-lib=framework={f}"); }
    println!("cargo:rerun-if-changed=src/macos.c");
    println!("cargo:rerun-if-changed=src/raw_macos.c");
}
