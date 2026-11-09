#![cfg(not(feature="native-mt2"))]
use wiredkvm_mt2_protocol_draft::{
    live::{LiveCore, Packet, LEASE_MS},
    Contact, ContactState, Encoder, Geometry,
};
fn report(n: usize, x: i16) -> Vec<u8> {
    let g = Geometry {
        major: 72,
        minor: 48,
        size: 31,
        pressure: 64,
        orientation: 0,
    };
    let c = (0..n)
        .map(|i| Contact::synthesized(x + i as i16, 0, i as u8, ContactState::Touch, g).unwrap())
        .collect::<Vec<_>>();
    Encoder::new(123, 32)
        .frame(&c, true)
        .unwrap()
        .as_bytes()
        .to_vec()
}
fn finish(s: &mut LiveCore) -> Vec<u8> {
    let p = s.peek().unwrap();
    let b = p.bytes[..p.len].to_vec();
    s.submitted();
    s.complete();
    b
}
#[test]
fn parser_disallows_mouse_buttons_single_finger_and_malformed_packets() {
    for n in [0, 2, 3, 4, 5] {
        assert!(Packet::parse(&report(n, 0)).is_some());
    }
    assert!(Packet::parse(&report(1, 0)).is_none());
    let r = report(4, 0);
    for i in [0, 1, 2, 3, 4, 5, 6, 7, 8, 11] {
        let mut b = r.clone();
        b[i] ^= 0x20;
        assert!(Packet::parse(&b).is_none(), "field {i}");
    }
    let mut b = r.clone();
    b[HEADER + 9 + 8] = b[HEADER + 8];
    assert!(Packet::parse(&b).is_none());
}
const HEADER: usize = 12;
#[test]
fn motion_flood_never_overwrites_dma_and_stays_bounded() {
    let mut s = LiveCore::new();
    assert!(s.begin(1, 0));
    s.offer(1, &report(4, 0), 0);
    s.submitted();
    for i in 0..100_000 {
        assert!(s.offer(1, &report(4, (i % 3000) as i16), i));
        assert!(s.queued() <= 2);
    }
    assert!(s.peek().is_none());
    s.complete();
    assert_eq!(finish(&mut s), report(4, (99999i32 % 3000) as i16));
}
#[test]
fn cancel_fences_old_completion_and_preserves_release_then_new_session() {
    let mut s = LiveCore::new();
    s.begin(10, 0);
    s.offer(10, &report(4, 0), 0);
    s.submitted();
    s.cancel(10);
    assert!(s.needs_abort());
    assert!(s.peek().is_none());
    assert!(!s.begin(11, 1));
    assert!(!s.offer(10, &report(2, 300), 1));
    // Late completion retires cancelled DMA; must not consume the new release.
    s.complete();
    assert!(!s.needs_abort());
    assert_eq!(s.queued(), 2);
    let r = finish(&mut s);
    assert_eq!(r[15] & 0xc0, 0xc0);
    assert_eq!(finish(&mut s).len(), 12);
    s.tick(5, true);
    assert!(s.offer(11, &report(2, 1), 5));
    assert!(!s.begin(10, 5));
    assert_eq!(finish(&mut s), report(2, 1));
}
#[test]
fn stalled_source_lease_disable_and_clock_wrap_all_release() {
    for disabled in [false, true] {
        let mut s = LiveCore::new();
        let now = u32::MAX - 80;
        s.begin(1, now);
        s.offer(1, &report(2, 0), now);
        s.submitted();
        s.tick(
            now.wrapping_add(if disabled { 1 } else { LEASE_MS }),
            !disabled,
        );
        assert!(s.needs_abort());
        s.aborted();
        assert_eq!(finish(&mut s).len(), 30);
        assert_eq!(finish(&mut s).len(), 12);
        assert!(!s.offer(1, &report(2, 0), now));
    }
}
#[test]
fn topology_overflow_fails_closed_instead_of_losing_terminal_frame() {
    let mut s = LiveCore::new();
    s.begin(1, 0);
    let mut failed = false;
    for i in 0..100 {
        if !s.offer(1, &report(2 + i % 3, 0), i as u32) {
            failed = true;
            break;
        }
    }
    assert!(failed);
    assert_eq!(s.queued(), 2);
    assert_eq!(finish(&mut s).get(15).map(|v| v & 0xc0), Some(0xc0));
    assert_eq!(finish(&mut s).len(), 12);
    assert!(!s.offer(1, &report(4, 0), 1));
    assert!(s.begin(2, 1));
}
#[test]
fn ten_thousand_cancel_new_paste_style_sessions_never_replay_old_epoch() {
    let mut s = LiveCore::new();
    for e in 1..10_001 {
        s.tick(e * 4, true);
        assert!(s.begin(e, e * 4));
        s.offer(e, &report(4, 100), e * 4);
        s.submitted();
        s.cancel(e);
        s.aborted();
        assert!(!s.offer(e, &report(4, 200), e * 4));
        finish(&mut s);
        assert_eq!(finish(&mut s).len(), 12);
    }
}

#[test]
fn idle_handoff_and_idle_between_gestures_do_not_expire_the_session() {
    let mut s = LiveCore::new();
    s.begin(1, 0);
    s.tick(10000, true);
    assert_eq!(s.faults(), 0);
    assert!(s.offer(1, &report(4, 0), 10000));
    finish(&mut s);
    assert!(s.offer(1, &report(0, 0), 10001));
    finish(&mut s);
    s.tick(90000, true);
    assert!(s.offer(1, &report(2, 10), 90000));
    assert_eq!(s.faults(), 0);
}
