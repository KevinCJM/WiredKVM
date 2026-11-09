# Protocol evidence and provenance

Reviewed 2026-11-05. This directory contains newly written, limited protocol code. No external crate, complete third-party driver, Apple product identity, or third-party firmware binary is incorporated. The optional `c-abi` feature now includes two attributed experimental protocol byte arrays; see `THIRD_PARTY_NOTICES.md` and `src/fixture.rs`.

## Primary implementation references

1. `timothyb89/bt2usb`, commit `53ecc1f728a44fdf20b7c950bd37c1855937b749` (2026-04-14).
   - [mt2_translate.rs](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2_translate.rs): 12-byte USB header, 9-byte contact records, up to 5 contacts, 16-bit timestamp, packed coordinates.
   - [interp.rs](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb-core/src/interp.rs): contact ID and state decoding.
   - [mt2.rs](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2.rs): reported Feature exchanges and touch lifecycle. Its descriptor and compound DB fixture are included only with `c-abi`; the DB's final 12 bytes are partly reconstructed upstream. The fixture is explicitly experimental. Its report-ID handling still requires independent USB verification.
   - Author attribution: Tim Buckley / timothyb89 and repository contributors. [Package manifest](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/Cargo.toml) and README declare `MIT OR Apache-2.0`; no standalone LICENSE file was found in the inspected tree. This is a provenance observation, not a legal conclusion about downstream distribution.
2. [Linux mainline hid-magicmouse.c](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c), read 2026-11-05: independently confirms MT2 USB report ID 0x02, nine-byte records, signed coordinate layout, ID low nibble and state high two bits. It is GPL-2.0-or-later. No Linux driver code is copied; this source is a cross-check of wire facts. It is not evidence of macOS acceptance.

The input encoder preserves all unknown record bits instead of assigning guessed contact shapes. Core tests intentionally use artificial records and artificial Feature payloads. FFI tests use the attributed candidate property fixture. None is an independently verified CH32/macOS capture. No contact synthesis is included in the C ABI stage.

## Known source ambiguity

The reference's touch comments mention Report ID 0x44 in places, while its emitted USB packet starts with 0x02 and embeds 0x31. This draft models the emitted packet format, also recognized by Linux. It does not claim every MT2 generation uses the same format.

The Feature state machine is an explicit normalized model. An eventual adapter must verify whether its USB stack already removes report IDs. Successful unit tests prove only the chosen model's bounded behavior; they do not resolve that external buffer contract.

All future direct third-party code reuse requires preserving the applicable notices and checking the exact files being imported. Source license declarations do not authorize Apple VID/PID or brand use. No production identity decision has been made here.
