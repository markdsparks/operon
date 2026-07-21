# Experimental C ABI

`operon-core` exposes a small C-compatible ABI for hosts that cannot link the
Rust API directly. It is intentionally a command/event driver: the host keeps
control of models, SQLite, files, platform permissions, cancellation, and
network access.

The public header is
[`operon_core.h`](../../crates/operon-core/include/operon_core.h). Build the
dynamic and static libraries with:

```bash
make build-c-abi
```

On macOS this produces `liboperon_core.dylib` and `liboperon_core.a` under
`target/release/`; other platforms use their native dynamic-library extension.

## Apple packaging

Build a distributable Apple artifact with:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
make build-apple-xcframework
```

This creates `artifacts/OperonCore.xcframework` with arm64 iPhone and universal
arm64/x86_64 Simulator static-library slices, each carrying the public header.
The artifact is intentionally ignored by Git. A release process can sign and
publish the resulting XCFramework without changing the C ABI.

To compile-link every packaged slice against the public C header (without
requiring a device), run:

```bash
make verify-apple-xcframework
```

## Ownership

- `operon_session_create` returns an opaque handle; destroy it exactly once with
  `operon_session_destroy`.
- `operon_session_start` and `operon_session_resume` allocate returned JSON and
  error strings; free each with `operon_string_free`.
- `operon_abi_version` returns a library-owned static string that must not be
  freed.
- A null `config_json` selects default configuration. `out_step_json` is
  required for start/resume; `out_error` is optional.

## Command loop

```text
host creates session
  → operon_session_start
  → { kind: "command", command: { kind: "generate" | "retrieve" | ... } }
host performs that native operation
  → operon_session_resume(event JSON)
  → next command or { kind: "complete", result: ... }
```

Commands, events, and completed results retain their versioned JSON protocol
shape. The ABI only adds an outer `{kind: command|complete}` envelope.

The repository includes `OperonCoreFFI`, a small macOS Swift developer bridge
that creates this handle, returns command envelopes, and accepts event
envelopes. An Apple host executes `generate` with Apple Foundation Models and
`search_memory` with its local store, then resumes the core. The C ABI itself
has no database, inference, filesystem, or network authority.

## Status

This is an experimental `0.1` ABI. Its handle lifecycle and JSON envelope are
covered by Rust and macOS Swift round-trip tests. The Swift bridge links a local
macOS dynamic library for development; an XCFramework, iOS integration, and a
cross-language replay suite remain before a stable ABI release.
