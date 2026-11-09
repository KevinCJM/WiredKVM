//! New recovery build of the non-diagnostic Petros V467 firmware.
//! Uses a caller-verified, already-patched local SDK. No script, download,
//! USB access, execution of firmware, flashing, or deletion is performed.
use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::Write,
    path::{Component, Path, PathBuf},
    process::Command,
};

const STEM: &str = "wiredkvm-ch32v467-petros-recovered";
const FLAGS: &[&str] = &[
    "-march=rv32imac_zicsr_zifencei",
    "-mabi=ilp32",
    "-mcmodel=medany",
    "-msmall-data-limit=0",
    "-Os",
    "-g3",
    "-ffunction-sections",
    "-fdata-sections",
    "-fno-common",
    "-fno-strict-aliasing",
    "-mstrict-align",
];

fn canonical_directory(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    if !path.is_dir() {
        return Err(format!("not a directory: {}", path.display()));
    }
    Ok(path)
}

fn inside(path: &Path, roots: &[&Path]) -> Result<PathBuf, String> {
    let actual = path
        .canonicalize()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    if !roots.iter().any(|root| actual.starts_with(root)) {
        return Err(format!(
            "input escapes source/SDK roots: {}",
            path.display()
        ));
    }
    Ok(actual)
}

fn source_file(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let path = inside(&root.join(relative), &[root])?;
    if !path.is_file() {
        return Err(format!("not a regular source file: {}", path.display()));
    }
    Ok(path)
}

// Validate every project/SDK header reachable through include directories.
// This traverses metadata only; it neither copies nor executes those files.
// Standard C/newlib headers are provided by the explicitly selected compiler.
fn audit_include_tree(
    path: &Path,
    roots: &[&Path],
    seen: &mut BTreeSet<PathBuf>,
) -> Result<(), String> {
    let path = inside(path, roots)?;
    if !seen.insert(path.clone()) {
        return Ok(());
    }
    if path.is_dir() {
        for entry in fs::read_dir(&path).map_err(|e| format!("{}: {e}", path.display()))? {
            let entry = entry.map_err(|e| e.to_string())?;
            audit_include_tree(&entry.path(), roots, seen)?;
        }
    } else if !path.is_file() {
        return Err(format!(
            "non-regular input in include tree: {}",
            path.display()
        ));
    }
    Ok(())
}

fn audit_dependencies(
    file: &Path,
    includes: &[PathBuf],
    roots: &[&Path],
    seen: &mut BTreeSet<PathBuf>,
) -> Result<(), String> {
    let file = inside(file, roots)?;
    if !seen.insert(file.clone()) {
        return Ok(());
    }
    // These are the standard/newlib headers observed in this recovered source
    // closure. They are resolved by the named GCC toolchain, not a host path.
    const SYSTEM_HEADERS: &[&str] = &[
        "ctype.h",
        "errno.h",
        "limits.h",
        "reent.h",
        "stdatomic.h",
        "stdbool.h",
        "stddef.h",
        "stdint.h",
        "stdio.h",
        "stdlib.h",
        "string.h",
        "sys/types.h",
    ];
    for line in text(&file)?.lines() {
        let Some(directive) = line.trim_start().strip_prefix('#') else {
            continue;
        };
        let Some(argument) = directive.trim_start().strip_prefix("include") else {
            continue;
        };
        let argument = argument.trim_start();
        let (quoted, delimiter) = match argument.as_bytes().first() {
            Some(b'"') => (true, '"'),
            Some(b'<') => (false, '>'),
            _ => {
                return Err(format!(
                    "unrecognized include in {}: {line}",
                    file.display()
                ))
            }
        };
        let (name, _) = argument[1..]
            .split_once(delimiter)
            .ok_or_else(|| format!("unterminated include in {}", file.display()))?;
        if Path::new(name)
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err(format!(
                "include contains an absolute/parent path: {}: {name}",
                file.display()
            ));
        }
        let mut candidates = Vec::new();
        if quoted {
            candidates.push(file.parent().unwrap().join(name));
        }
        candidates.extend(includes.iter().map(|include| include.join(name)));
        if let Some(header) = candidates.into_iter().find(|path| path.is_file()) {
            audit_dependencies(&header, includes, roots, seen)?;
        } else if !SYSTEM_HEADERS.contains(&name) {
            return Err(format!(
                "unknown/missing dependency {} included by {}; review without guessing",
                name,
                file.display()
            ));
        }
    }
    Ok(())
}

fn text(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn require_marker(path: &Path, marker: &str) -> Result<(), String> {
    if !text(path)?.contains(marker) {
        return Err(format!(
            "unrecognized patched SDK input {}: missing {marker:?}",
            path.display()
        ));
    }
    Ok(())
}

fn replace_once(value: &mut String, before: &str, after: &str) -> Result<(), String> {
    if value.matches(before).count() != 1 {
        return Err(format!(
            "descriptor context must occur exactly once: {before}"
        ));
    }
    *value = value.replacen(before, after, 1);
    Ok(())
}

fn tool(prefix: &Path, suffix: &str) -> Result<PathBuf, String> {
    if !["gcc", "objcopy", "size"].contains(&suffix) {
        return Err("unsupported tool".into());
    }
    let directory = canonical_directory(
        prefix
            .parent()
            .ok_or("toolchain prefix needs a parent directory")?,
    )?;
    let mut name = prefix
        .file_name()
        .ok_or("toolchain prefix needs a file-name prefix")?
        .to_os_string();
    name.push(suffix);
    let program = directory
        .join(name)
        .canonicalize()
        .map_err(|e| format!("missing {suffix}: {e}"))?;
    if !program.is_file() || !program.starts_with(&directory) {
        return Err(format!(
            "compiler tool must resolve inside its bin directory: {}",
            program.display()
        ));
    }
    Ok(program)
}

fn command(tool: &Path, output: &Path) -> Command {
    let mut command = Command::new(tool);
    command.current_dir(output).env("TMPDIR", output);
    // Prevent ambient search paths, specs, or dependency-output variables from
    // adding unreviewed inputs or writing compiler outputs outside output.
    for key in [
        "CPATH",
        "C_INCLUDE_PATH",
        "CPLUS_INCLUDE_PATH",
        "OBJC_INCLUDE_PATH",
        "GCC_EXEC_PREFIX",
        "COMPILER_PATH",
        "LIBRARY_PATH",
        "GCC_SPECS",
        "DEPENDENCIES_OUTPUT",
        "SUNPRO_DEPENDENCIES",
    ] {
        command.env_remove(key);
    }
    command
}

fn run(command: &mut Command, label: &str) -> Result<(), String> {
    println!("BUILD {label}");
    let status = command
        .status()
        .map_err(|e| format!("{label}: {e}; partial outputs retained"))?;
    if !status.success() {
        return Err(format!("{label}: {status}; partial outputs retained"));
    }
    Ok(())
}

fn write_new(path: &Path, data: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    file.write_all(data)
        .map_err(|e| format!("{}: {e}", path.display()))
}

/// Build from recovered source and a previously verified SDK-patched directory.
/// `output` must not exist; its parent must already exist. Failure leaves all
/// evidence intact. This produces a new baseline, not the running diagnostic bin.
pub fn build(
    source_root: &Path,
    sdk_patched: &Path,
    compiler_prefix: &Path,
    output: &Path,
) -> Result<(), String> {
    let source = canonical_directory(source_root)?;
    let sdk = canonical_directory(sdk_patched)?;
    let gcc = tool(compiler_prefix, "gcc")?;
    let objcopy = tool(compiler_prefix, "objcopy")?;
    let size = tool(compiler_prefix, "size")?;
    let source_include = ["firmware/ch32v407", "firmware/main"];
    let sdk_include = [
        "EVT/EXAM/SRC/Core",
        "EVT/EXAM/SRC/Debug",
        "EVT/EXAM/SRC/Peripheral/inc",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/board",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/include",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/port",
    ];
    let mut includes = Vec::new();
    for relative in source_include {
        includes.push(inside(&source.join(relative), &[&source])?);
    }
    for relative in sdk_include {
        includes.push(inside(&sdk.join(relative), &[&sdk])?);
    }
    let mut seen = BTreeSet::new();
    for include in &includes {
        if !include.is_dir() {
            return Err(format!("missing include directory: {}", include.display()));
        }
        audit_include_tree(include, &[&source, &sdk], &mut seen)?;
    }

    // Fixed order matches the recovered non-diagnostic Petros build.
    let mut sources = Vec::new();
    for relative in [
        "firmware/ch32v407/bridge.c",
        "firmware/ch32v407/main.c",
        "firmware/ch32v407/newlib_context.c",
        "firmware/ch32v407/setup_msc.c",
        "firmware/ch32v407/alignment_safe_libc.c",
    ] {
        sources.push(source_file(&source, relative)?);
    }
    let descriptors_original = source_file(&source, "firmware/ch32v407/descriptors.c")?;
    let stub = source_file(&source, "firmware/ch32v467_petros/setup_flash_none.c")?;
    // The stub's relative header search begins here; validate that directory too.
    audit_include_tree(stub.parent().unwrap(), &[&source, &sdk], &mut seen)?;
    let wire = source_file(&source, "firmware/main/wire_protocol.c")?;
    let mut vendor_sources = Vec::new();
    for relative in [
        "EVT/EXAM/SRC/Startup/startup_ch32v4x7.S",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/board/system_ch32v4x7.c",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/src/usbd_driver_core.c",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/port/usbhs1_dcp.c",
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/port/usbhs2_dcp.c",
        "EVT/EXAM/SRC/Peripheral/src/ch32v4x7_rcc.c",
    ] {
        vendor_sources.push(source_file(&sdk, relative)?);
    }
    let linker = source_file(&sdk, "EVT/EXAM/SRC/Ld/Link.ld")?;
    let mut dependencies = BTreeSet::new();
    for input in sources
        .iter()
        .chain([&descriptors_original, &stub, &wire])
        .chain(&vendor_sources)
    {
        audit_dependencies(input, &includes, &[&source, &sdk], &mut dependencies)?;
    }
    require_marker(&linker, "__stack_size = 8192;")?;
    require_marker(&linker, "LENGTH = 576K")?;
    require_marker(&linker, "LENGTH = 136K-1K")?;
    let config = source_file(
        &sdk,
        "EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/include/usb_config.h",
    )?;
    for level in ["INFO", "WARNING", "ERROR"] {
        require_marker(
            &config,
            &format!("USB_DRIVER_LOG_{level}_EN disabled: no synchronous USB logging"),
        )?;
    }
    for port in [1, 2] {
        let file = source_file(
            &sdk,
            &format!("EVT/EXAM/USBHS/Dual_device/cdc_transfer/usb_driver/port/usbhs{port}_dcp.c"),
        )?;
        require_marker(&file, "extern void wk407_reset_begin(unsigned);")?;
        require_marker(&file, "reset_pending")?;
        require_marker(&file, "/* polling owner */")?;
        require_marker(
            &file,
            "Common PLL remains enabled for the other controller.",
        )?;
    }
    let mut descriptors = text(&descriptors_original)?;
    replace_once(
        &mut descriptors,
        "\"WiredKVM CH32 Target\":\"WiredKVM CH32 Host\"",
        "\"WiredKVM Petros V467 Target\":\"WiredKVM Petros V467 Host\"",
    )?;
    replace_once(
        &mut descriptors,
        "0x70,0x40,0,2,1,2,3,1",
        "0x70,0x40,0x67,2,1,2,3,1",
    )?;
    replace_once(
        &mut descriptors,
        "0x71,0x40,0,2,1,2,3,1",
        "0x71,0x40,0x67,2,1,2,3,1",
    )?;

    let parent = canonical_directory(
        output
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new(".")),
    )?;
    let name = output
        .file_name()
        .ok_or("output needs a new directory name")?;
    if !matches!(
        Path::new(name).components().next(),
        Some(Component::Normal(_))
    ) {
        return Err("invalid output name".into());
    }
    let output = parent.join(name);
    if output.starts_with(&sdk) || includes.iter().any(|include| output.starts_with(include)) {
        return Err("output must be outside all SDK/source include directories".into());
    }
    // Exclusive create is intentional: no create_dir_all and no cleanup/reuse.
    fs::create_dir(&output)
        .map_err(|e| format!("output must be a new directory {}: {e}", output.display()))?;
    if output.canonicalize().map_err(|e| e.to_string())? != output {
        return Err("output resolved unexpectedly; directory retained".into());
    }
    let generated = output.join("generated");
    let objects_dir = output.join("obj");
    fs::create_dir(&generated).map_err(|e| e.to_string())?;
    fs::create_dir(&objects_dir).map_err(|e| e.to_string())?;
    let descriptors_path = generated.join("descriptors.c");
    write_new(&descriptors_path, descriptors.as_bytes())?;
    sources.push(descriptors_path);
    sources.push(stub);
    sources.push(wire);
    sources.extend(vendor_sources);

    let mut objects = Vec::new();
    for source_file in &sources {
        let mut object_name = source_file.file_name().unwrap().to_os_string();
        object_name.push(".o");
        let object = objects_dir.join(object_name);
        if objects.contains(&object) {
            return Err("duplicate object output name; artifacts retained".into());
        }
        let mut compile = command(&gcc, &output);
        compile.args(FLAGS);
        if source_file.file_name().unwrap() == "alignment_safe_libc.c" {
            compile.args(["-fno-builtin", "-fno-tree-loop-distribute-patterns"]);
        }
        for include in &includes {
            compile.arg("-I").arg(include);
        }
        compile.arg("-c").arg(source_file).arg("-o").arg(&object);
        run(&mut compile, &source_file.display().to_string())?;
        objects.push(object);
    }
    let elf = output.join(format!("{STEM}.elf"));
    let binary = output.join(format!("{STEM}.bin"));
    let map = output.join(format!("{STEM}.map"));
    let mut link = command(&gcc, &output);
    link.args(FLAGS)
        .args(["-nostartfiles", "--specs=nosys.specs"])
        .args(&objects)
        .arg("-Wl,--gc-sections")
        .args(["-Xlinker", "-Map", "-Xlinker"])
        .arg(&map)
        .arg("-T")
        .arg(&linker)
        .arg("-o")
        .arg(&elf);
    run(&mut link, "link non-diagnostic Petros V467")?;
    run(
        command(&objcopy, &output)
            .args(["-O", "binary"])
            .arg(&elf)
            .arg(&binary),
        "objcopy",
    )?;
    let binary_size = fs::metadata(&binary).map_err(|e| e.to_string())?.len();
    // V407 product ceiling remains 512KiB even though this SDK's linker allows
    // the board's 576KiB mapping. Do not silently widen the product requirement.
    if binary_size == 0 || binary_size > 512 * 1024 {
        return Err(format!("firmware binary {binary_size} bytes exceeds the 512KiB product ceiling (or is empty); artifacts retained"));
    }
    run(command(&size, &output).arg(&elf), "firmware size")?;

    let mut provenance = format!("New recovery build: non-diagnostic Petros V467\nSource: {}\nSDK-patched: {}\nCompiler: {}\n\nNot the currently flashed diagnostic image.\nNo device access or flashing occurred.\nExternal NOR: not linked (no-medium adapter).\nExtra PSRAM: not linked.\nVID/PID/serial preserved; USB product and bcdDevice 0x0267 adapted.\nSDK integrity must be verified by the caller; marker checks are not hashes.\nNo original Python verifier or hardware acceptance test was run.\n\nInputs:\n",
        source.display(), sdk.display(), gcc.display());
    for path in sources.iter().chain([&descriptors_original, &linker]) {
        provenance.push_str(&format!("{}\n", path.display()));
    }
    provenance.push_str(&format!("\nBinary bytes: {binary_size}\nProduct binary ceiling: 524288 bytes\nResolved project/SDK dependency files: {}\n", dependencies.len()));
    write_new(&output.join("RECOVERY_BUILD.txt"), provenance.as_bytes())?;
    println!("RECOVERY_FIRMWARE_BUILT {}", binary.display());
    Ok(())
}
