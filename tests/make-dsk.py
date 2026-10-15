#!/usr/bin/env python3
"""Writes an Amstrad CPC disk image (.dsk, CPCEMU's standard format) for the
core's tests: AMSDOS's DATA format (40 tracks, one side, 9 sectors of 512
bytes numbered &C1 to &C9), with one file on it, so that CAT tells the disks
apart. It needs no file of anyone's.

usage: make-dsk.py <out.dsk> <NAME> [EXT]

The directory is the first four sectors of track 0: 64 entries of 32 bytes
(user, name, extension, extent, two reserved bytes, the number of 128-byte
records, and sixteen 1 KB block numbers), unused ones &E5. Blocks 0 and 1
are the directory; the file is block 2, one record of text.
"""
import struct
import sys

TRACKS, SECTORS, SECTOR = 40, 9, 512
IDS = [0xC1, 0xC6, 0xC2, 0xC7, 0xC3, 0xC8, 0xC4, 0xC9, 0xC5]   # the order on the track


def main():
    out, name = sys.argv[1], sys.argv[2].upper()
    ext = (sys.argv[3] if len(sys.argv) > 3 else "TXT").upper()
    # the disk as AMSDOS sees it: track t, sector &C1+s at (t*9+s)*512
    data = bytearray(b"\xE5" * (TRACKS * SECTORS * SECTOR))
    entry = bytes([0]) + name.encode().ljust(8)[:8] + ext.encode().ljust(3)[:3] + bytes([0, 0, 0, 1])
    entry += bytes([2]) + bytes(15)
    data[0:32] = entry
    text = ("This is disk %s.\r\n" % name).encode()
    block2 = 2 * 1024
    data[block2:block2 + 128] = text.ljust(128, b"\x1A")

    image = bytearray(256)
    image[0:34] = b"MV - CPCEMU Disk-File\r\nDisk-Info\r\n"
    image[34:48] = b"Chimera tests".ljust(14)
    image[48] = TRACKS
    image[49] = 1
    image[50:52] = struct.pack("<H", 256 + SECTORS * SECTOR)
    for t in range(TRACKS):
        info = bytearray(256)
        info[0:12] = b"Track-Info\r\n"
        info[16] = t
        info[17] = 0
        info[20] = 2            # 512 bytes
        info[21] = SECTORS
        info[22] = 0x4E         # gap 3
        info[23] = 0xE5         # filler
        sectors = b""
        for i, sid in enumerate(IDS):
            info[24 + 8 * i:24 + 8 * i + 8] = bytes([t, 0, sid, 2, 0, 0, 0, 0])
            s = sid - 0xC1
            sectors += data[(t * SECTORS + s) * SECTOR:(t * SECTORS + s + 1) * SECTOR]
        image += info + sectors
    open(out, "wb").write(image)
    print("%s: %d bytes, file %s.%s" % (out, len(image), name, ext))


if __name__ == "__main__":
    main()
