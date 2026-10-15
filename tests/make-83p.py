#!/usr/bin/env python3
"""Writes a TI-83 program file (.83p) for the core's tests: one TI-BASIC
program, CHIMERA, that shows 4242 when it is run (":Disp 4242", in TI's
tokens). It needs no file of anyone's.

usage: make-83p.py <out.83p> [name]

The format is TI's: the signature "**TI83**", three fixed bytes, a 42-byte
comment, the length of the entries; each entry is its header (its length,
11, then the data's length, the type, 5 for a program, and the 8-byte name),
the data's length again and the data (a program's own 2-byte length, then
its tokens); and at the end the 16-bit sum of the entries.
"""
import struct
import sys


def main():
    name = (sys.argv[2] if len(sys.argv) > 2 else "CHIMERA").encode()[:8]
    tokens = bytes([0xDE]) + b"4242"            # Disp 4242
    data = struct.pack("<H", len(tokens)) + tokens
    entry = struct.pack("<HHB", 11, len(data), 0x05) + name.ljust(8, b"\0") + struct.pack("<H", len(data)) + data
    comment = b"Chimera test program".ljust(42, b"\0")
    out = b"**TI83**" + bytes([0x1A, 0x0A, 0x00]) + comment + struct.pack("<H", len(entry)) + entry
    out += struct.pack("<H", sum(entry) & 0xFFFF)
    open(sys.argv[1], "wb").write(out)
    print("%s: %d bytes, program %s" % (sys.argv[1], len(out), name.decode()))


if __name__ == "__main__":
    main()
