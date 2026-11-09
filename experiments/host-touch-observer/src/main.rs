//! Independent Book-side diagnostic. Default never loads a framework.
use std::time::Duration;

#[cfg(target_os = "macos")]
mod mac;

#[derive(Debug, PartialEq)]
enum Mode {
    DryRun,
    Inspect,
    Stream,
    Protocol,
    ObserveUsbTarget(u64, u64),
    Observe(u64),
}
fn args(values: &[String]) -> Result<Mode, String> {
    match values {
        [] => Ok(Mode::DryRun),
        [s] if s == "--dry-run" => Ok(Mode::DryRun),
        [s] if s == "--inspect" => Ok(Mode::Inspect),
        [s] if s == "--stream" => Ok(Mode::Stream),
        [s] if s == "--protocol" => Ok(Mode::Protocol),
        [a, b, n, c, id]
            if a == "--observe-usb-target" && b == "--seconds" && c == "--registry-id" =>
        {
            let seconds = n.parse::<u64>().map_err(|_| "Invalid duration")?;
            let id = id.parse::<u64>().map_err(|_| "Invalid registry ID")?;
            if !(1..=30).contains(&seconds) || id == 0 {
                return Err("Bounded target observation needs fresh registry ID".into());
            }
            Ok(Mode::ObserveUsbTarget(seconds, id))
        }
        [a, b, n] if a == "--observe" && b == "--seconds" => {
            let n = n.parse::<u64>().map_err(|_| "Invalid duration")?;
            if !(1..=30).contains(&n) {
                return Err("Duration must be 1..30 seconds".into());
            }
            Ok(Mode::Observe(n))
        }
        _ => Err("Use --dry-run, --inspect, or --observe --seconds 1..30".into()),
    }
}
fn run(mode: Mode) -> Result<String, String> {
    if mode == Mode::Protocol {
        return Ok(if cfg!(feature = "native-mt2") {
            "2"
        } else {
            "1"
        }
        .into());
    }
    if mode == Mode::DryRun {
        return Ok("{\"mode\":\"dry_run\",\"framework_loaded\":false,\"input_injected\":false,\"target_access\":false}".into());
    }
    #[cfg(target_os = "macos")]
    {
        mac::run(mode)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = Duration::ZERO;
        Err("Only macOS Book is supported".into())
    }
}
fn main() {
    let result = args(&std::env::args().skip(1).collect::<Vec<_>>()).and_then(run);
    match result {
        Ok(s) => println!("{s}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_never_activates_capture() {
        assert_eq!(args(&[]), Ok(Mode::DryRun));
        assert!(run(Mode::DryRun)
            .unwrap()
            .contains("\"framework_loaded\":false"));
    }
    #[test]
    fn target_observation_needs_bounded_time_and_exact_registry_id() {
        for (n, id) in [("0", "1"), ("31", "1"), ("6", "0"), ("6", "unknown")] {
            let args = vec![
                "--observe-usb-target".into(),
                "--seconds".into(),
                n.into(),
                "--registry-id".into(),
                id.into(),
            ];
            assert!(super::args(&args).is_err());
        }
        assert_eq!(
            run(Mode::Protocol).unwrap(),
            if cfg!(feature = "native-mt2") {
                "2"
            } else {
                "1"
            }
        );
    }
    #[test]
    fn no_unbounded_observation_or_unknown_options() {
        for n in ["0", "31", "-1", "forever"] {
            assert!(args(&["--observe".into(), "--seconds".into(), n.into()]).is_err());
        }
        assert!(args(&["--observe".into()]).is_err());
    }
}
