#!/usr/bin/env python3
"""Writes an Atari 7800 cartridge (.a78) for the core's tests. It needs no
file of anyone's, but the machine needs its BIOS: the PAL one (machine
a7800p), which starts a cartridge without the NTSC BIOS's signature check.

usage: make-a78.py <out.a78> [nopad]

The program, hand-assembled below (6502 machine code), at &C000 (16 KB),
runs with interrupts off and, for ever, once a frame (it waits for the
vertical blank to start, MARIA's MSTAT bit 7):
  - counts the frames at &1800 (16 bits, low byte first), and gives the
    background (MARIA's BACKGRND, &20) the colour the count's low byte names;
  - copies the joysticks (SWCHA, &280: P1 in the high four bits, P2 in the
    low four, up down left right from the lowest, 0 while held) to &1802,
    the console's switches (SWCHB, &282: Reset bit 0, Select bit 1, Pause
    bit 3, 0 while held) to &1803, and the TIA's six input ports (INPT0-INPT5, &08-&0D: the two-button
    joysticks' buttons, then the one-button fire of each) to &1808-&180D.
&1830 holds "A78T" once the program runs. Made with "nopad" it reads none of
them (only MSTAT), so every frame is a frame that did not read its controls.
"""
import struct
import sys


def assemble(nopad):
    org = 0xC000
    code = bytearray()
    labels, fixups = {}, []

    def b(*xs):
        code.extend(xs)

    def label(n):
        labels[n] = org + len(code)

    def branch(op, target):
        b(op, 0)
        fixups.append((len(code) - 1, target))

    label("reset")
    b(0x78, 0xD8)                          # sei / cld
    b(0xA2, 0xFF, 0x9A)                    # ldx #$ff / txs
    b(0xA9, 0x00, 0xA2, 0x3F)              # lda #0 / ldx #$3f
    label("clr")
    b(0x9D, 0x00, 0x18, 0xCA)              # sta $1800,x / dex
    branch(0x10, "clr")                    # bpl clr
    for i, c in enumerate(b"A78T"):
        b(0xA9, c, 0x8D, 0x30 + i, 0x18)   # lda #c / sta $1830+i
    label("loop")
    label("w1")
    b(0x2C, 0x28, 0x00)                    # bit $28 (MSTAT): N = vertical blank
    branch(0x30, "w1")                     # bmi w1: wait while it is on
    label("w2")
    b(0x2C, 0x28, 0x00)
    branch(0x10, "w2")                     # bpl w2: wait until it starts
    b(0xEE, 0x00, 0x18)                    # inc $1800
    branch(0xD0, "nocarry")
    b(0xEE, 0x01, 0x18)                    # inc $1801
    label("nocarry")
    b(0xAD, 0x00, 0x18, 0x85, 0x20)        # lda $1800 / sta $20: the background colour is the count
    if not nopad:
        b(0xAD, 0x80, 0x02, 0x8D, 0x02, 0x18)       # lda $280 / sta $1802
        b(0xAD, 0x82, 0x02, 0x8D, 0x03, 0x18)       # lda $282 / sta $1803
        b(0xA2, 0x05)                                # ldx #5
        label("inpt")
        b(0xB5, 0x08, 0x9D, 0x08, 0x18, 0xCA)       # lda $08,x / sta $1808,x / dex
        branch(0x10, "inpt")                         # bpl inpt
    b(0x4C, labels["loop"] & 0xFF, labels["loop"] >> 8)   # jmp loop
    label("irq")
    b(0x40)                                # rti

    for at, name in fixups:
        d = labels[name] - (org + at + 1)
        assert -128 <= d <= 127, (name, d)
        code[at] = d & 0xFF
    rom = bytearray(code + bytes(0x4000 - len(code)))
    # the cartridge's end: the region byte and the start of its ROM (the low
    # four bits 7: a 7800 cartridge), then the NMI, reset and IRQ vectors
    rom[0x3FF8] = 0xFF
    rom[0x3FF9] = 0xC7
    rom[0x3FFA:0x3FFC] = struct.pack("<H", labels["irq"])
    rom[0x3FFC:0x3FFE] = struct.pack("<H", labels["reset"])
    rom[0x3FFE:0x4000] = struct.pack("<H", labels["irq"])
    return bytes(rom)


def header(size, pal):
    h = bytearray(128)
    h[0] = 1
    h[1:17] = b"ATARI7800".ljust(16, b"\0")
    h[17:49] = b"Chimera test cartridge".ljust(32, b"\0")
    h[49:53] = struct.pack(">I", size)
    h[55] = h[56] = 1                      # a joystick in each port
    h[57] = 1 if pal else 0
    h[100:128] = b"ACTUAL CART DATA STARTS HERE"
    return bytes(h)


def main():
    nopad = len(sys.argv) > 2 and sys.argv[2] == "nopad"
    rom = assemble(nopad)
    open(sys.argv[1], "wb").write(header(len(rom), True) + rom)
    print("%s: %d bytes%s" % (sys.argv[1], 128 + len(rom), " (no controls read)" if nopad else ""))


if __name__ == "__main__":
    main()
