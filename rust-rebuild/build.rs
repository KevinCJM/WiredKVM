//! Compile only the recovered, audited memory-only C simulator into OUT_DIR.
//! No shell, historical script, executable probe, device access, or cleanup.
use std::{env, path::Path, process::Command};

fn run(tool: &str, arguments: &[&std::ffi::OsStr], cwd: &Path) {
    let status = Command::new(tool)
        .args(arguments)
        .current_dir(cwd)
        // Clang temporary outputs must also stay in Cargo's own OUT_DIR.
        .env("TMPDIR", cwd)
        .status()
        .unwrap_or_else(|error| panic!("cannot run {tool}: {error}"));
    assert!(status.success(), "{tool} failed: {status}");
}

fn main() {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let parent = manifest.parent().unwrap();
    // Recovery uses the snapshot; the restored project uses the same verified
    // bridge sources at their normal project paths.
    let source = if parent.join("firmware/ch32v407/bridge.c").is_file() {
        parent.to_path_buf()
    } else {
        parent.join("verified-at-snapshot")
    }.canonicalize().unwrap();
    let out = std::path::PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR missing"))
        .canonicalize()
        .expect("Cargo OUT_DIR must exist");
    assert!(out.is_absolute() && out != source && !source.starts_with(&out));
    let includes = [
        source.join("firmware/ch32v407"),
        source.join("firmware/main"),
        source.join("tests"),
    ];
    let sources = [
        "firmware/ch32v407/bridge.c",
        "firmware/main/wire_protocol.c",
        "tests/ch32v407_sim.c",
    ];
    let mut objects = Vec::new();
    for (index, relative) in sources.into_iter().enumerate() {
        let input = source.join(relative);
        let object = out.join(format!("bridge_source_{index}.o"));
        println!("cargo:rerun-if-changed={}", input.display());
        let mut args = vec![
            std::ffi::OsStr::new("-std=c11"),
            "-O2".as_ref(),
            "-Wall".as_ref(),
            "-Wextra".as_ref(),
            "-Werror".as_ref(),
            "-c".as_ref(),
            input.as_os_str(),
            "-o".as_ref(),
            object.as_os_str(),
        ];
        for include in &includes {
            args.push("-I".as_ref());
            args.push(include.as_os_str());
        }
        run("/usr/bin/clang", &args, &out);
        objects.push(object);
    }
    for relative in [
        "firmware/ch32v407/bridge.h",
        "firmware/main/wire_protocol.h",
        "tests/ch32v407_sim.h",
    ] {
        println!("cargo:rerun-if-changed={}", source.join(relative).display());
    }
    let archive = out.join("libwiredkvm_recovered_bridge.a");
    let mut args = vec![std::ffi::OsStr::new("crs"), archive.as_os_str()];
    args.extend(objects.iter().map(|path| path.as_os_str()));
    run("/usr/bin/ar", &args, &out);
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=wiredkvm_recovered_bridge");
}
