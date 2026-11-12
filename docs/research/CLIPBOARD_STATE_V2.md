# Clipboard state and standard representations

The build-16 implementation keeps USB descriptors, firmware, independent input, the
file stream and the Finder portal. The Book engine owns a std-only Rust state
model through a small C ABI. Swift owns OS adapters and serial I/O. State-core
calls never contain clipboard/file bytes.

## State and intent

- Endpoint 0 is Book; endpoint 1 is the target. Each observation has an endpoint
  session, logical stamp, actual OS revision and local/received/unknown lineage.
- Native Copy/Cut is delivered once. `SELECT` chooses an endpoint/version;
  neither shortcut manufactures a clipboard revision. Cut needs a newer native
  version before cross-machine use; same-machine paste always stays native.
- Capture sends ordered `CONTEXT`, `SELECT`, numeric `PASTE` and `CANCEL` intents.
  The engine returns a nine-field `ROUTE` projection and `RESULT`. Capture keeps
  only a projection and pending focus/input intent, not content provenance.
- A paste pins source and destination versions. Local copy, focus/safety loss,
  cancellation, disconnect or a retired intent prevents late publication/replay.
- A successful receive records its exact original endpoint/session/stamp.
  Matching destination lineage reuses the native clipboard and sends no body.
- Initial observations establish existing versions without claiming a new copy.
  A nonce-bound departure snapshot resolves a late target menu copy; a new Book
  copy or input context invalidates that snapshot. An unseen future remote copy
  cannot alter a native paste that has already executed; it is never replayed.

## Representations and transport

Items and their order are preserved. Standard UTF-8 text, HTML, RTF, PNG/TIFF
images and file references are supported; private types are ignored. An image
uses one PNG body, converting only when required, with TIFF prepared once on the
receiving worker. A bad optional image may be omitted when the same item has a
valid standard text representation; revision, cancellation and capacity errors
still reject the transaction.

The `WKCB` container has a bounded JSON descriptor plus raw binary segments and
checksums. Images and formatted representation bodies use Bulk, never JSON/Data
Base64 or HID fallback. Only a file-reference-only descriptor, containing no
representation/file bytes, may use the bounded control lane to enable Finder
progress before file data arrives. Files keep the current stream/collection and
verified-prefix portal. Collection and bundle READY notifications are distinct,
queued, and both required before publication. Their new Bulk generations must
increase in publication order.

Limits: 128 items; text/HTML/RTF each 1 MiB; PNG 64 MiB; source image budget
128 MiB, each dimension <=8192 and <=16,777,216 pixels; container 128 MiB and
descriptor 1 MiB; additional generated TIFF data totals at most 128 MiB. File
data remains separate (64 GiB stream limit, at most 128 selected roots).

Build 16 requires state-v2/multi-representation capability flags. Invalid or old
peers disable cross-machine clipboard only. Missing Bulk rejects media without
reading it or falling back to the old body channel. Keyboard/mouse/touch stay
independent. The target runs from the cable image, with no installed component.

## Verification

Run Rust state tests, Swift/C ABI checks, private-pasteboard bundle tests and input/capture regressions. Physical acceptance is separate from simulation. Keep device identities, local paths, raw logs and measurements outside public commits.
