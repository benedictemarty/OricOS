#!/usr/bin/env python3
"""
oricos-bundle.py — wrap a flat binary into an OricOS bundle (.oosobj).

Format OricOS Object v1 (cf. ADR-08, OricOS/CHANGELOG.md sprint 2.k.1) :
    Header (8 bytes) :
      +0  magic        "OOS\\x01"  (4B)
      +4  version      (1B = 0x01)
      +5  flags        (1B = 0)
      +6  num_sections (1B = 1)
      +7  reserved     (1B = 0)
    Section[0] entry (8 bytes) :
      +0  type         (1B = 0x01 CODE)
      +1  reserved     (1B)
      +2  size         (2B little-endian)
      +4  offset       (2B little-endian, = 16)
      +6  reserved     (2B)
    Section[0] data (offset 16 from bundle start).

v0.1 : 1 section CODE seule. Multi-section reportée v0.2.
"""

import struct
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: oricos-bundle.py <input.bin> <output.oosobj>",
              file=sys.stderr)
        return 1
    in_path, out_path = sys.argv[1], sys.argv[2]
    with open(in_path, "rb") as f:
        data = f.read()
    size = len(data)
    if size > 0xFFFF:
        print(f"Error: section CODE too large ({size} > 65535 bytes)",
              file=sys.stderr)
        return 1
    bundle = bytearray()
    # Header
    bundle += b"OOS\x01"
    bundle += bytes([0x01, 0x00, 0x01, 0x00])  # version, flags, nsec, reserved
    # Section[0] entry
    bundle += bytes([0x01, 0x00])              # type CODE, reserved
    bundle += struct.pack("<H", size)          # size LE
    bundle += struct.pack("<H", 16)            # offset = header(8) + entry(8)
    bundle += bytes([0x00, 0x00])              # reserved
    # Section[0] data
    bundle += data
    with open(out_path, "wb") as f:
        f.write(bytes(bundle))
    print(f"Bundle: {len(bundle)} bytes ({size} code), → {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
