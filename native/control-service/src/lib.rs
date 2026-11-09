//! Lifecycle policy is independent of USB and process APIs and can be tested offline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub entry: u64,
    pub location: u32,
    pub port: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub pid: i32,
    pub sec: u64,
    pub usec: u64,
    pub path: String,
}
#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    Wait,
    Start,
    Keep,
    Stop,
}
pub fn decide(
    console: bool,
    devices: &[Device],
    bound: Option<&Device>,
    healthy: bool,
    foreign: bool,
) -> Action {
    if let Some(old) = bound {
        if !console || devices.len() != 1 || &devices[0] != old || !healthy {
            Action::Stop
        } else {
            Action::Keep
        }
    } else if console && devices.len() == 1 && !foreign {
        Action::Start
    } else {
        Action::Wait
    }
}
pub fn hid_ready(success: bool, text: &str) -> bool {
    success && text.lines().any(|s| s.starts_with("CPP_USB_HID_READY ("))
}
pub fn same_process(expected: &Identity, actual: Option<&Identity>) -> bool {
    actual == Some(expected)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn board(id: u64, port: &str) -> Device {
        Device {
            entry: id,
            location: 1,
            port: port.into(),
        }
    }
    #[test]
    fn login_with_board_or_hotplug_both_start() {
        let b = board(1, "/dev/cu.usbmodem2101");
        assert_eq!(
            decide(false, &[b.clone()], None, false, false),
            Action::Wait
        );
        assert_eq!(decide(true, &[], None, false, false), Action::Wait);
        assert_eq!(
            decide(true, &[b.clone()], None, false, false),
            Action::Start
        );
        assert_eq!(
            decide(true, &[b.clone()], Some(&b), true, false),
            Action::Keep
        );
    }
    #[test]
    fn detach_stops_then_changed_port_can_start() {
        let a = board(1, "/dev/cu.usbmodem1101");
        let b = board(2, "/dev/cu.usbmodem2101");
        assert_eq!(decide(true, &[], Some(&a), true, false), Action::Stop);
        assert_eq!(
            decide(true, &[b.clone()], None, false, false),
            Action::Start
        );
        assert_eq!(decide(true, &[b], Some(&a), true, false), Action::Stop);
    }
    #[test]
    fn same_port_new_usb_instance_restarts() {
        let a = board(1, "/dev/cu.usbmodem1");
        let b = board(2, &a.port);
        assert_eq!(decide(true, &[b], Some(&a), true, false), Action::Stop);
    }
    #[test]
    fn ambiguous_boards_never_start_or_continue() {
        let b = board(1, "/dev/cu.usbmodem1");
        let d = vec![b.clone(), board(2, "/dev/cu.usbmodem2")];
        assert_eq!(decide(true, &d, None, false, false), Action::Wait);
        assert_eq!(decide(true, &d, Some(&b), true, false), Action::Stop);
    }
    #[test]
    fn foreign_runtime_and_logout_are_respected() {
        let b = board(1, "/dev/cu.usbmodem1");
        assert_eq!(decide(true, &[b.clone()], None, false, true), Action::Wait);
        assert_eq!(
            decide(false, &[b.clone()], Some(&b), true, false),
            Action::Stop
        );
    }
    #[test]
    fn process_exit_recovers_and_pid_reuse_is_not_owned() {
        let b = board(1, "/dev/cu.usbmodem1");
        assert_eq!(
            decide(true, &[b.clone()], Some(&b), false, false),
            Action::Stop
        );
        assert_eq!(decide(true, &[b], None, false, false), Action::Start);
        let a = Identity {
            pid: 99,
            sec: 10,
            usec: 2,
            path: "/app/control".into(),
        };
        let mut reused = a.clone();
        reused.sec += 1;
        assert!(!same_process(&a, Some(&reused)));
        assert!(!same_process(&a, None));
        assert!(same_process(&a, Some(&a)));
    }
    #[test]
    fn status_zero_without_hid_is_not_ready() {
        assert!(!hid_ready(
            true,
            "CPP_USB_HID_NOT_CONNECTED (no key or cursor movement)"
        ));
        assert!(!hid_ready(
            false,
            "CPP_USB_HID_READY (no key or cursor movement)"
        ));
        assert!(hid_ready(
            true,
            "CPP_USB_HID_READY (no key or cursor movement)\n"
        ));
    }
    #[test]
    fn repeated_hotplug_and_crashes_do_not_duplicate_sessions() {
        let mut starts = 0;
        let mut stops = 0;
        for n in 0..1000 {
            let d = board(n, "/dev/cu.usbmodem1");
            assert_eq!(
                decide(true, &[d.clone()], None, false, false),
                Action::Start
            );
            starts += 1;
            for _ in 0..20 {
                assert_eq!(
                    decide(true, &[d.clone()], Some(&d), true, false),
                    Action::Keep
                );
            }
            assert_eq!(decide(true, &[], Some(&d), false, false), Action::Stop);
            stops += 1;
        }
        assert_eq!(starts, stops);
    }
}
