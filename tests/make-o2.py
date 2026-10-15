#!/usr/bin/env python3
"""Writes an Odyssey 2 / Videopac cartridge (.bin, 2 KB) for the core's
tests. It needs no file of anyone's, but the machine needs its BIOS and the
video chip's character ROM.

usage: make-o2.py <out.bin> [nopad]

The BIOS starts a cartridge at &400. The program, hand-assembled below
(Intel 8048 machine code), runs with interrupts off and, for ever:
  - counts its turns at &20 of the processor's own RAM;
  - reads each joystick the way MAME's driver wires them: port 1 bit 2 low
    (the keyboard and joystick decoder on), port 2's low bits the joystick
    (0 or 1), then the data bus, where a held direction or button reads 0;
    joystick 0 goes to &22, joystick 1 to &23;
  - gives the video chip's background (register &A3) the count, so the
    picture changes as it runs.
&3C holds "O2T!" once the program runs. Made with "nopad" it reads no
joystick, so every frame is a frame that did not read its controls.
"""
import sys


def assemble(nopad):
    org = 0x400
    code = bytearray()
    labels = {}

    def b(*xs):
        code.extend(xs)

    def label(n):
        labels[n] = org + len(code)

    def jmp(target):
        # JMP addr: bits 8-10 of the address in the opcode, within the 2 KB bank
        b(((target >> 8) & 7) << 5 | 0x04, target & 0xFF)

    b(0x15, 0x35)                          # dis i / dis tcnti
    b(0xB8, 0x20)                          # mov r0,#&20
    b(0xBA, 0x1C)                          # mov r2,#28
    label("clr")
    b(0xB0, 0x00, 0x18)                    # mov @r0,#0 / inc r0
    b(0xEA, (labels["clr"]) & 0xFF)        # djnz r2,clr
    b(0xB8, 0x3C)                          # mov r0,#&3c
    for c in b"O2T!":
        b(0xB0, c, 0x18)                   # mov @r0,#c / inc r0
    label("loop")
    b(0xB8, 0x20, 0x10)                    # mov r0,#&20 / inc @r0
    if not nopad:
        for joy, at in ((0, 0x22), (1, 0x23)):
            b(0x23, 0xF8, 0x39)            # mov a,#&f8 / outl p1,a: decoder on (bit 2 low)
            b(0x23, 0xF8 | joy, 0x3A)      # mov a,#&f8+joy / outl p2,a: which joystick
            b(0x08)                        # ins a,bus
            b(0xB8, at, 0xA0)              # mov r0,#at / mov @r0,a
    b(0x23, 0xF4, 0x39)                    # mov a,#&f4 / outl p1,a: the video chip on
    b(0xB8, 0x20, 0xF0)                    # mov r0,#&20 / mov a,@r0
    b(0xB8, 0xA3, 0x90)                    # mov r0,#&a3 / movx @r0,a: its background
    jmp(labels["loop"])
    assert all(addr >> 8 == org >> 8 for addr in labels.values())
    return bytes(code + bytes(0x800 - len(code)))


def main():
    nopad = len(sys.argv) > 2 and sys.argv[2] == "nopad"
    rom = assemble(nopad)
    open(sys.argv[1], "wb").write(rom)
    print("%s: %d bytes%s" % (sys.argv[1], len(rom), " (no controls read)" if nopad else ""))


if __name__ == "__main__":
    main()
