#![cfg(feature = "c-abi")]
use wiredkvm_mt2_protocol_draft::{ffi::*, Error};

#[test]
fn stage_one_has_no_input_until_enable_then_one_zero_contact_report() {
    let core = FfiCore::new();
    let mut dst = [0xa5; 64];
    assert!(!core.enabled());
    assert_eq!(core.input(&mut dst), Ok(0));
    core.set(2, &[1]).unwrap();
    assert!(core.enabled());
    assert_eq!(core.input(&mut dst[..11]), Err(-2));
    assert_eq!(core.input(&mut dst), Ok(12));
    assert_eq!(&dst[..12], &[2, 0, 0, 0, 0, 0, 0, 0, 0x31, 0, 0, 0x88]);
    assert_eq!(&dst[12..], &[0xa5; 52]);
    assert_eq!(core.input(&mut dst), Ok(0));
    core.set(2, &[0]).unwrap();
    assert!(!core.enabled());
    assert_eq!(core.input(&mut dst), Ok(0));
}

#[test]
fn experimental_properties_and_selector_exceed_ep0_single_packet_safely() {
    let core = FfiCore::new();
    let mut dst = [0; 256];
    core.set(1, &[0xdb]).unwrap();
    assert_eq!(core.get(1, &mut dst), Ok(5));
    assert_eq!(&dst[..5], &[1, 0xdb, 0, 75, 0]);
    assert_eq!(core.get(0xdb, &mut dst), Ok(76));
    assert_eq!(&dst[..5], &[0xdb, 1, 2, 0, 0xd1]);
    assert_eq!(core.get(0xdb, &mut dst[..64]), Ok(64));
    assert_eq!(core.get(0xdb, &mut []), Ok(0));
}

#[test]
fn unsupported_or_bad_payload_does_not_enable_input() {
    let core = FfiCore::new();
    assert_eq!(core.set(0x44, &[1]), Err(Error::UnsupportedRequest));
    assert_eq!(core.set(2, &[2]), Err(Error::InvalidValue));
    assert_eq!(core.set(2, &[2, 1]), Err(Error::InvalidLength));
    assert_eq!(core.set(1, &[0x77]), Err(Error::UnsupportedRequest));
    assert!(!core.enabled());
    assert_eq!(core.get(0x44, &mut [0; 8]), Err(Error::UnsupportedRequest));
}

#[test]
fn reset_disables_and_clears_pending_without_injecting_release() {
    let core = FfiCore::new();
    core.set(2, &[1]).unwrap();
    core.set(1, &[0xdb]).unwrap();
    core.set(0x99, &[0xaa, 0x55]).unwrap();
    core.reset();
    let mut dst = [0; 64];
    assert!(!core.enabled());
    assert_eq!(core.input(&mut dst), Ok(0));
    assert_eq!(core.get(1, &mut dst), Ok(5));
    assert_eq!(&dst[..5], &[1, 0x99, 0, 2, 0]);
    core.get(0x99, &mut dst).unwrap();
    assert_eq!(&dst[..3], &[0x99, 0, 0]);
}

#[test]
fn c_abi_checks_buffers_and_exports_descriptor_without_overwrite() {
    use core::ptr::{null, null_mut};
    wkmt2_reset();
    let mut descriptor = [0xa5; 128];
    let mut report = [0; 256];
    unsafe {
        assert_eq!(wkmt2_report_descriptor(null_mut(), 0), -2);
        assert_eq!(wkmt2_report_descriptor(null_mut(), 110), -1);
        assert_eq!(wkmt2_report_descriptor(descriptor.as_mut_ptr(), 109), -2);
        assert_eq!(wkmt2_report_descriptor(descriptor.as_mut_ptr(), 128), 110);
        assert_eq!(&descriptor[..6], &[5, 1, 9, 2, 0xa1, 1]);
        assert_eq!(&descriptor[110..], &[0xa5; 18]);
        assert_eq!(wkmt2_feature_get(2, null_mut(), 0), 0);
        assert_eq!(wkmt2_feature_get(2, null_mut(), 1), -1);
        assert_eq!(wkmt2_feature_get(0x44, report.as_mut_ptr(), 256), -3);
        assert_eq!(wkmt2_feature_set(2, null(), 0), -4);
        assert_eq!(wkmt2_feature_set(2, null(), 1), -1);
        assert_eq!(wkmt2_feature_set(2, [2, 1].as_ptr(), 2), -4);
        assert_eq!(wkmt2_feature_set(2, [1].as_ptr(), 1), 0);
        assert_eq!(wkmt2_enabled(), 1);
        assert_eq!(wkmt2_input(report.as_mut_ptr(), 64), 12);
        assert_eq!(wkmt2_input(report.as_mut_ptr(), 64), 0);
        assert_eq!(wkmt2_feature_get(0xdb, report.as_mut_ptr(), 256), 76);
    }
    wkmt2_reset();
    assert_eq!(wkmt2_enabled(), 0);
}

#[test]
fn feature_config_snapshot_is_not_torn_under_concurrent_access() {
    use std::{sync::Arc, thread};
    let core = Arc::new(FfiCore::new());
    let writer = {
        let core = core.clone();
        thread::spawn(move || {
            for i in 0..10000 {
                let pair = if i % 2 == 0 {
                    [0xaa, 0x55]
                } else {
                    [0x55, 0xaa]
                };
                core.set(0x99, &pair).unwrap();
            }
        })
    };
    let mut dst = [0; 3];
    for _ in 0..10000 {
        core.get(0x99, &mut dst).unwrap();
        assert!(matches!(
            dst,
            [0x99, 0, 0] | [0x99, 0xaa, 0x55] | [0x99, 0x55, 0xaa]
        ));
    }
    writer.join().unwrap();
}
