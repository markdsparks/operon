#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK="$ROOT_DIR/artifacts/OperonCore.xcframework"
SOURCE="$ROOT_DIR/tests/ffi/ios-link-smoke.c"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/operon-xcframework-link.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Missing XCFramework: $FRAMEWORK" >&2
  echo "Run make build-apple-xcframework first." >&2
  exit 1
fi

link_slice() {
  local sdk="$1"
  local architecture="$2"
  local slice="$3"
  local minimum_version="$4"

  xcrun --sdk "$sdk" clang \
    -arch "$architecture" \
    "$minimum_version" \
    "$SOURCE" \
    -I"$FRAMEWORK/$slice/Headers" \
    "$FRAMEWORK/$slice/liboperon_core.a" \
    -o "$TEMP_DIR/$sdk-$architecture"
}

link_slice iphoneos arm64 ios-arm64 -miphoneos-version-min=16.0
link_slice iphonesimulator arm64 ios-arm64_x86_64-simulator -mios-simulator-version-min=16.0
link_slice iphonesimulator x86_64 ios-arm64_x86_64-simulator -mios-simulator-version-min=16.0

echo "Verified device and Simulator XCFramework slices link successfully."
