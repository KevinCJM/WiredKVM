use wiredkvm_mt2_protocol_draft::{Contact,ContactState,Encoder,Error,Geometry};

fn geometry(orientation:i8)->Geometry {Geometry {major:72,minor:48,size:31,pressure:64,orientation}}

#[test]
fn synthesized_record_matches_documented_decoder_fields() {
    // Constructed example, not a captured finger. Wire fields independently
    // follow hid-magicmouse.c's MT2 decoder: signed XY, shape, pressure, ID/angle.
    let c=Contact::synthesized(-1200,875,9,ContactState::Touch,geometry(-2)).unwrap();
    assert_eq!(c.bytes(),&[0x50,0xbb,0x92,0x83,72,48,31,64,0x49]);
    assert_eq!(c.position(),(-1200,875));
    assert_eq!((c.bytes()[8]>>5) as i8-4,-2);
    assert_eq!(c.id(),9);
}

#[test]
fn synthesized_geometry_never_truncates_bad_orientation_id_or_xy() {
    for o in [-5,4] {assert_eq!(Contact::synthesized(0,0,0,ContactState::Touch,geometry(o)),Err(Error::OrientationRange));}
    assert_eq!(Contact::synthesized(0,0,16,ContactState::Touch,geometry(0)),Err(Error::ContactIdRange));
    assert_eq!(Contact::synthesized(4096,0,0,ContactState::Touch,geometry(0)),Err(Error::CoordinateRange));
}

#[test]
fn four_contacts_and_release_keep_geometry_and_do_not_set_pointer_buttons() {
    let contacts:[Contact;4]=core::array::from_fn(|i|Contact::synthesized((i as i16-2)*600,0,i as u8,ContactState::Touch,geometry(0)).unwrap());
    let mut e=Encoder::new(10000,32);let down=e.frame(&contacts,true).unwrap();
    assert_eq!(down.as_bytes().len(),48);assert_eq!(&down.as_bytes()[1..7],&[0;6]);
    let frames=e.release(true).unwrap();assert_eq!(frames[1].as_bytes().len(),12);
    for i in 0..4 {
        let d=&down.as_bytes()[12+i*9..21+i*9];let r=&frames[0].as_bytes()[12+i*9..21+i*9];
        assert_eq!(&r[4..],&d[4..]);assert_eq!(&r[..3],&d[..3]);
        assert_eq!(r[3]&0xc0,0xc0);assert_eq!(&frames[0].as_bytes()[1..7],&[0;6]);
    }
}
