#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/artifacts"
FRAMEWORK="$ARTIFACT_DIR/OperonCore.xcframework"
ARCHIVE="$ARTIFACT_DIR/OperonCore.xcframework.zip"

if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Missing XCFramework: $FRAMEWORK" >&2
  echo "Run scripts/build-apple-xcframework.sh first." >&2
  exit 1
fi

# Normalize generated timestamps and file order so CI and local release builds
# produce the same SwiftPM checksum from identical compiler output.
find "$FRAMEWORK" -exec touch -t 202001010000 {} +
rm -f "$ARCHIVE"
(
  cd "$ARTIFACT_DIR"
  export COPYFILE_DISABLE=1
  find OperonCore.xcframework -print | LC_ALL=C sort | zip -X -q "$ARCHIVE" -@
)

echo "Created $ARCHIVE"
xcrun swift package compute-checksum "$ARCHIVE"
