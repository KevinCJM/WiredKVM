use wiredkvm_clipboard_state::{Snapshot, State};

fn local(side: u32, stamp: u64, revision: u64) -> Snapshot {
    Snapshot { side, provenance: 1, session: 100 + u64::from(side), stamp, revision,
        ..Snapshot::default() }
}
fn received(mut dest: Snapshot, source: Snapshot) -> Snapshot {
    dest.stamp += 1;
    dest.revision += 1;
    dest.provenance = 2;
    if source.provenance == 2 {
        dest.original_side = source.original_side;
        dest.original_session = source.original_session;
        dest.original_stamp = source.original_stamp;
    } else {
        dest.original_side = source.side;
        dest.original_session = source.session;
        dest.original_stamp = source.stamp;
    }
    dest
}
fn seeded() -> State {
    let mut state = State::default();
    assert!(state.observe(local(0, 11, 7), false));
    assert!(state.observe(local(1, 21, 9), false));
    state
}
fn outgoing(state: &mut State, id: u64) -> wiredkvm_clipboard_state::Plan {
    state.plan(id, 1, state.projection().applied_sequence, 9, 5)
}

#[test]
fn existing_clipboards_are_available_without_new_os_writes() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    let p = outgoing(&mut s, 1);
    assert_eq!(p.action, 1);
    assert_eq!(p.source, local(0, 11, 7));
    assert_eq!(p.destination, local(1, 21, 9));
}

#[test]
fn a_b_a_reselects_unchanged_real_a_version() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    assert!(s.select(3, 1, false, 0));
    assert!(s.context(4, 0, 6));
    assert!(s.select(5, 0, false, 0));
    assert!(s.context(6, 1, 7));
    let p = s.plan(1, 1, 6, 9, 7);
    assert_eq!(p.action, 1);
    assert_eq!(p.source.stamp, 11);
    assert_eq!(s.snapshot(1).unwrap().stamp, 21);
}

#[test]
fn repeated_native_copy_never_fabricates_content_versions() {
    let mut s = seeded();
    for sequence in 1..=1000 { assert!(s.select(sequence, 0, false, 0)); }
    assert_eq!(s.snapshot(0), Some(local(0, 11, 7)));
    assert_eq!(s.snapshot(1), Some(local(1, 21, 9)));
    assert_eq!(s.plan(1, 0, 1000, 999, 0).action, 0,
        "same-machine paste cannot wait for a clipboard-version check");
}

#[test]
fn no_selected_source_is_immediately_native() {
    let mut s = State::default();
    assert_eq!(s.plan(1, 0, 0, 999, 0).action, 0);
    assert!(!s.active(1));
}

#[test]
fn cut_requires_real_new_local_content_and_same_side_native_never_waits() {
    let mut s = seeded();
    assert!(s.select(1, 0, true, 11));
    assert!(s.projection().cut_blocked == 1);
    assert_eq!(s.plan(1, 0, 1, 7, 0).action, 0);
    assert!(s.context(2, 1, 5));
    let p = outgoing(&mut s, 2);
    assert_eq!((p.action, p.reason), (2, 6));
    assert!(s.observe(local(0, 11, 7), true));
    assert_eq!(outgoing(&mut s, 3).action, 2, "duplicate origins cannot confirm Cut");
    assert!(s.observe(local(0, 12, 8), true));
    assert_eq!(s.projection().cut_blocked, 0);
    assert_eq!(outgoing(&mut s, 3).source.stamp, 12,
        "the same unresolved V may resume once Cut really changes the clipboard");
}

#[test]
fn received_write_and_unknown_baseline_cannot_confirm_cut() {
    let mut s = seeded();
    assert!(s.select(1, 0, true, 11));
    assert!(s.observe(received(local(0, 11, 7), local(1, 21, 9)), true));
    assert_eq!(s.projection().cut_blocked, 1);
    let mut empty = State::default();
    assert!(empty.select(1, 0, true, 0));
    assert!(empty.observe(local(0, 1, 3), true));
    assert_eq!(empty.projection().cut_blocked, 1, "first snapshot is not evidence of a Cut");
}

#[test]
fn committed_received_lineage_makes_repeated_paste_native() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    let p = outgoing(&mut s, 1);
    let dest = received(p.destination, p.source);
    assert!(s.commit(1, dest));
    assert_eq!(s.plan(2, 1, 2, dest.revision, 5).action, 0);
    assert!(s.select(3, 1, false, 0));
    assert!(s.context(4, 0, 6));
    assert_eq!(s.plan(3, 0, 4, 7, 6).action, 0,
        "copying received content back to its unchanged original is native too");
}

#[test]
fn equal_numeric_stamps_from_different_origins_are_not_equal_content() {
    let mut s = seeded();
    let mut dest = received(local(1, 21, 9), local(0, 11, 7));
    dest.original_session += 1;
    assert!(s.observe(dest, false));
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    assert_eq!(s.plan(1, 1, 2, dest.revision, 5).action, 1);
    dest.stamp += 1;
    dest.revision += 1;
    dest.original_session = 100;
    dest.original_side = 1;
    assert!(s.observe(dest, false));
    assert_eq!(s.plan(2, 1, 2, dest.revision, 5).action, 1);
}

#[test]
fn changing_either_endpoint_invalidates_the_pinned_transaction() {
    for side in [0, 1] {
        let mut s = seeded();
        assert!(s.select(1, 0, false, 0));
        assert!(s.context(2, 1, 5));
        let p = outgoing(&mut s, 1);
        assert!(s.active(1));
        let mut changed = s.snapshot(side).unwrap();
        changed.stamp += 1; changed.revision += 1;
        assert!(s.observe(changed, true));
        assert!(!s.active(1));
        assert!(!s.commit(1, received(p.destination, p.source)));
    }
}

#[test]
fn new_paste_replaces_old_and_late_commit_is_refused() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    let old = outgoing(&mut s, 1);
    let new = outgoing(&mut s, 2);
    assert!(!s.active(1)); assert!(s.active(2));
    assert!(!s.commit(1, received(old.destination, old.source)));
    assert!(s.commit(2, received(new.destination, new.source)));
    assert!(!s.commit(2, received(new.destination, new.source)));
}

#[test]
fn repeated_active_intent_is_idempotent_and_cancelled_id_cannot_rearm() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    let original = outgoing(&mut s, 1);
    assert_eq!(outgoing(&mut s, 1), original);
    s.abort(1);
    assert_eq!(outgoing(&mut s, 1).reason, 8);
    assert_eq!(outgoing(&mut s, 2).action, 1);
    assert_eq!(outgoing(&mut s, 1).reason, 8);
    assert!(s.active(2), "stale requests must not cancel a newer intent");
}

#[test]
fn unknown_source_can_refresh_once_but_abort_closes_refresh_intent() {
    let mut s = State::default();
    assert!(s.observe(local(1, 21, 9), false));
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    assert_eq!(outgoing(&mut s, 1).action, 3);
    assert!(s.observe(local(0, 11, 7), false));
    assert_eq!(outgoing(&mut s, 1).action, 1);
    s.abort(1);
    assert_eq!(outgoing(&mut s, 1).reason, 8);
}

#[test]
fn new_session_requires_reset_and_rejects_old_session_after_binding() {
    let mut s = seeded();
    let mut new = local(1, 1, 1); new.session = 500;
    assert!(!s.observe(new, false));
    assert!(s.reset(1, 500));
    assert!(s.observe(new, false));
    assert!(!s.observe(local(1, 22, 10), true));
    assert!(s.reset(1, 0));
    assert!(s.observe(new, false));
    assert!(!s.observe(local(1, 22, 10), false));
}

#[test]
fn stale_versions_and_same_version_mutations_are_rejected() {
    let mut s = seeded();
    assert!(!s.observe(local(0, 10, 6), false));
    assert!(!s.observe(local(0, 11, 8), false));
    assert!(!s.observe(local(0, 12, 6), false));
    assert!(!s.observe(local(0, 12, 7), false), "a new token cannot fabricate an OS revision");
    assert_eq!(s.snapshot(0), Some(local(0, 11, 7)));
}

#[test]
fn input_order_destination_revision_and_focus_are_checked() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(!s.select(1, 1, false, 0));
    assert!(s.context(2, 1, 5));
    assert!(!s.context(1, 0, 9));
    assert_eq!(s.plan(1, 1, 3, 9, 5).reason, 3);
    assert!(s.context(3, 1, 5));
    assert_eq!(s.plan(1, 1, 3, 9, 5).action, 1);
    assert_eq!(s.plan(2, 1, 3, 8, 5).reason, 4);
    assert_eq!(s.plan(3, 1, 3, 9, 4).reason, 7);
    assert_eq!(s.plan(4, 0, 3, 7, 5).reason, 7);
    assert_eq!(s.plan(5, 1, 3, 9, 5).action, 1);
    assert!(s.context(4, 0, 6));
    assert!(!s.active(5));
}

#[test]
fn destination_copy_or_new_selection_retires_an_unresolved_paste() {
    let mut s = State::default();
    assert!(s.observe(local(1, 21, 9), false));
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    assert_eq!(outgoing(&mut s, 1).action, 3);
    assert!(s.observe(local(1, 22, 10), true));
    assert_eq!(s.plan(1, 1, 2, 10, 5).reason, 8);
    assert!(s.observe(local(0, 11, 7), false));
    assert!(s.select(3, 0, false, 0));
    assert_eq!(s.plan(2, 1, 3, 10, 5).action, 1);
    assert!(s.select(4, 0, false, 0));
    assert!(!s.active(2));
    assert_eq!(s.plan(2, 1, 4, 10, 5).reason, 8);
}

#[test]
fn future_or_zero_cut_baselines_cannot_authorize_old_content() {
    let mut s = seeded();
    assert!(s.select(1, 0, true, 999));
    assert!(s.context(2, 1, 5));
    assert_eq!(outgoing(&mut s, 1).reason, 6);
    assert!(s.observe(local(0, 12, 8), false));
    assert_eq!(outgoing(&mut s, 1).reason, 6);
}

#[test]
fn forged_commit_cannot_publish_another_source_or_without_a_real_write() {
    let mut s = seeded();
    assert!(s.select(1, 0, false, 0));
    assert!(s.context(2, 1, 5));
    let p = outgoing(&mut s, 1);
    let valid = received(p.destination, p.source);
    for bad in [
        Snapshot { original_side: 1, ..valid },
        Snapshot { original_session: 999, ..valid },
        Snapshot { original_stamp: 999, ..valid },
        Snapshot { session: 999, ..valid },
        Snapshot { stamp: p.destination.stamp, ..valid },
        Snapshot { revision: p.destination.revision, ..valid },
        Snapshot { provenance: 1, original_session: 0, original_stamp: 0, ..valid },
    ] { assert!(!s.commit(1, bad)); assert!(s.active(1)); }
    assert!(s.commit(1, valid));
}

#[test]
fn malformed_records_and_null_c_handles_fail_closed() {
    let mut s = seeded();
    for bad in [Snapshot { side: 2, ..local(0, 12, 8) },
        Snapshot { session: 0, ..local(0, 12, 8) },
        Snapshot { stamp: 0, ..local(0, 12, 8) },
        Snapshot { reserved: 1, ..local(0, 12, 8) },
        Snapshot { provenance: 3, ..local(0, 12, 8) },
        Snapshot { original_stamp: 1, ..local(0, 12, 8) }] { assert!(!s.observe(bad, false)); }
    assert!(!s.reset(2, 1));
    assert!(!s.select(1, 2, false, 0));
    assert!(!s.context(1, 2, 1));
    unsafe {
        use wiredkvm_clipboard_state::*;
        assert_eq!(wkcs_active(std::ptr::null(), 1), 0);
        assert_eq!(wkcs_observe(std::ptr::null_mut(), local(0, 1, 1), 0), 0);
        assert_eq!(wkcs_plan(std::ptr::null_mut(), 1, 0, 0, 0, 0).action, 2);
        wkcs_destroy(std::ptr::null_mut());
    }
}

#[test]
fn deterministic_hundred_thousand_operation_stress_keeps_only_two_snapshots() {
    let mut s = seeded();
    let mut sequence = 0;
    for id in 1..=100_000 {
        let side = (id % 2) as u32;
        let mut source = s.snapshot(side).unwrap();
        source.stamp += 1; source.revision += 1;
        source.provenance = 1; source.original_side = 0;
        source.original_session = 0; source.original_stamp = 0;
        assert!(s.observe(source, true));
        sequence += 1; assert!(s.select(sequence, side, false, 0));
        sequence += 1; assert!(s.context(sequence, 1 - side, id));
        let dest = s.snapshot(1 - side).unwrap();
        let p = s.plan(id, 1 - side, sequence, dest.revision, id);
        assert_eq!(p.action, 1);
        if id % 3 == 0 { s.abort(id); assert!(!s.commit(id, received(dest, source))); }
        else { assert!(s.commit(id, received(dest, source))); }
        assert_eq!(s.projection().active_id, 0);
    }
}

#[test]
fn matched_departure_selects_fresh_peer_without_fabricating_input_sequence() {
    let mut s = seeded();
    assert!(s.context(1, 1, 4));
    assert!(s.context(2, 0, 5));
    assert!(s.observe(local(1, 22, 10), false));
    assert_eq!(s.projection().selected_side, 2);
    let generation = s.projection().generation;
    assert!(s.confirm_departure(1, 2, 5, 101, 21));
    assert_eq!(s.projection().selected_side, 1);
    assert_eq!(s.projection().applied_sequence, 2);
    assert!(s.projection().generation > generation);
    assert_eq!(s.plan(1, 0, 2, 7, 5).action, 1);
}

#[test]
fn departure_rejects_initial_same_stamp_wrong_session_or_received_content() {
    let mut s = seeded();
    assert!(s.context(1, 1, 4));
    assert!(s.context(2, 0, 5));
    assert!(!s.confirm_departure(1, 2, 5, 101, 21));
    assert!(!s.confirm_departure(1, 2, 5, 101, 22));
    assert!(s.observe(local(1, 22, 10), false));
    assert!(!s.confirm_departure(1, 2, 5, 999, 21));
    assert!(!s.confirm_departure(1, 2, 5, 101, 0));
    assert!(!s.confirm_departure(2, 2, 5, 101, 21));
    assert!(s.observe(received(local(1, 22, 10), local(0, 11, 7)), false));
    assert!(!s.confirm_departure(1, 2, 5, 101, 21));
    assert_eq!(s.projection().selected_side, 2);
}

#[test]
fn departure_loses_to_new_select_focus_transition_and_reset() {
    for event in 0..3 {
        let mut s = seeded();
        assert!(s.context(1, 1, 4));
        assert!(s.context(2, 0, 5));
        assert!(s.observe(local(1, 22, 10), false));
        match event {
            0 => { assert!(s.select(3, 0, false, 0)); },
            1 => { assert!(s.context(3, 1, 6)); },
            _ => { assert!(s.reset(1, 102)); },
        }
        assert!(!s.confirm_departure(1, 2, 5, 101, 21));
    }
    let mut s = seeded();
    assert!(s.context(1, 1, 5));
    assert!(s.observe(local(1, 22, 10), false));
    assert!(!s.confirm_departure(1, 1, 5, 101, 21), "must have left the source side");
    assert!(!s.confirm_departure(1, 1, 6, 101, 21));
}

#[test]
fn departure_cannot_unlock_cut_without_its_actual_new_os_version() {
    let mut s = seeded();
    assert!(s.context(1, 1, 4));
    assert!(s.select(2, 1, true, 21));
    assert!(s.context(3, 0, 5));
    assert!(!s.confirm_departure(1, 3, 5, 101, 20), "old baseline cannot bypass pending Cut");
    assert!(s.observe(local(1, 22, 10), false));
    assert!(s.confirm_departure(1, 3, 5, 101, 21));
    assert_eq!(s.projection().cut_blocked, 0);
    assert_eq!(s.plan(1, 0, 3, 7, 5).action, 1);
}

#[test]
fn departure_can_resolve_refresh_but_cannot_reopen_retired_paste() {
    let mut s = State::default();
    assert!(s.observe(local(0, 11, 7), false));
    assert!(s.context(1, 1, 4));
    assert!(s.select(2, 1, false, 0));
    assert!(s.context(3, 0, 5));
    assert_eq!(s.plan(1, 0, 3, 7, 5).action, 3);
    assert!(s.observe(local(1, 22, 10), false));
    assert!(s.confirm_departure(1, 3, 5, 101, 21));
    assert_eq!(s.plan(1, 0, 3, 7, 5).action, 1);
    s.abort(1);
    assert!(s.confirm_departure(1, 3, 5, 101, 21));
    assert_eq!(s.plan(1, 0, 3, 7, 5).reason, 8);
}
