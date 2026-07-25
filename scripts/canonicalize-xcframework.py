#!/usr/bin/env python3
"""Canonicalize generated XCFramework metadata for stable release archives."""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: canonicalize-xcframework.py PATH/Info.plist")
    path = Path(sys.argv[1])
    with path.open("rb") as source:
        payload = plistlib.load(source)
    payload["AvailableLibraries"] = sorted(
        payload.get("AvailableLibraries", []),
        key=lambda item: item["LibraryIdentifier"],
    )
    with path.open("wb") as destination:
        plistlib.dump(payload, destination, fmt=plistlib.FMT_XML, sort_keys=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
