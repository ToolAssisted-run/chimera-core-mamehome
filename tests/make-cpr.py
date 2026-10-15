#!/usr/bin/env python3
"""Writes an Amstrad GX4000 / CPC+ cartridge (.cpr) for the core's tests. It
needs no file of anyone's: the GX4000 has no ROM of its own and starts the
cartridge's first bank at address 0.

usage: make-cpr.py <out.cpr> [nopad]

The program, hand-assembled below (Z80 machine code), runs with interrupts
off, sets the video chip up as the CPC's firmware does, and for ever, once a
frame (it waits for the vertical sync to start):
  - counts the frames at &8000 (16 bits, low byte first), and gives the
    border the colour the count's low five bits name;
  - reads the ten rows of the keyboard matrix through the PPI and the sound
    chip (register 14), the way the CPC's firmware does, and copies each to
    &8008 + row (a bit is 0 while its key is held; row 9 is joystick 1, and
    the GX4000's second joystick is on row 6).
&8030 holds "CPRT" once the program runs. Made with "nopad" it reads no row
(only the sync), so every frame is a frame that did not read its controls.
"""
import struct
import sys


def assemble(nopad):
    code = bytearray()
    labels, fixups = {}, []

    def b(*xs):
        code.extend(xs)

    def label(n):
        labels[n] = len(code)

    def jr(op, target):
        b(op, 0)
        fixups.append(("rel", len(code) - 1, target))

    def jp(target):
        b(0xC3, 0, 0)
        fixups.append(("abs", len(code) - 2, target))

    b(0xF3)                              # di
    b(0x31, 0x00, 0xC0)                  # ld sp,&c000
    # the video chip (CRTC) as the CPC's firmware sets it: on a GX4000 nothing
    # else does, and with its registers at 0 it makes no vertical sync
    for reg, val in enumerate((63, 40, 46, 0x8E, 38, 0, 25, 30, 0, 7, 0, 0, 0x30, 0)):
        b(0x01, reg, 0xBC, 0xED, 0x49)   # ld bc,&bc00+reg / out (c),c: select it
        b(0x01, val, 0xBD, 0xED, 0x49)   # ld bc,&bd00+val / out (c),c: write it
    # clear &8000-&803f
    b(0x21, 0x00, 0x80)                  # ld hl,&8000
    b(0x06, 0x40)                        # ld b,64
    label("clr")
    b(0x36, 0x00)                        # ld (hl),0
    b(0x23)                              # inc hl
    jr(0x10, "clr")                      # djnz clr
    for i, c in enumerate(b"CPRT"):
        b(0x3E, c, 0x32, 0x30 + i, 0x80)  # ld a,c / ld (&8030+i),a
    label("loop")
    # wait for the vertical sync to start: PPI port B (&f5xx) bit 0
    label("w1")
    b(0x06, 0xF5, 0xED, 0x78)            # ld b,&f5 / in a,(c)
    b(0x1F)                              # rra
    jr(0x38, "w1")                       # jr c,w1  (wait while it is on)
    label("w2")
    b(0x06, 0xF5, 0xED, 0x78)
    b(0x1F)
    jr(0x30, "w2")                       # jr nc,w2 (wait until it starts)
    # count the frame
    b(0x2A, 0x00, 0x80)                  # ld hl,(&8000)
    b(0x23)                              # inc hl
    b(0x22, 0x00, 0x80)                  # ld (&8000),hl
    # the border's colour is the frame count (gate array: pen &10, colour &40+n),
    # so the picture changes as the program runs
    b(0x7D, 0xE6, 0x1F, 0xF6, 0x40)      # ld a,l / and &1f / or &40
    b(0x01, 0x10, 0x7F, 0xED, 0x49)      # ld bc,&7f10 / out (c),c: the border
    b(0xED, 0x79)                        # out (c),a: its colour
    if not nopad:
        b(0x21, 0x08, 0x80)              # ld hl,&8008
        b(0x1E, 0x40)                    # ld e,&40 (row 0, sound chip read)
        label("row")
        b(0x01, 0x82, 0xF7, 0xED, 0x49)  # ld bc,&f782 / out (c),c: ports A and C out
        b(0x01, 0x0E, 0xF4, 0xED, 0x49)  # ld bc,&f40e / out (c),c: register 14
        b(0x06, 0xF6, 0x3E, 0xC0, 0xED, 0x79)  # ld b,&f6 / ld a,&c0 / out (c),a: select it
        b(0xAF, 0xED, 0x79)              # xor a / out (c),a: inactive
        b(0x01, 0x92, 0xF7, 0xED, 0x49)  # ld bc,&f792 / out (c),c: port A in
        b(0x06, 0xF6, 0xED, 0x59)        # ld b,&f6 / out (c),e: the row, read
        b(0x06, 0xF4, 0xED, 0x78)        # ld b,&f4 / in a,(c)
        b(0x77, 0x23)                    # ld (hl),a / inc hl
        b(0x01, 0x82, 0xF7, 0xED, 0x49)  # ld bc,&f782 / out (c),c
        b(0x01, 0x00, 0xF6, 0xED, 0x49)  # ld bc,&f600 / out (c),c: inactive
        b(0x1C)                          # inc e
        b(0x7B, 0xFE, 0x4A)              # ld a,e / cp &4a
        jr(0x20, "row")                  # jr nz,row
    jp("loop")

    for kind, at, name in fixups:
        t = labels[name]
        if kind == "rel":
            d = t - (at + 1)
            assert -128 <= d <= 127, (name, d)
            code[at] = d & 0xFF
        else:
            code[at:at + 2] = struct.pack("<H", t)
    return bytes(code)


def cpr(program):
    # RIFF "AMS!", one 16 KB bank as chunk "cb00"
    bank = program + bytes(16384 - len(program))
    chunk = b"cb00" + struct.pack("<I", len(bank)) + bank
    body = b"AMS!" + chunk
    return b"RIFF" + struct.pack("<I", len(body)) + body


def main():
    nopad = len(sys.argv) > 2 and sys.argv[2] == "nopad"
    data = cpr(assemble(nopad))
    open(sys.argv[1], "wb").write(data)
    print("%s: %d bytes%s" % (sys.argv[1], len(data), " (no controls read)" if nopad else ""))


if __name__ == "__main__":
    main()
