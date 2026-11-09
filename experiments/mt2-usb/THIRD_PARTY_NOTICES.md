# Experimental fixture attribution

`src/fixture.rs` contains the 110-byte USB HID descriptor and 75-byte compound
property fixture published by **Tim Buckley / timothyb89 and contributors** in
[`bt2usb/src/mt2.rs`](https://github.com/timothyb89/bt2usb/blob/53ecc1f728a44fdf20b7c950bd37c1855937b749/bt2usb/src/mt2.rs).
Fixed upstream commit: `53ecc1f728a44fdf20b7c950bd37c1855937b749`.

The upstream package declares `MIT OR Apache-2.0`. This experimental derivative
preserves that declaration and attribution; the included Apache-2.0 license text
is in `LICENSE-APACHE-2.0.txt`. Upstream has no standalone copyright/license
notice in the inspected file/tree. No missing notice is invented here.

Changes: only the two protocol byte arrays are included, under new constant names
and an explicit experiment warning. The upstream handler, timing engine,
Bluetooth frontend, actuator implementation and complete driver are not copied.
The C ABI, bounded encoder and tests are newly written in this directory.

**The property fixture's final 12 bytes were reconstructed upstream, not captured
in full.** It is a candidate for an enumeration experiment, not certified device
data or proof that any CH32/macOS pair accepts it. No Apple identity is declared
by this crate, and this license does not grant rights to Apple VID/PID or branding.
Before distributing a derived product, verify source notices and device identity
separately. Nothing in this prototype authorizes production use of Apple's VID.
