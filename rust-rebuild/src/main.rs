//! Recovery build entry point. It never starts the resulting controller,
//! touches a USB device, changes permissions, or deletes a file.
use std::{env, fs, path::{Path, PathBuf}, process::{self, Command}};
mod firmware_build;

const CLIPBOARD: &[&str] = &[
    "WKClipboardProtocol", "WKOnboarding", "WKFnKey", "WKScrollRelay", "WKGestureRelay", "WKInputRelay",
    "WKStreamFiles", "WKClipboardContent", "WKClipboardTransport", "WKFilePortal",
    "WKClipboardSelfTest", "WKFilePipelineSelfTest", "WKOnDemandClipboard",
    "WKCompanionInstall", "WiredKVMCompanion",
];

fn required() -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = ["native/wiredkvm.cpp", "native/wk_protocol.hpp",
        "native/iphone_edge.hpp", "native/desktop_pointer.hpp", "native/exchange_service.hpp",
        "native/file_transfer_runtime.hpp", "native/clipboard_channel.hpp", "host/macos_capture.swift",
        "host/WKPointingSource.swift", "host/gui/WiredKVMClipboard.swift", "host/ch32v407_host.swift"]
        .iter().map(PathBuf::from).collect();
    paths.extend(CLIPBOARD.iter().map(|name| PathBuf::from(format!("host/clipboard/{name}.swift"))));
    paths
}

fn source_root(path: &Path) -> Result<PathBuf, String> {
    let root = path.canonicalize().map_err(|e| format!("source directory: {e}"))?;
    for file in required() {
        let path = root.join(&file);
        let actual = path.canonicalize().map_err(|e| format!("missing {}: {e}", file.display()))?;
        if !actual.starts_with(&root) || !actual.is_file() {
            return Err(format!("source must be a file inside the source root: {}", file.display()));
        }
    }
    Ok(root)
}

fn compile(command: &mut Command, label: &str) -> Result<(), String> {
    println!("BUILD {label}");
    let status = command.status().map_err(|e| format!("{label}: {e}"))?;
    if !status.success() { return Err(format!("{label} failed: {status}; artifacts retained")); }
    Ok(())
}

fn swift(output: &Path) -> Command {
    let mut command = Command::new("/usr/bin/swiftc");
    command.args(["-O", "-target"])
        .arg(format!("{}-apple-macosx13.0", if cfg!(target_arch = "aarch64") { "arm64" } else { "x86_64" }))
        .arg("-module-cache-path").arg(output.join("swift-cache"))
        .args(["-framework", "AppKit", "-framework", "IOKit", "-framework", "ServiceManagement", "-lcompression"]);
    command
}

fn build_macos(root: &Path, destination: &Path) -> Result<(), String> {
    if !cfg!(target_os = "macos") { return Err("build-macos requires macOS".into()); }
    let root = source_root(root)?;
    if destination.file_name().is_none() { return Err("output must name a new directory".into()); }
    // Exclusive creation prevents overwriting an earlier build or a user directory.
    fs::create_dir(destination).map_err(|e| format!("output must be a new directory: {e}"))?;
    let output = destination.canonicalize().map_err(|e| e.to_string())?;
    fs::create_dir(output.join("capture-source")).map_err(|e| e.to_string())?;
    fs::copy(root.join("host/macos_capture.swift"), output.join("capture-source/main.swift"))
        .map_err(|e| format!("capture source copy: {e}"))?;
    let mut native = Command::new("/usr/bin/clang++");
    native.args(["-std=c++17", "-O2", "-Wall", "-Wextra", "-Wpedantic", "-Werror", "-mmacosx-version-min=13.0"])
        .arg(root.join("native/wiredkvm.cpp")).arg("-o").arg(output.join("wiredkvm-native"));
    compile(&mut native, "native")?;
    let mut capture = swift(&output);
    capture.args(["-framework", "ApplicationServices", "-framework", "Cocoa", "-D", "WK_PIXEL_SCROLL"])
        .arg(output.join("capture-source/main.swift"))
        .arg(root.join("host/clipboard/WKScrollRelay.swift"))
        .arg(root.join("host/clipboard/WKGestureRelay.swift"))
        .arg(root.join("host/WKPointingSource.swift"))
        .arg("-o").arg(output.join("macos-capture"));
    compile(&mut capture, "capture")?;
    for (name, host) in [("wiredkvm-companion", false), ("wiredkvm-ch32-host", true)] {
        let mut command = swift(&output);
        command.arg("-parse-as-library");
        if host { command.args(["-D", "WK_CH32_TEST"]); }
        for source in CLIPBOARD { command.arg(root.join(format!("host/clipboard/{source}.swift"))); }
        if host {
            command.arg(root.join("host/gui/WiredKVMClipboard.swift"))
                .arg(root.join("host/ch32v407_host.swift"));
        }
        command.arg("-o").arg(output.join(name));
        compile(&mut command, name)?;
    }
    println!("BUILD_OK {} (not launched; no tests executed)", output.display());
    Ok(())
}

fn run() -> Result<(), String> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    match args.as_slice() {
        [verb, root] if verb == "check-sources" => {
            let root = source_root(Path::new(root))?;
            println!("SOURCE_FILES_PRESENT {} (not a functional or integrity test)", root.display()); Ok(())
        }
        [verb, root, output] if verb == "build-macos" => build_macos(Path::new(root), Path::new(output)),
        [verb, root, sdk, prefix, output] if verb == "build-petros" => firmware_build::build(
            Path::new(root), Path::new(sdk), Path::new(prefix), Path::new(output)),
        [] => { println!("Usage:\n  wiredkvm-offline-regression check-sources SOURCE_ROOT\n  wiredkvm-offline-regression build-macos SOURCE_ROOT NEW_OUTPUT_DIRECTORY\n  wiredkvm-offline-regression build-petros SOURCE_ROOT PATCHED_SDK COMPILER_PREFIX NEW_OUTPUT_DIRECTORY\n\nOffline regression: cargo test --offline\nNo command opens USB, launches a controller, or deletes files."); Ok(()) }
        _ => Err("invalid arguments; run without arguments for usage".into()),
    }
}

fn main() { if let Err(error) = run() { eprintln!("ERROR: {error}"); process::exit(1); } }
