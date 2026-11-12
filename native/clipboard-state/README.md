# Clipboard state core

This std-only Rust library observes no OS clipboard, USB device, file or clock.
The Book coordinator owns one instance on its serial executor. Endpoint 0 is
Book; endpoint 1 is mini. Swift imports the fixed C ABI as `WKClipboardStateCore`.

- Each endpoint session binds on reset or its first snapshot. A new session must
  reset that side before observing snapshots. Versions increase within a session;
  a new version must also have a newer actual OS revision. Duplicate snapshots
  do not select a source or invalidate work.
- Copy selects an existing version without minting one. Cut remains blocked
  until the same session supplies a newer local version than its pre-cut stamp.
  A Cut with no known baseline cannot claim that an initial snapshot proves it.
- Input sequences and paste IDs are independent, nonzero monotonic counters.
  Context and selection share the input sequence. A future sequence requests
  metadata resolution; same-machine paste remains native without content I/O.
- A new paste ID replaces the only active transaction. Repeating that active ID
  is idempotent. An unresolved refresh or Cut can retry the same ID; abort, reset,
  new source selection, a destination copy or completion retires it. Retired IDs
  cannot reopen transactions or cancel a newer one.
- A transfer pins both endpoint snapshots and focus epoch. Changing either
  snapshot or focus invalidates it. Commit requires a real destination OS write
  and the exact full original endpoint/session/version lineage. Existing matching
  lineage uses native paste instead of another transfer.
- Callers must abort on input safety, timeout or disconnect. They retain bounded
  timers and OS-specific checks; this model neither waits nor reads content.
- `confirmDeparture` accepts a freshly observed local source only for the exact
  current input sequence/focus after leaving that side and a matching baseline
  session with a newer stamp. The caller must validate a nonce-bound departure
  reply and unchanged destination clipboard revision first. Ordinary keepalives
  cannot invoke it. It does not invent an input sequence or unlock an unconfirmed
  Cut. An unresolved refresh may continue; active transfers and retired IDs
  cannot be revived by this confirmation.

Offline tests:

```sh
cargo test --offline --locked --manifest-path native/clipboard-state/Cargo.toml --target-dir /tmp/wk-state-target
cargo build --offline --locked --release --manifest-path native/clipboard-state/Cargo.toml --target-dir /tmp/wk-state-target
swiftc -O -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path /tmp/wk-state-swift-cache -I native/clipboard-state/include host/clipboard/WKClipboardState.swift native/clipboard-state/tests/swift_abi.swift /tmp/wk-state-target/release/libwiredkvm_clipboard_state.a -o /tmp/wk-state-swift-abi
/tmp/wk-state-swift-abi
```

These tests do not prove real application, hardware or transport acceptance.
