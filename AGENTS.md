# AGENTS.md - MAME home systems core for Chimera

This repository builds eight home systems of MAME (Atari 7800, Intellivision,
Vectrex, Odyssey 2, Channel F, Amstrad CPC, TI-83, BBC Micro) as one sandboxed guest for
Chimera (https://github.com/ToolAssisted-run/chimera), a frontend for
tool-assisted speedruns. MAME is not forked: its own build system builds its
libraries for ten driver files, and `waterbox/` replaces its frontend and
SDL layer. The result is one file, `mamehome.chimeraCore`: the guest binary
`core.wbx` plus the declarations Chimera reads. `docs/BUILDING.md` has the
detail behind every command here, and `docs/PLAN.md` what was decided, what
was measured and what is not done. The arcade core
(`chimera-core-mame`) is the same frontend shaped for arcade machines.

## Layout

- `extern/mame/` - upstream MAME at a pinned commit (submodule). Never commit
  in it.
- `patches/` - numbered patches against `extern/mame`.
- `waterbox/checkout-mame.sh`, `mame-sparse.txt` - the part of MAME that is
  checked out.
- `waterbox/apply-patches.sh` - applies the patches to the MAME tree.
- `waterbox/drivers.txt` - the driver files MAME is asked to build.
- `waterbox/machines.txt` - the machines the package offers, and the system
  each one is.
- `waterbox/build-mame.sh` - MAME's libraries, `native` or `guest`.
- `waterbox/build-core.sh` - this repository's code linked against them.
  `mame-flags.sh` reads the flags MAME compiled a driver with.
- `waterbox/build-package.sh` - builds the guest and writes the package.
- `waterbox/mame-driver.cpp`, `mame-driver.h` - the frontend: the machine,
  its files, the picture, the sound, the controls, the firmware check, save
  data, memory, and the walk over every machine.
- `waterbox/wbx-entry.cpp` - the exports Chimera calls.
- `waterbox/run-native.c`, `run-wbx.c`, `gate-harness.h` - the native
  reference, the sandbox runner, and the options both take.
- `waterbox/gen-config.py` - GENERATES `waterbox.config` and
  `default_keybinds.json` (both committed) from the walk, with
  `waterbox.template.json` for what every machine shares.
- `waterbox/run-gate.sh` - the test script. `tests/make-cpr.py`,
  `make-a78.py`, `make-o2.py`, `make-83p.py`, `make-dsk.py` - the test
  cartridges, the TI-83 test program and the CPC test disks;
  `type-keys.py` types text on a CPC's keyboard. `tests/run-frontend.sh` - the window test.
- `waterbox/libco/` - ares's libco. `guest-shim/`, `native-shim/` - headers.
- `waterbox/bin/`, `build/` - build output (ignored by git).
- `tests/roms-local/` - a folder per machine with its firmware and a game,
  for the tests (ignored by git).

## Build and test

```sh
export MINIBOX_DIR=<chimera>/extern/chimera-common-minibox   # always the same one
waterbox/checkout-mame.sh
waterbox/build-core.sh native && waterbox/build-core.sh guest
CHIMERA_ROOT=<chimera> waterbox/run-gate.sh
```

Run the test script before every commit that touches what it covers, and say
in the commit what ran, with the numbers. Chimera's own package checks need
`dotnet` on the PATH.

## Rules

- **Never commit inside `extern/mame`.** A change to MAME is a numbered patch
  in `patches/` (paths relative to `extern/mame`, the form `git apply`
  takes), with its code under the `CHIMERA_CORE` define and a comment that
  says why. `waterbox/apply-patches.sh` must then print
  `already applied: all <n> patches`.
- **Keep `MINIBOX_DIR` the same for every build.** The path of miniBox's
  toolchain is part of what decides whether MAME's sandbox build is still
  valid; another path rebuilds it from nothing.
- **Never edit a build script while it runs.** `sh` reads a script as it goes.
- **The package is generated.** After a change to the MAME commit, to
  `machines.txt` or to how controls are named, run
  `build/native/run-native <any folder> --walk > walk.txt` and
  `waterbox/gen-config.py walk.txt`. Do not edit `waterbox.config` or
  `default_keybinds.json` by hand; the test script compares them with what
  the walk gives.
- **Nothing depends on the host.** No clock, no thread, no file written, no
  input device. A machine must run the same in the native reference, in the
  sandbox, and after a savestate is loaded; the test script checks all three
  for every machine it has.
- **No ROM, BIOS or game is committed**, uploaded to CI or attached to an
  issue. Firmware for the tests goes in `tests/roms-local`, copied, never
  linked.
- **A test is seen to fail once.** A new test is broken on purpose and seen
  to fail before it is trusted, and a "the same" comparison has a run beside
  it that must come out different.
- **Write in plain language**, in commits, documents and comments: say what
  changed in ordinary words, and explain a term the first time it is used.
  Prose files are ASCII.
- **Commits**: `type(scope): what changed`, a short body with what changed,
  why and how it was tested. Stage paths by name.
- **Publishing, and anything that changes what Chimera is, is the owner's to
  decide.**

## Traps already met

- `ioport_field::type_class()` and `name()` need a running machine. The
  controls' names come from MAME's list of kinds (`inpttype.ipp`), which
  needs none, so the walk and the running core name them the same way.
- One controller device used twice (the Intellivision's two hand
  controllers) gives two fields of one kind and one player. The core gives
  each device a player of its own when names collide.
- MAME names a later player's analog kinds with the player at the end
  ("P2 AD Stick X 2"); only an analog name loses it, or "P2 Button 2" becomes
  "P2 Button".
- Some keyboards name keys by symbols (arrows, a pound sign). The core spells
  them out in ASCII; a symbol it does not know becomes "?", which
  gen-config.py refuses.
- A machine whose RAM is in a driver's own arrays (the Intellivision) has no
  memory share: the arrays registered for MAME's savestates are memory
  domains, the sound streams' buffers left out.
- An Intellivision `.bin` cartridge is laid out by MAME's `intv.hsi`, which
  the core carries as text (patch 0007): the sandbox has no hash folder.
- On a GX4000 nothing sets up the video chip at power-on: a cartridge that
  does not program the CRTC never sees a vertical sync.
- A control released at frame N is seen by the machine a frame or two later:
  a test that reads the machine's memory at the end of a run holds the
  control to the end.
- MAME catches what is thrown while it starts a machine and carries on. A
  reason not to start is put in `s_refused`, and `mame_init` answers with it.
- The TI-83's link sender (patch 0008) needs patch 0010: MAME's TI-83 port
  read did not show the calculator's own pull-down, and every bit waited for
  the calculator's 0.64-second timeout. A reply waits 5 ms after the
  calculator's last bit, or it drops the transfer.
- A patch that adds files is regenerated with `diff -uN` per file; a shell
  script with `set -e` stops at the first `diff`, which exits 1 when files
  differ, and leaves a patch with only its first file.
- A disk control does its swap at the start of the next frame, inside
  MAME's turn (chimera_osd::update), never from the host's stack.
- MAME clears a disk's "changed" flag when its motor stops, even for a
  format it cannot write: patch 0012 keeps every disk taken out.
- MAME reads every port once a frame for itself. Patch 0005 leaves those
  reads out, or no frame would ever count as a lag frame.
