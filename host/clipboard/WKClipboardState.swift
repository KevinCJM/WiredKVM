import WKClipboardStateCore

// No AppKit access: the coordinator supplies observations from its adapters.
// Own and use this instance on one serial executor (the existing main thread).
final class WKClipboardState {
    enum Provenance: UInt32 { case unknown = 0, local = 1, received = 2 }
    enum Action: UInt32 { case native = 0, transfer = 1, blocked = 2, refresh = 3 }
    struct Snapshot: Equatable {
        let side: UInt32
        let session, stamp, revision: UInt64
        let provenance: Provenance
        let originalSide: UInt32
        let originalSession, originalStamp: UInt64
        init(side: UInt32, session: UInt64, stamp: UInt64, revision: UInt64,
             provenance: Provenance = .local, originalSide: UInt32 = 0,
             originalSession: UInt64 = 0, originalStamp: UInt64 = 0) {
            self.side = side; self.session = session; self.stamp = stamp; self.revision = revision
            self.provenance = provenance; self.originalSide = originalSide
            self.originalSession = originalSession; self.originalStamp = originalStamp
        }
        fileprivate init(_ s: WKCSnapshot) {
            self.init(side: s.side, session: s.session, stamp: s.stamp, revision: s.revision,
                provenance: Provenance(rawValue: s.provenance) ?? .unknown,
                originalSide: s.original_side, originalSession: s.original_session,
                originalStamp: s.original_stamp)
        }
        fileprivate var raw: WKCSnapshot {
            WKCSnapshot(side: side, provenance: provenance.rawValue, session: session,
                stamp: stamp, revision: revision, original_side: originalSide, reserved: 0,
                original_session: originalSession, original_stamp: originalStamp)
        }
    }
    struct Projection {
        let generation, appliedSequence, focusEpoch: UInt64
        let selectedSide: UInt32?
        let cutBlocked: Bool
        let contextSide: UInt32
        let activeID: UInt64
    }
    struct Plan {
        let action: Action
        let reason: UInt32
        let id: UInt64
        let source, destination: Snapshot
        let focusEpoch, generation: UInt64
    }
    private let state: OpaquePointer
    init() { state = wkcs_create()! }
    deinit { wkcs_destroy(state) }

    @discardableResult func reset(side: UInt32, session: UInt64 = 0) -> Bool {
        wkcs_reset(state, side, session) == 1
    }
    @discardableResult func observe(_ snapshot: Snapshot, selectSource: Bool = false) -> Bool {
        wkcs_observe(state, snapshot.raw, selectSource ? 1 : 0) == 1
    }
    @discardableResult func select(sequence: UInt64, side: UInt32, cut: Bool = false,
                                   baselineStamp: UInt64 = 0) -> Bool {
        wkcs_select(state, sequence, side, cut ? 1 : 0, baselineStamp) == 1
    }
    @discardableResult func context(sequence: UInt64, side: UInt32, focusEpoch: UInt64) -> Bool {
        wkcs_context(state, sequence, side, focusEpoch) == 1
    }
    @discardableResult func confirmDeparture(side: UInt32, expectedSequence: UInt64,
                                            focusEpoch: UInt64, baselineSession: UInt64,
                                            baselineStamp: UInt64) -> Bool {
        wkcs_confirm_departure(state, side, expectedSequence, focusEpoch,
                               baselineSession, baselineStamp) == 1
    }
    func plan(id: UInt64, destination: UInt32, minSequence: UInt64,
              destinationRevision: UInt64, focusEpoch: UInt64) -> Plan {
        let p = wkcs_plan(state, id, destination, minSequence, destinationRevision, focusEpoch)
        return Plan(action: Action(rawValue: p.action) ?? .blocked, reason: p.reason, id: p.id,
            source: Snapshot(p.source), destination: Snapshot(p.destination),
            focusEpoch: p.focus_epoch, generation: p.generation)
    }
    func active(_ id: UInt64) -> Bool { wkcs_active(state, id) == 1 }
    @discardableResult func commit(id: UInt64, destinationSnapshot: Snapshot) -> Bool {
        wkcs_commit(state, id, destinationSnapshot.raw) == 1
    }
    func abort(_ id: UInt64 = 0) { wkcs_abort(state, id) }
    func snapshot(side: UInt32) -> Snapshot? {
        var value = WKCSnapshot()
        return wkcs_snapshot(state, side, &value) == 1 ? Snapshot(value) : nil
    }
    var snapshots: [Snapshot?] { [snapshot(side: 0), snapshot(side: 1)] }
    var projection: Projection {
        let p = wkcs_projection(state)
        return Projection(generation: p.generation, appliedSequence: p.applied_sequence,
            focusEpoch: p.focus_epoch, selectedSide: p.selected_side < 2 ? p.selected_side : nil,
            cutBlocked: p.cut_blocked == 1, contextSide: p.context_side, activeID: p.active_id)
    }
}
