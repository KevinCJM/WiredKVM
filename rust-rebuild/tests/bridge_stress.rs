//! These exercise actual recovered C routing, not hardware, AppKit clipboard,
//! automatic edge detection, USB latency, real file content, or SHA validation.
use wiredkvm_offline_regression::*;

fn read_cell(sim: &mut Simulator, destination: Port) -> [u8; CELL_BYTES] {
    let mut bytes = [0; CELL_BYTES];
    assert_eq!(sim.read(destination, &mut bytes), CELL_BYTES);
    bytes
}

#[test]
fn both_bulk_queues_full_still_service_120000_hid_probes() {
    let report = run_routing_stress(120_000).unwrap();
    assert_eq!(report.hid_services, 120_000);
    assert_eq!(report.routed_cells_per_direction, 120_000);
    assert_eq!(report.routed_bytes, 122_880_000);
    assert_eq!(report.bulk_high_water, BULK_SLOTS as u32);
    assert!(report.core_bytes <= 200 * 1024);
    eprintln!("routing-only stress: {report:?}; no physical latency or SHA claim");
}

#[test]
fn cancel_full_old_queue_admits_new_transaction_without_draining() {
    for origin in [Port::Host, Port::Target] {
        cancel_direction_without_draining(origin);
    }
}

fn cancel_direction_without_draining(origin: Port) {
    let mut sim = Simulator::new().unwrap();
    let receiver = origin.peer();
    let epoch = 71;
    assert!(sim.session(epoch));
    assert!(sim.grant(origin, epoch, [1; 16], 1));
    assert!(sim.grant(origin, epoch, [2; 16], 2));
    assert!(sim.grant(receiver, epoch, [3; 16], 1));
    for sequence in 0..BULK_SLOTS {
        let id = if sequence % 2 == 0 { [1; 16] } else { [2; 16] };
        assert_eq!(
            sim.write(origin, &RoutingCell::data(epoch, id, sequence as u64).0),
            CELL_BYTES
        );
        assert_eq!(
            sim.write(
                receiver,
                &RoutingCell::data(epoch, [3; 16], sequence as u64).0
            ),
            CELL_BYTES
        );
    }
    assert!(sim.control(
        receiver,
        &BulkControl {
            kind: ControlKind::Cancel,
            origin,
            epoch,
            id: [1; 16],
            generation: 1
        }
    ));
    assert!(sim.hid_probe(1));
    // No read/drain or artificial wait occurs between cancel, new grant and write.
    assert!(sim.grant(origin, epoch, [4; 16], 3));
    let new = RoutingCell::data(epoch, [4; 16], 0);
    assert_eq!(sim.write(origin, &new.0), CELL_BYTES);
    assert!(
        !sim.grant(origin, epoch, [1; 16], 1),
        "late grant revived cancellation"
    );
    for sequence in (1..BULK_SLOTS).step_by(2) {
        assert_eq!(
            read_cell(&mut sim, receiver),
            RoutingCell::data(epoch, [2; 16], sequence as u64).0
        );
    }
    assert_eq!(read_cell(&mut sim, receiver), new.0);
    for sequence in 0..BULK_SLOTS {
        assert_eq!(
            read_cell(&mut sim, origin),
            RoutingCell::data(epoch, [3; 16], sequence as u64).0
        );
    }
    let stale = RoutingCell::data(epoch, [1; 16], 99);
    assert_eq!(
        sim.write(origin, &stale.0),
        CELL_BYTES,
        "C write counts consumed, not admitted, bytes"
    );
    assert_eq!(sim.read(receiver, &mut [0; CELL_BYTES]), 0);
    sim.close();
}

#[test]
fn disconnect_purges_queued_partial_and_inflight_cells_in_both_directions() {
    let mut sim = Simulator::new().unwrap();
    let old_epoch = 80;
    assert!(sim.session(old_epoch));
    for (port, id) in [(Port::Host, [5; 16]), (Port::Target, [6; 16])] {
        assert!(sim.grant(port, old_epoch, id, 1));
        let cell = RoutingCell::data(old_epoch, id, 0);
        assert_eq!(sim.write(port, &cell.0), CELL_BYTES);
        // Force the C simulator's in-flight read buffer and a partial OUT cell.
        assert_eq!(sim.read(port.peer(), &mut [0; 7]), 7);
        assert_eq!(sim.write(port, &cell.0[..137]), 137);
    }
    sim.connect(Port::Target, false, 1);
    assert_eq!(sim.write(Port::Host, &[0; CELL_BYTES]), 0);
    sim.connect(Port::Target, true, 2);
    for destination in [Port::Host, Port::Target] {
        assert_eq!(sim.read(destination, &mut [0; CELL_BYTES]), 0);
    }
    // Old complete frames are consumed but cannot pass without fresh sessions.
    for port in [Port::Host, Port::Target] {
        assert_eq!(
            sim.write(port, &RoutingCell::data(old_epoch, [5; 16], 0).0),
            CELL_BYTES
        );
        assert_eq!(sim.read(port.peer(), &mut [0; CELL_BYTES]), 0);
    }
    assert!(sim.session(81));
    for (port, id) in [(Port::Host, [5; 16]), (Port::Target, [6; 16])] {
        assert!(sim.grant(port, 81, id, 2));
        // Reusing the ID must not make a stale session's full frame valid.
        assert_eq!(
            sim.write(port, &RoutingCell::data(old_epoch, id, 0).0),
            CELL_BYTES
        );
        assert_eq!(sim.read(port.peer(), &mut [0; CELL_BYTES]), 0);
        let fresh = RoutingCell::data(81, id, 0);
        assert_eq!(sim.write(port, &fresh.0), CELL_BYTES);
        assert_eq!(read_cell(&mut sim, port.peer()), fresh.0);
    }
    assert!(sim.hid_probe(3));
    sim.close();
}

#[test]
fn bad_control_crc_cannot_cancel_admitted_transaction() {
    let mut sim = Simulator::new().unwrap();
    assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    assert!(sim.session(90));
    assert!(sim.grant(Port::Host, 90, [9; 16], 1));
    let mut report = BulkControl {
        kind: ControlKind::Cancel,
        origin: Port::Host,
        epoch: 90,
        id: [9; 16],
        generation: 1,
    }
    .encode();
    report[60] ^= 1;
    assert!(!sim.control_bytes(Port::Target, &report));
    let cell = RoutingCell::data(90, [9; 16], 0);
    assert_eq!(sim.write(Port::Host, &cell.0), CELL_BYTES);
    assert_eq!(read_cell(&mut sim, Port::Target), cell.0);
    sim.close();
}
