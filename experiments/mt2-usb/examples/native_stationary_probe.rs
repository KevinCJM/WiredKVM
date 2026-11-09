//! Emit a finite fixture only. No USB, input APIs or clipboard access.
use wiredkvm_mt2_protocol_draft::{
    native_format::{usb_frame, FingerKind, NativeContact, NativeState},
    Geometry,
};
fn emit(epoch: u32, contacts: &[NativeContact], time: u32, delay: u32) {
    let p = usb_frame(contacts, time).unwrap();
    let hex = p
        .as_bytes()
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect::<String>();
    println!("{delay} MT2D,{epoch},{hex}");
}
fn main() {
    let g = Geometry {
        major: 20,
        minor: 20,
        size: 10,
        pressure: 5,
        orientation: 0,
    };
    let kinds = [
        FingerKind::Index,
        FingerKind::Middle,
        FingerKind::Ring,
        FingerKind::Little,
    ];
    for n in [2, 4] {
        let epoch = 100 + n as u32;
        println!("0 MT2B,{epoch}");
        let c = (0..n)
            .map(|i| {
                NativeContact::new(
                    (i as i16 * 700) - 1100,
                    0,
                    i as u8 + 1,
                    kinds[i],
                    NativeState::Start,
                    g,
                )
                .unwrap()
            })
            .collect::<Vec<_>>();
        emit(epoch, &c, 0, 8);
        let active = c
            .iter()
            .map(|c| c.with_state(NativeState::Active))
            .collect::<Vec<_>>();
        for i in 1..=24 {
            emit(epoch, &active, i * 16, 16);
        }
        let stop = c
            .iter()
            .map(|c| c.with_state(NativeState::Stop))
            .collect::<Vec<_>>();
        emit(epoch, &stop, 400, 16);
        let gone = c
            .iter()
            .map(|c| c.with_state(NativeState::Inactive))
            .collect::<Vec<_>>();
        emit(epoch, &gone, 416, 16);
        emit(epoch, &[], 432, 16);
        println!("16 MT2E,{epoch}");
    }
}
