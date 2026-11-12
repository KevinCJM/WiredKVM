import WKClipboardStateCore

@main struct ClipboardStateABITest {
    static func main() {
        precondition(MemoryLayout<WKCSnapshot>.size == 56)
        precondition(MemoryLayout<WKCSProjection>.size == 48)
        precondition(MemoryLayout<WKCSPlan>.size == 144)
        let state = WKClipboardState()
        let source = WKClipboardState.Snapshot(side: 0, session: 100, stamp: 11, revision: 7)
        let destination = WKClipboardState.Snapshot(side: 1, session: 101, stamp: 21, revision: 9)
        precondition(state.observe(source) && state.observe(destination))
        precondition(state.select(sequence: 1, side: 0))
        precondition(state.context(sequence: 2, side: 1, focusEpoch: 5))
        let plan = state.plan(id: 1, destination: 1, minSequence: 2, destinationRevision: 9, focusEpoch: 5)
        precondition(plan.action == .transfer && state.active(1))
        let received = WKClipboardState.Snapshot(side: 1, session: 101, stamp: 22, revision: 10,
            provenance: .received, originalSide: 0, originalSession: 100, originalStamp: 11)
        precondition(state.commit(id: 1, destinationSnapshot: received))
        precondition(state.snapshots[1] == received && state.projection.selectedSide == 0)
        precondition(state.plan(id: 2, destination: 1, minSequence: 2,
            destinationRevision: 10, focusEpoch: 5).action == .native)
        precondition(state.context(sequence: 3, side: 0, focusEpoch: 6))
        let fresh = WKClipboardState.Snapshot(side: 1, session: 101, stamp: 23, revision: 11)
        precondition(state.observe(fresh))
        precondition(state.confirmDeparture(side: 1, expectedSequence: 3, focusEpoch: 6,
            baselineSession: 101, baselineStamp: 22))
        precondition(state.projection.selectedSide == 1 && state.projection.appliedSequence == 3)
        print("CLIPBOARD_STATE_SWIFT_ABI_PASS os_access=false clipboard_access=false usb_access=false")
    }
}
