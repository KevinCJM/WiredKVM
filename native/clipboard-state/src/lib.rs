//! Bounded, OS-independent clipboard provenance and paste planning.
//!
//! Only this model assigns cross-machine routes. Endpoint adapters observe OS
//! versions; Copy selects an endpoint without manufacturing a new version.
//! Every mutating call belongs to the coordinator's single serial executor.

const NO_SIDE: u32 = 2;
const UNKNOWN: u32 = 0;
const LOCAL: u32 = 1;
const RECEIVED: u32 = 2;
const NATIVE: u32 = 0;
const TRANSFER: u32 = 1;
const BLOCKED: u32 = 2;
const REFRESH: u32 = 3;
const INVALID: u32 = 1;
const SEQUENCE: u32 = 3;
const REVISION: u32 = 4;
const UNKNOWN_SOURCE: u32 = 5;
const CUT_UNCONFIRMED: u32 = 6;
const FOCUS: u32 = 7;
const STALE: u32 = 8;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Snapshot {
    pub side: u32,
    pub provenance: u32,
    pub session: u64,
    pub stamp: u64,
    pub revision: u64,
    pub original_side: u32,
    pub reserved: u32,
    pub original_session: u64,
    pub original_stamp: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Origin {
    side: u32,
    session: u64,
    stamp: u64,
}

impl Snapshot {
    fn valid(self) -> bool {
        self.side < NO_SIDE
            && self.session != 0
            && self.stamp != 0
            && self.reserved == 0
            && match self.provenance {
                UNKNOWN | LOCAL => self.original_side == 0
                    && self.original_session == 0 && self.original_stamp == 0,
                RECEIVED => self.original_side < NO_SIDE
                    && self.original_session != 0 && self.original_stamp != 0,
                _ => false,
            }
    }
    fn origin(self) -> Option<Origin> {
        match self.provenance {
            LOCAL => Some(Origin { side: self.side, session: self.session, stamp: self.stamp }),
            RECEIVED => Some(Origin { side: self.original_side, session: self.original_session,
                stamp: self.original_stamp }),
            _ => None,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Projection {
    pub generation: u64,
    pub applied_sequence: u64,
    pub focus_epoch: u64,
    pub selected_side: u32,
    pub cut_blocked: u32,
    pub context_side: u32,
    pub reserved: u32,
    pub active_id: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Plan {
    pub action: u32,
    pub reason: u32,
    pub id: u64,
    pub source: Snapshot,
    pub destination: Snapshot,
    pub focus_epoch: u64,
    pub generation: u64,
}

#[derive(Clone, Copy, Debug)]
struct Selection {
    side: u32,
    cut: bool,
    baseline_session: u64,
    baseline_stamp: u64,
}

#[derive(Debug)]
pub struct State {
    snapshots: [Option<Snapshot>; 2],
    sessions: [u64; 2],
    selected: Option<Selection>,
    applied_sequence: u64,
    context_side: u32,
    focus_epoch: u64,
    generation: u64,
    active: Option<Plan>,
    last_plan_id: u64,
    last_plan_action: u32,
    last_plan_destination: u32,
}

impl Default for State {
    fn default() -> Self {
        Self { snapshots: [None; 2], sessions: [0; 2], selected: None,
            applied_sequence: 0, context_side: 0, focus_epoch: 0,
            generation: 1, active: None, last_plan_id: 0, last_plan_action: BLOCKED,
            last_plan_destination: NO_SIDE }
    }
}

impl State {
    fn changed(&mut self) { self.generation = self.generation.wrapping_add(1).max(1); }

    pub fn reset(&mut self, side: u32, session: u64) -> bool {
        if side >= NO_SIDE { return false; }
        self.snapshots[side as usize] = None;
        self.sessions[side as usize] = session;
        if self.selected.is_some_and(|s| s.side == side) { self.selected = None; }
        self.active = None;
        self.last_plan_action = BLOCKED;
        self.changed();
        true
    }

    pub fn observe(&mut self, snapshot: Snapshot, select_source: bool) -> bool {
        if !snapshot.valid() { return false; }
        let i = snapshot.side as usize;
        if self.sessions[i] != 0 && self.sessions[i] != snapshot.session { return false; }
        if let Some(old) = self.snapshots[i] {
            if snapshot.stamp < old.stamp { return false; }
            if snapshot.stamp == old.stamp { return old == snapshot; }
            if snapshot.revision <= old.revision { return false; }
        }
        self.sessions[i] = snapshot.session;
        self.snapshots[i] = Some(snapshot);
        // A source change invalidates its data, a destination change wins over
        // the incoming paste. A duplicate advertisement above does neither.
        if self.active.is_some_and(|p| p.source.side == snapshot.side
            || p.destination.side == snapshot.side) { self.active = None; }
        if select_source && snapshot.side == self.last_plan_destination {
            self.last_plan_action = BLOCKED;
        }
        if select_source && !self.selected.is_some_and(|s| s.side == snapshot.side && s.cut) {
            self.selected = Some(Selection { side: snapshot.side, cut: false,
                baseline_session: 0, baseline_stamp: 0 });
        }
        self.changed();
        true
    }

    pub fn select(&mut self, sequence: u64, side: u32, cut: bool, baseline_stamp: u64) -> bool {
        if side >= NO_SIDE || sequence == 0 || sequence <= self.applied_sequence { return false; }
        let baseline = self.snapshots[side as usize];
        self.applied_sequence = sequence;
        self.selected = Some(Selection { side, cut,
            baseline_session: baseline.map_or(0, |s| s.session),
            baseline_stamp: if baseline_stamp != 0 { baseline_stamp } else { baseline.map_or(0, |s| s.stamp) } });
        self.active = None;
        self.last_plan_action = BLOCKED;
        self.changed();
        true
    }

    pub fn context(&mut self, sequence: u64, side: u32, focus_epoch: u64) -> bool {
        if side >= NO_SIDE || sequence == 0 || sequence <= self.applied_sequence { return false; }
        self.applied_sequence = sequence;
        if self.context_side != side || self.focus_epoch != focus_epoch {
            self.active = None;
            self.last_plan_action = BLOCKED;
        }
        self.context_side = side;
        self.focus_epoch = focus_epoch;
        self.changed();
        true
    }

    /// Select a fresh local version confirmed by a matched departure barrier.
    /// The adapter must separately validate its nonce and unchanged destination
    /// OS revision. This must never be called for an ordinary advertisement.
    pub fn confirm_departure(&mut self, side: u32, expected_sequence: u64,
        focus_epoch: u64, baseline_session: u64, baseline_stamp: u64) -> bool {
        if side >= NO_SIDE || expected_sequence == 0 || baseline_session == 0 || baseline_stamp == 0
            || self.applied_sequence != expected_sequence || self.focus_epoch != focus_epoch
            || self.context_side == side { return false; }
        let Some(snapshot) = self.snapshots[side as usize] else { return false; };
        if snapshot.session != baseline_session || snapshot.stamp <= baseline_stamp
            || snapshot.provenance != LOCAL { return false; }
        // A barrier cannot turn a Cut without a confirmed new OS version into
        // a Copy of old content, even if the supplied departure baseline is old.
        if self.selected.is_some_and(|s| s.side == side && s.cut) && self.cut_blocked() {
            return false;
        }
        if self.selected.is_some_and(|s| s.side == side && !s.cut) && self.active.is_none() {
            return true;
        }
        if self.active.is_some() {
            self.active = None;
            self.last_plan_action = BLOCKED;
        }
        // A refresh has not sent content; it may resolve the same bounded V
        // using this newly confirmed source. Retired IDs stay retired.
        self.selected = Some(Selection { side, cut: false, baseline_session: 0, baseline_stamp: 0 });
        self.changed();
        true
    }

    fn cut_blocked(&self) -> bool {
        let Some(s) = self.selected else { return false; };
        if !s.cut { return false; }
        let Some(current) = self.snapshots[s.side as usize] else { return true; };
        s.baseline_session == 0 || s.baseline_stamp == 0
            || current.session != s.baseline_session || current.stamp <= s.baseline_stamp
            || current.provenance != LOCAL
    }

    pub fn plan(&mut self, id: u64, destination: u32, min_sequence: u64,
        destination_revision: u64, focus_epoch: u64) -> Plan {
        let rejected = |reason| Plan { id, action: BLOCKED, reason,
            focus_epoch, generation: self.generation, ..Plan::default() };
        if id == 0 { return rejected(INVALID); }
        if id < self.last_plan_id { return rejected(STALE); }
        if id == self.last_plan_id {
            if let Some(p) = self.active {
                if self.active(id) && p.destination.side == destination
                    && p.destination.revision == destination_revision && p.focus_epoch == focus_epoch
                    && min_sequence <= self.applied_sequence { return p; }
                return rejected(STALE);
            }
            // A refresh has not started a transaction. Only this unresolved
            // intent may be planned again after its metadata response arrives.
            if self.last_plan_action != REFRESH { return rejected(STALE); }
        }
        self.last_plan_id = id;
        self.last_plan_destination = destination;
        // New Paste owns the only transaction slot, even if its validation fails.
        self.active = None;
        self.changed();
        let p = self.resolve_plan(id, destination, min_sequence, destination_revision, focus_epoch);
        self.last_plan_action = if p.reason == CUT_UNCONFIRMED { REFRESH } else { p.action };
        p
    }

    fn resolve_plan(&mut self, id: u64, destination: u32, min_sequence: u64,
        destination_revision: u64, focus_epoch: u64) -> Plan {
        let mut p = Plan { id, action: BLOCKED, focus_epoch,
            generation: self.generation, ..Plan::default() };
        if id == 0 || destination >= NO_SIDE { p.reason = INVALID; return p; }
        if min_sequence > self.applied_sequence { p.action = REFRESH; p.reason = SEQUENCE; return p; }
        if destination != self.context_side || focus_epoch != self.focus_epoch { p.reason = FOCUS; return p; }
        let Some(selected) = self.selected else { p.action = NATIVE; return p; };
        // Same-machine Paste never waits for a version, a peer or a Cut result.
        if selected.side == destination { p.action = NATIVE; return p; }
        let Some(dest) = self.snapshots[destination as usize] else {
            p.action = REFRESH; p.reason = UNKNOWN_SOURCE; return p;
        };
        p.destination = dest;
        if dest.revision != destination_revision { p.reason = REVISION; return p; }
        let Some(source) = self.snapshots[selected.side as usize] else {
            p.action = REFRESH; p.reason = UNKNOWN_SOURCE; return p;
        };
        p.source = source;
        if self.cut_blocked() { p.reason = CUT_UNCONFIRMED; return p; }
        let Some(origin) = source.origin() else {
            p.action = REFRESH; p.reason = UNKNOWN_SOURCE; return p;
        };
        // Equality is a full source/endpoint-session/version tuple, never just
        // an OS count or numeric stamp shared by the two independent machines.
        if dest.origin() == Some(origin) { p.action = NATIVE; return p; }
        p.action = TRANSFER;
        self.active = Some(p);
        p
    }

    pub fn active(&self, id: u64) -> bool {
        id != 0 && self.active.is_some_and(|p| p.id == id
            && self.snapshots[p.source.side as usize] == Some(p.source)
            && self.snapshots[p.destination.side as usize] == Some(p.destination)
            && self.context_side == p.destination.side && self.focus_epoch == p.focus_epoch)
    }

    pub fn commit(&mut self, id: u64, destination: Snapshot) -> bool {
        if !self.active(id) || !destination.valid() { return false; }
        let Some(p) = self.active else { return false; };
        if destination.side != p.destination.side || destination.session != p.destination.session
            || destination.stamp <= p.destination.stamp || destination.revision <= p.destination.revision
            || destination.provenance != RECEIVED || destination.origin() != p.source.origin() {
            return false;
        }
        self.snapshots[destination.side as usize] = Some(destination);
        self.active = None;
        self.last_plan_action = BLOCKED;
        self.changed();
        true
    }

    pub fn abort(&mut self, id: u64) {
        if id == 0 || id == self.last_plan_id {
            self.active = None;
            self.last_plan_action = BLOCKED;
            self.changed();
        }
    }

    pub fn snapshot(&self, side: u32) -> Option<Snapshot> {
        if side >= NO_SIDE { None } else { self.snapshots[side as usize] }
    }

    pub fn projection(&self) -> Projection {
        Projection { generation: self.generation, applied_sequence: self.applied_sequence,
            focus_epoch: self.focus_epoch, selected_side: self.selected.map_or(NO_SIDE, |s| s.side),
            cut_blocked: u32::from(self.cut_blocked()), context_side: self.context_side,
            reserved: 0, active_id: self.active.map_or(0, |p| p.id) }
    }
}

// The C boundary accepts only bounded integers and fixed-size value records.
// Callers own the state, serialize access and must never pass a dangling pointer.
#[no_mangle]
pub extern "C" fn wkcs_create() -> *mut State { Box::into_raw(Box::new(State::default())) }
#[no_mangle]
pub unsafe extern "C" fn wkcs_destroy(state: *mut State) {
    if !state.is_null() { drop(Box::from_raw(state)); }
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_reset(state: *mut State, side: u32, session: u64) -> i32 {
    state.as_mut().map_or(0, |s| i32::from(s.reset(side, session)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_observe(state: *mut State, snapshot: Snapshot, select_source: u32) -> i32 {
    if select_source > 1 { return 0; }
    state.as_mut().map_or(0, |s| i32::from(s.observe(snapshot, select_source == 1)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_select(state: *mut State, sequence: u64, side: u32, cut: u32,
    baseline_stamp: u64) -> i32 {
    if cut > 1 { return 0; }
    state.as_mut().map_or(0, |s| i32::from(s.select(sequence, side, cut == 1, baseline_stamp)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_context(state: *mut State, sequence: u64, side: u32,
    focus_epoch: u64) -> i32 {
    state.as_mut().map_or(0, |s| i32::from(s.context(sequence, side, focus_epoch)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_confirm_departure(state: *mut State, side: u32,
    expected_sequence: u64, focus_epoch: u64, baseline_session: u64, baseline_stamp: u64) -> i32 {
    state.as_mut().map_or(0, |s| i32::from(s.confirm_departure(side, expected_sequence,
        focus_epoch, baseline_session, baseline_stamp)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_plan(state: *mut State, id: u64, destination: u32,
    min_sequence: u64, destination_revision: u64, focus_epoch: u64) -> Plan {
    state.as_mut().map_or(Plan { action: BLOCKED, reason: INVALID, id, ..Plan::default() },
        |s| s.plan(id, destination, min_sequence, destination_revision, focus_epoch))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_active(state: *const State, id: u64) -> i32 {
    state.as_ref().map_or(0, |s| i32::from(s.active(id)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_commit(state: *mut State, id: u64, destination: Snapshot) -> i32 {
    state.as_mut().map_or(0, |s| i32::from(s.commit(id, destination)))
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_abort(state: *mut State, id: u64) {
    if let Some(s) = state.as_mut() { s.abort(id); }
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_snapshot(state: *const State, side: u32, output: *mut Snapshot) -> i32 {
    let (Some(s), Some(out)) = (state.as_ref(), output.as_mut()) else { return 0; };
    let Some(snapshot) = s.snapshot(side) else { return 0; };
    *out = snapshot;
    1
}
#[no_mangle]
pub unsafe extern "C" fn wkcs_projection(state: *const State) -> Projection {
    state.as_ref().map_or(Projection { selected_side: NO_SIDE, ..Projection::default() }, State::projection)
}
