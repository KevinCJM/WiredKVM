use wiredkvm_mt2_protocol_draft::*;

// Deliberately artificial byte fixture, not a claim of valid physical fingers.
fn contact(id: u8) -> Contact {
    Contact::from_observed_record([0, 0, 0, 0xb4, 0x12, 0x34, 0x56, 0x78, 0xa0])
        .with_id(id)
        .unwrap()
        .with_position(100 + i16::from(id), -200)
        .unwrap()
}

#[test]
fn zero_two_four_five_contact_packet_sizes_and_exact_records() {
    let points = [contact(0), contact(1), contact(2), contact(3), contact(4)];
    for n in [0usize, 2, 4, 5] {
        let mut encoder = Encoder::new(0x1234, 32);
        let report = encoder.frame(&points[..n], true).unwrap();
        let b = report.as_bytes();
        assert_eq!(b.len(), 12 + 9 * n);
        assert!(b.len() <= 64);
        assert_eq!(&b[..7], &[2, 0, 0, 0, 0, 0, 0]);
        assert_eq!(b[7], u8::from(n != 0));
        assert_eq!(&b[8..12], &[0x31, 0x34, 0x12, 0x88]);
        for (i, p) in points[..n].iter().enumerate() {
            assert_eq!(&b[12 + i * 9..21 + i * 9], p.bytes());
        }
    }
}

#[test]
fn signed_coordinate_boundaries_round_trip_without_corrupting_other_fields() {
    let original = contact(7);
    for x in [X_MIN, -1, 0, 1, X_MAX] {
        for y in [Y_MIN, -1, 0, 1, Y_MAX] {
            let p = original.with_position(x, y).unwrap();
            assert_eq!(p.position(), (x, y));
            assert_eq!(p.bytes()[3] & 0xfc, original.bytes()[3] & 0xfc);
            assert_eq!(&p.bytes()[4..], &original.bytes()[4..]);
        }
    }
    for (x, y) in [
        (-4097, 0),
        (4096, 0),
        (0, -4096),
        (0, 4097),
        (i16::MIN, i16::MAX),
    ] {
        assert_eq!(original.with_position(x, y), Err(Error::CoordinateRange));
    }
}

#[test]
fn exact_13_bit_wire_extremes() {
    let p = Contact::from_observed_record([0; 9])
        .with_position(-4096, 4096)
        .unwrap();
    assert_eq!(&p.bytes()[..4], &[0, 0x10, 0, 2]);
    let p = Contact::from_observed_record([0; 9])
        .with_position(4095, -4095)
        .unwrap();
    assert_eq!(&p.bytes()[..4], &[0xff, 0xef, 0xff, 1]);
}

#[test]
fn contact_id_and_state_preserve_opaque_bits() {
    let p = contact(0);
    assert_eq!(p.with_id(16), Err(Error::ContactIdRange));
    for id in 0..16 {
        let q = p.with_id(id).unwrap();
        assert_eq!(q.id(), id);
        assert_eq!(q.bytes()[8] & 0xf0, p.bytes()[8] & 0xf0);
    }
    for state in [
        ContactState::None,
        ContactState::Approach,
        ContactState::Touch,
        ContactState::Release,
    ] {
        let q = p.with_state(state);
        assert_eq!(q.state(), state);
        assert_eq!(q.position(), p.position());
        assert_eq!(q.bytes()[3] & 0x3c, p.bytes()[3] & 0x3c);
    }
}

#[test]
fn invalid_frame_never_advances_clock_or_accepts_duplicate_or_sixth_contact() {
    let mut encoder = Encoder::new(5, 32);
    let p = contact(0);
    assert_eq!(encoder.frame(&[p], false), Err(Error::Disabled));
    assert_eq!(encoder.frame(&[p, p], true), Err(Error::DuplicateContactId));
    assert_eq!(encoder.frame(&[p; 6], true), Err(Error::TooManyContacts));
    assert_eq!(encoder.next_timestamp(), 5);
}

#[test]
fn timestamp_wrap_is_explicit_and_deterministic() {
    let mut encoder = Encoder::new(65520, 32);
    let first = encoder.frame(&[], true).unwrap();
    let second = encoder.frame(&[], true).unwrap();
    assert_eq!(&first.as_bytes()[9..11], &65520u16.to_le_bytes());
    assert_eq!(&second.as_bytes()[9..11], &16u16.to_le_bytes());
}

#[test]
fn release_preserves_ids_and_coordinates_then_clears_all_contacts() {
    let mut encoder = Encoder::new(0, 32);
    let points = [contact(1), contact(2), contact(3), contact(4)];
    encoder.frame(&points, true).unwrap();
    let release = encoder.release(true).unwrap();
    assert_eq!(release[0].as_bytes().len(), 48);
    for (i, p) in points.iter().enumerate() {
        let raw: [u8; 9] = release[0].as_bytes()[12 + i * 9..21 + i * 9]
            .try_into()
            .unwrap();
        let q = Contact::from_observed_record(raw);
        assert_eq!(q.id(), p.id());
        assert_eq!(q.position(), p.position());
        assert_eq!(q.state(), ContactState::Release);
    }
    assert_eq!(release[1].as_bytes().len(), 12);
    assert_eq!(release[1].as_bytes()[7], 0);
    assert_eq!(encoder.release(true).unwrap()[0].as_bytes().len(), 12);
}

#[test]
fn reset_discards_old_contacts_and_restarts_explicit_clock() {
    let mut encoder = Encoder::new(0, 32);
    encoder.frame(&[contact(1), contact(2)], true).unwrap();
    encoder.reset(77);
    let reports = encoder.release(true).unwrap();
    assert_eq!(reports[0].as_bytes().len(), 12);
    assert_eq!(&reports[0].as_bytes()[9..11], &77u16.to_le_bytes());
}

#[test]
fn unknown_property_bytes_are_required_not_fabricated() {
    assert!(matches!(
        FeatureMachine::new(&[]),
        Err(Error::MissingPropertyCapture)
    ));
    assert!(matches!(
        FeatureMachine::new(&[0; 256]),
        Err(Error::PropertyCaptureTooLarge)
    ));
    let opaque = [0xa5; 75]; // arbitrary test fixture, NOT a usable MT2 property report
    let mut f = FeatureMachine::new(&opaque).unwrap();
    f.set_wire(1, &[1, 0xdb]).unwrap();
    assert_eq!(f.get(1, 5).unwrap().as_bytes(), &[1, 0xdb, 0, 75, 0]);
    let properties = f.get(0xdb, 300).unwrap();
    assert_eq!(properties.as_bytes().len(), 76); // control transfer may exceed 64
    assert_eq!(&properties.as_bytes()[1..], &opaque);
}

#[test]
fn feature_enable_disable_config_and_reset_are_stateful() {
    let mut f = FeatureMachine::new(&[0x77]).unwrap();
    assert!(!f.enabled());
    assert_eq!(f.get(2, 2).unwrap().as_bytes(), &[2, 0]);
    f.set_wire(2, &[2, 1]).unwrap();
    assert!(f.enabled());
    f.set_wire(2, &[2, 0]).unwrap();
    assert!(!f.enabled());
    f.set_payload(0x99, &[8, 9]).unwrap();
    assert_eq!(f.get(0x99, 3).unwrap().as_bytes(), &[0x99, 8, 9]);
    f.set_payload(2, &[1]).unwrap();
    f.reset();
    assert!(!f.enabled());
    assert_eq!(f.get(1, 5).unwrap().as_bytes(), &[1, 0x99, 0, 2, 0]);
    assert_eq!(f.get(0x99, 3).unwrap().as_bytes(), &[0x99, 0, 0]);
}

#[test]
fn unsupported_and_malformed_requests_cannot_modify_state() {
    let mut f = FeatureMachine::new(&[0x77]).unwrap();
    assert!(matches!(f.get(0xfe, 64), Err(Error::UnsupportedRequest)));
    assert_eq!(f.set_payload(0xfe, &[1]), Err(Error::UnsupportedRequest));
    assert_eq!(f.set_payload(1, &[0x55]), Err(Error::UnsupportedRequest));
    assert_eq!(f.set_payload(2, &[]), Err(Error::InvalidLength));
    assert_eq!(f.set_payload(2, &[1, 0]), Err(Error::InvalidLength));
    assert_eq!(f.set_payload(2, &[2]), Err(Error::InvalidValue));
    assert_eq!(f.set_wire(2, &[1, 1]), Err(Error::ReportIdMismatch));
    assert_eq!(f.set_wire(2, &[]), Err(Error::ReportIdMismatch));
    assert!(!f.enabled());
    assert_eq!(f.get(1, 5).unwrap().as_bytes(), &[1, 0x99, 0, 2, 0]);
}

#[test]
fn get_report_honors_zero_short_and_oversized_host_requests() {
    let f = FeatureMachine::new(&[0x55; 255]).unwrap();
    assert!(f.get(2, 0).unwrap().as_bytes().is_empty());
    assert_eq!(f.get(2, 1).unwrap().as_bytes(), &[2]);
    assert_eq!(f.get(2, 1000).unwrap().as_bytes(), &[2, 0]);
    assert_eq!(f.get(0xdb, usize::MAX).unwrap().as_bytes().len(), 256);
}
