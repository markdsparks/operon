#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER_DIR="$ROOT_DIR/crates/operon-core/include"
OUTPUT_PATH="$ROOT_DIR/artifacts/OperonCore.xcframework"
OUTPUT_PARENT="$(dirname "$OUTPUT_PATH")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/operon-xcframework.XXXXXX")"
STAGED_OUTPUT="$TEMP_DIR/OperonCore.xcframework"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  if ! rustup target list --installed | grep -qx "$target"; then
    echo "Missing Rust target '$target'. Install it with:" >&2
    echo "  rustup target add $target" >&2
    exit 1
  fi
  cargo build --release --package operon-core --target "$target"
done

SIMULATOR_LIBRARY="$TEMP_DIR/liboperon_core.a"
lipo -create \
  "$ROOT_DIR/target/aarch64-apple-ios-sim/release/liboperon_core.a" \
  "$ROOT_DIR/target/x86_64-apple-ios/release/liboperon_core.a" \
  -output "$SIMULATOR_LIBRARY"

mkdir -p "$OUTPUT_PARENT"
xcodebuild -create-xcframework \
  -library "$ROOT_DIR/target/aarch64-apple-ios/release/liboperon_core.a" \
  -headers "$HEADER_DIR" \
  -library "$SIMULATOR_LIBRARY" \
  -headers "$HEADER_DIR" \
  -output "$STAGED_OUTPUT"

# This is a generated, Git-ignored artifact. Replace only this known output so
# `make build-apple-xcframework` is safe to repeat during local development.
rm -rf "$OUTPUT_PATH"
mv "$STAGED_OUTPUT" "$OUTPUT_PATH"

echo "Created $OUTPUT_PATH"
