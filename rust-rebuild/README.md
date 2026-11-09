# Rust recovery tools

Zero third-party dependencies. Rust 2021. macOS host compiler required for the recovered C bridge test fixture.

This crate adds build and regression entry points. It does not claim that the recovered C firmware or Swift endpoints have been ported to Rust.

`cargo test --offline` exercises the real recovered bridge in memory. `cargo run --offline --` prints build commands. Builds require a new output directory and leave partial output on failure.

The tool contains no recursive deletion, USB device access, controller launch, installation, or permission changes. Tests never read or write clipboard contents. The C simulator has explicit RAM-only release; fixtures do not perform filesystem cleanup.

The 120,000-probe stress result measures routing correctness, not physical latency or throughput. See the project README for the exact limits.
