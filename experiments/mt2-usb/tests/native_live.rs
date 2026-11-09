#![cfg(feature = "native-mt2")]
use wiredkvm_mt2_protocol_draft::{
    live::{LiveCore, Packet},
    native_format::{usb_frame, FingerKind, NativeContact, NativeState},
    Geometry,
};
fn report(n: usize, state: NativeState, clock: u32) -> Vec<u8> {
    let kinds = [
        FingerKind::Index,
        FingerKind::Middle,
        FingerKind::Ring,
        FingerKind::Little,
        FingerKind::Thumb,
    ];
    let g = Geometry {
        major: 20,
        minor: 20,
        size: 10,
        pressure: 5,
        orientation: 0,
    };
    let c = (0..n)
        .map(|i| NativeContact::new(i as i16 * 300, 0, i as u8 + 1, kinds[i], state, g).unwrap())
        .collect::<Vec<_>>();
    usb_frame(&c, clock).unwrap().as_bytes().to_vec()
}
fn take(s: &mut LiveCore) -> Vec<u8> {
    let p = s.peek().unwrap();
    let out = p.bytes[..p.len].to_vec();
    s.submitted();
    s.complete();
    out
}
#[test]
fn full_states_and_clock_accepted_undefined_finger_regression_rejected() {
    for state in [
        NativeState::Inactive,
        NativeState::Start,
        NativeState::Active,
        NativeState::Stop,
    ] {
        for clock in [0, 8191, 8192, 2000000] {
            assert!(Packet::parse(&report(4, state, clock)).is_some());
        }
    }
    let mut old = report(4, NativeState::Active, 0);
    for offset in (15..old.len()).step_by(9) {
        old[offset] &= !0x1c;
    }
    assert!(Packet::parse(&old).is_none());
}
#[test]
fn start_is_never_coalesced_into_active_and_native_stop_clears_geometry() {
    let mut s = LiveCore::new();
    s.begin(1, 0);
    s.offer(1, &report(4, NativeState::Start, 0), 0);
    s.offer(1, &report(4, NativeState::Active, 4), 4);
    for n in 5..100005 {
        assert!(s.offer(1, &report(4, NativeState::Active, n), n));
        assert!(s.queued() <= 2);
    }
    assert_eq!(take(&mut s)[15] >> 5, 3);
    assert_eq!(take(&mut s)[15] >> 5, 4);
    s.cancel(1);
    let stop = take(&mut s);
    assert_eq!(stop[15] >> 5, 7);
    assert_eq!(&stop[16..20], &[0; 4]);
    assert!(Packet::parse(&stop).is_some());
    assert_eq!(take(&mut s).len(), 12);
}
#[test]
fn ten_thousand_cancelled_dma_callbacks_never_pop_the_new_release() {
    let mut s = LiveCore::new();
    for epoch in 1..10001 {
        s.tick(epoch * 4, true);
        assert!(s.begin(epoch, epoch * 4));
        assert!(s.offer(epoch, &report(4, NativeState::Active, epoch * 4), epoch * 4));
        s.submitted();
        s.cancel(epoch);
        assert!(s.needs_abort());
        s.complete();
        assert_eq!(s.queued(), 2);
        assert_eq!(take(&mut s)[15] >> 5, 7);
        assert_eq!(take(&mut s).len(), 12);
    }
}
