use wiredkvm_mt2_protocol_draft::{
    native_format::{usb_frame, FingerKind, NativeContact, NativeState},
    Error, Geometry,
};
fn g() -> Geometry {
    Geometry {
        major: 20,
        minor: 20,
        size: 10,
        pressure: 5,
        orientation: 0,
    }
}
#[test]
fn known_three_bit_lifecycle_and_finger_types_keep_y_bits() {
    let c = NativeContact::new(-1200, 875, 9, FingerKind::Index, NativeState::Active, g()).unwrap();
    // Independently packed 13+13+3+3-bit layout: Y consumes only low two bits.
    assert_eq!(c.bytes()[3], 0x8b);
    assert_eq!(c.with_state(NativeState::Start).bytes()[3], 0x6b);
    assert_eq!(c.with_state(NativeState::Stop).bytes()[3], 0xeb);
    assert_eq!(c.with_state(NativeState::Inactive).bytes()[3], 0x0b);
    assert_eq!(&c.with_state(NativeState::Stop).bytes()[4..8], &[0; 4]);
    assert_eq!(c.bytes()[8], 0x89);
    assert!(NativeContact::new(0, 0, 0, FingerKind::Index, NativeState::Active, g()).is_err());
}
#[test]
fn clock_preserves_all_24_bits_and_low_flag_across_old_eight_second_wrap() {
    let a = usb_frame(&[], 8191).unwrap();
    let b = usb_frame(&[], 8192).unwrap();
    assert_eq!(&a.as_bytes()[9..12], &[0xfc, 0xff, 0]);
    assert_eq!(&b.as_bytes()[9..12], &[4, 0, 1]);
    // Published real TOUCH header 0c 2a 88 is a clock value, not a fixed 0x88.
    let t = 0x882a0cu32 >> 3;
    assert_eq!(
        &usb_frame(&[], t).unwrap().as_bytes()[9..12],
        &[0x0c, 0x2a, 0x88]
    );
    let wrap = usb_frame(&[], 1 << 21).unwrap();
    assert_eq!(&wrap.as_bytes()[9..12], &[4, 0, 0]);
}
#[test]
fn four_real_finger_labels_start_touch_stop_and_gone_are_distinct() {
    let kinds = [
        FingerKind::Index,
        FingerKind::Middle,
        FingerKind::Ring,
        FingerKind::Little,
    ];
    let c = kinds
        .iter()
        .enumerate()
        .map(|(i, k)| {
            NativeContact::new(i as i16 * 300, 0, i as u8 + 1, *k, NativeState::Start, g()).unwrap()
        })
        .collect::<Vec<_>>();
    let start = usb_frame(&c, 100).unwrap();
    assert_eq!(start.as_bytes().len(), 48);
    assert_eq!(start.as_bytes()[7], 1);
    for (i, k) in kinds.iter().enumerate() {
        let b = start.as_bytes()[15 + i * 9];
        assert_eq!((b >> 2) & 7, *k as u8);
        assert_eq!(b >> 5, 3);
    }
    let active = c
        .iter()
        .map(|c| c.with_state(NativeState::Active))
        .collect::<Vec<_>>();
    let stop = c
        .iter()
        .map(|c| c.with_state(NativeState::Stop))
        .collect::<Vec<_>>();
    let gone = c
        .iter()
        .map(|c| c.with_state(NativeState::Inactive))
        .collect::<Vec<_>>();
    assert_ne!(
        usb_frame(&active, 104).unwrap().as_bytes(),
        usb_frame(&stop, 108).unwrap().as_bytes()
    );
    assert_eq!(usb_frame(&gone, 112).unwrap().as_bytes()[7], 0);
    assert_eq!(
        usb_frame(&[c[0], c[0]], 100).err(),
        Some(Error::DuplicateContactId)
    );
}
