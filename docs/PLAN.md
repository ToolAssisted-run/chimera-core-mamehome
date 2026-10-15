# The plan

This core is part of the owner's goal of 2026-10-12: every system BizHawk
runs, in Chimera. After the Commodore 64 (the VICE core), the systems BizHawk
runs on its own emulators were left: the Atari 7800, the Intellivision, the
Vectrex, the Odyssey 2, the Channel F, the Amstrad CPC and the TI-83. Each
needed an emulator chosen. This page says what was chosen and why, what was
measured, and what is not done.

## Why one MAME core for six systems

- **MAME emulates all of them**, and for most of them it is the reference:
  its 7800 driver is the one the A7800 emulator grew from; its Vectrex,
  Odyssey 2, Channel F and CPC drivers are maintained with the hardware's
  documentation in hand.
- **Chimera already runs MAME twice** (the arcade core and the X68000 core):
  how MAME is built for the sandbox, its patches (no host clock, no sound
  thread, the frontend told of every port read), and the frontend that
  replaces MAME's own are all proven. This core starts from the arcade core's
  files and changes what a home machine needs differently.
- **One package, many machines**, as ares and Genesis Plus GX are in
  Chimera: one `core.wbx` and a Machine setting, each machine with its own
  system id, controls and firmware.
- The alternatives were one small emulator a system (ProSystem, FreeIntv,
  vecx, O2EM, FreeChaF, Caprice32): six ports, six sets of traps, and for
  several of them a less exact machine than MAME's.

## What differs from the arcade core

- **Which machine**: the Machine setting, not the name of a rom set.
- **The game's files** go into the machine's own media devices (cartridge
  slot, disk drives, tape, snapshot) by their extensions, not into MAME's rom
  path.
- **Controls**: each machine its own list, named after MAME's (mame-driver.cpp
  says how), instead of one arcade panel of every control. The walk
  (`run-native --walk`) runs the same naming code over every machine without
  running any, and `gen-config.py` writes each machine's entry from it.
- **Firmware**: fixed per machine, so it is declared in the package (with
  the condition it is needed on: the machine, and for a BIOS's file the BIOS
  setting) and checked by MAME's audit before the machine is built.
- **Memory domains**: home machines often keep their RAM in a driver's own
  arrays (the Intellivision) or in RAM a memory map declares without naming
  it. Both are domains, beside MAME's named memory.
- **Hash files**: an Intellivision `.bin` cartridge has no header; MAME lays
  it out by its `intv.hsi` list, which the core carries as text (patch 0007).

## The pin

MAME 0cacb1a7 (2026-09-28), the commit the arcade and X68000 cores build, so
their patches apply unchanged. It moves with them.

## Machines

`waterbox/machines.txt`: 25 machines of the 67 the seven driver files
declare. Left out: prototypes and clones that add nothing (the Odyssey 3, the
Channel F's other licensed models), the KC Compact and the Aleste, and the TI
calculators other than the TI-83 (BizHawk has the TI-83 only).

## The TI-83's link cable

MAME emulates the TI-83 but cannot send it a program from a file; BizHawk
does it through the link cable, and so does this core (owner, 2026-10-15:
"Yes you should"). Patch 0008 adds a device on MAME's TI-8x link port
(`chimerafile`, chosen when the project has a `.83p` or `.83g`): the
computer's side of TI's silent link protocol (RTS, then ACK and DATA after
the calculator's CTS, then EOT), three seconds after power-on and again every
half second until the calculator takes it. Found on the way:

- MAME's TI-83 port read showed only the far side's pull-down on each line,
  not the calculator's own (the lines are wired-AND, and MAME's TI-85 read
  mixes both). The calculator's link routine waits for "my line low, the
  other released", never saw it, and took each bit by its 0.64-second
  timeout: a byte every 5 seconds. Patch 0010 reads the calculator's own
  pull-down too; a byte then takes half a millisecond.
- The calculator's ACK and CTS carry a length (11) and no data: only the
  commands that carry data take their length as data.
- A reply started the instant the calculator's last bit completes makes it
  time out waiting for both lines to go idle, and drop the transfer: each
  reply waits 5 ms.
- A TI-83 does not answer an EOT.

The default BIOS is OS 1.08, not MAME's 1.10: the newest whose ROM BizHawk
users have (the owner's folder has 1.02 to 1.08).

## Disks (owner, 2026-10-15: "Proceed with cpc swapping")

- Previous Disk, Next Disk and Eject Disk: controls of the core's own on
  every machine with a disk drive, after its MAME controls. A control acts
  when it goes down, at the start of the next frame, on MAME's own stack.
  All of the project's disks are one list for drive A (drive B stays
  empty), as the VICE core does for the 1541.
- Patch 0011: every file MAME opens for writing is a copy in memory of the
  file it names, and every later open of that name is the copy. Before it, a
  disk was write-protected in the sandbox (its files are read-only) and
  writable in the reference build, which wrote to the test's own files.
- Patch 0012: MAME cannot write the CPC's DSK format, so a disk's changes
  lived only in its in-memory image and were lost when it came out. A disk
  taken out is now kept, by its file's name, with any write still in
  progress put on it first, and putting it in again takes it back. It is
  kept changed or not: when the motor stops MAME clears "changed" after
  "writing back" a format it cannot write.
- A file AMSDOS saves is renamed from X.$$$ to X.BAS a few seconds after
  "Ready"; a disk taken out before that keeps X.$$$, as a real one would.

## Measured (2026-10-15)

- MAME's libraries: about 5 minutes a flavor on 14 processors. `core.wbx` is
  67 MB.
- The test script: 73 passed, 0 failed, 0 skipped, with the local folders.
  - The package is what the walk gives (24 machines, 18 settings, 30
    firmware files), and Chimera's own package checks pass (18).
  - The GX4000, on a cartridge the test writes (`tests/make-cpr.py`): it
    runs and counts its frames; each of the 12 joystick controls clears its
    own bit of the keyboard matrix, the CPC's wiring (joystick 1 row 9,
    joystick 2 row 6, bits 0 to 5); no lag frame when it reads the
    joysticks, every frame a lag frame when it reads nothing.
  - The 7800 (PAL BIOS, a cartridge the test writes): P1's directions are
    SWCHA's high four bits and P2's its low four; each button of a
    two-button joystick sets its own TIA input and clears its player's fire
    input; Reset, Select and Pause are SWCHB's bits 0, 1 and 3.
  - The Odyssey 2 (a cartridge the test writes): each joystick read on the
    data bus, up, right, down, left and fire in bits 0 to 4.
  - The default key bindings name only keys Chimera sends (205 names).
  - The CPC6128 with two disks the test writes (tests/make-dsk.py): CAT
    (typed with tests/type-keys.py) reads disk ONE, then TWO after Next
    Disk; a program saved to ONE is still on it after Next Disk and
    Previous Disk; after Eject Disk CAT reads no directory; the swaps run
    the same in the reference, the sandbox and with a state saved and
    loaded every frame; the disk files given are never written. A planted
    fault (Next Disk putting the same disk back) failed two of these tests.
    On Windows, a project's Next Disk and CAT give Linux's picture.
  - The TI-83 (OS 1.08): a program file the test writes
    (tests/make-83p.py) goes over the link cable; its tokens and its
    catalogue entry are in RAM afterwards, and not without the file; ON,
    PRGM, ENTER, ENTER runs it (the screen shows 4242), and the same keys
    with no file change the screen differently.
  - For the GX4000, the Intellivision (Astrosmash), the Channel F (its
    built-in games), the Vectrex (Mine Storm), the 7800, the Odyssey 2 and
    the CPC6128 (BASIC, its keys pressed at random) and the TI-83: the
    sandbox gives the
    reference's digests every 50 frames under a wander over every control;
    a run without the wander differs; a state saved and loaded every frame,
    and a state moved to a new sandbox, change nothing.
  - The Intellivision with a firmware file taken out is refused, naming the
    file; its disc is sixteen buttons or two axes as its set-up switch says.
- Through Chimera's engine (chimera-run), as projects with movies: the
  GX4000 cartridge with P1 Up held reads its joystick row as held, and as
  free with an idle movie; Astrosmash with its firmware starts when the
  movie presses Enter.
- In Chimera's window (tests/run-frontend.sh, 4 passed): the GX4000
  cartridge runs 300 frames and its RAM is the headless runner's; the
  package's keys become Chimera's; the Intellivision without its firmware
  is refused, naming exec.bin; with the firmware in Chimera's configuration
  Astrosmash's RAM is the headless runner's.
- Windows (chimera-run.exe, cross-built from Chimera): the GX4000 project's
  RAM and picture, and the Astrosmash project's picture, are byte for byte
  Linux's.
- Two faults planted on purpose were caught: two controls swapped in the
  package (two tests failed), and two controls swapped in the core (the
  wiring test failed).

## Firmware the owner's folder has

Every file the tested machines need matches MAME's: the Intellivision's
Executive ROM and GROM, the Channel F's three ROMs, the Vectrex's 8 KB ROM
(BizHawk's `VEC_Minestorm.vec`; BizHawk's 4 KB BIOS file is its second
half), the 7800's NTSC and PAL BIOSes, the Odyssey 2's BIOS and the 8244
video chip's character ROM (`charset_i8244.bin`, which BizHawk keeps in its
code), and the CPC464, CPC664 and CPC6128 ROMs with the disk ROM. The
owner's folder has no game for the 7800, the Odyssey 2 or the CPC, so the
tests write their own cartridges (tests/make-a78.py, tests/make-o2.py) and
the CPC runs BASIC. The TI-83's OS 1.02 to 1.08 match MAME's.

## Not done

- A changed disk is not handed out by Export Save Data.
- Chimera's window on Windows not tried (only its headless runner).
- Not published: a repository, CI, the roster and the README rows are the
  owner's to decide.
