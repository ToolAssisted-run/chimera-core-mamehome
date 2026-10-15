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

`waterbox/machines.txt`: 24 machines of the 67 the seven driver files
declare. Left out: prototypes and clones that add nothing (the Odyssey 3, the
Channel F's other licensed models), the KC Compact and the Aleste, and the
TI calculators (see "Not done").

## Measured (2026-10-15)

- MAME's libraries: about 5 minutes a flavor on 14 processors. `core.wbx` is
  67 MB.
- The test script: 36 passed, 0 failed, 0 skipped, with the local folders.
  - The package is what the walk gives (24 machines, 18 settings, 30
    firmware files), and Chimera's own package checks pass (18).
  - The GX4000, on a cartridge the test writes (`tests/make-cpr.py`): it
    runs and counts its frames; each of the 12 joystick controls clears its
    own bit of the keyboard matrix, the CPC's wiring (joystick 1 row 9,
    joystick 2 row 6, bits 0 to 5); no lag frame when it reads the
    joysticks, every frame a lag frame when it reads nothing.
  - For the GX4000, the Intellivision (Astrosmash), the Channel F (its
    built-in games) and the Vectrex (Mine Storm): the sandbox gives the
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

- Intellivision: the Executive ROM and the GROM match MAME's.
- Channel F: all three of MAME's files match.
- Vectrex: BizHawk's `VEC_Minestorm.vec` is MAME's `exec_rom.bin` (the 8 KB
  ROM with Mine Storm). BizHawk's 4 KB BIOS file is its second half.
- Odyssey 2: the BIOS files match, but MAME also needs the 8244 video chip's
  character ROM (`charset_i8244.bin`), which BizHawk keeps in its code.
- Atari 7800: no BIOS. MAME needs it for the NTSC machine.
- Amstrad CPC: no ROMs (the GX4000 and the CPC+ machines need none).

## Not done

- **TI-83**: MAME emulates the calculator but has no way to send a program
  to it from a file (BizHawk does it through its link cable). It needs a
  link device of our own that sends a `.83p` file.
- A CPC disk is not swapped while the machine runs (Previous/Next Disk).
- Chimera's window on Windows not tried (only its headless runner).
- Not published: a repository, CI, the roster and the README rows are the
  owner's to decide.
