# Building

This core is built on Linux. The result, `core.wbx`, is one file that runs in
Chimera on Linux and on Windows.

## What is needed

- GCC 13 or newer, GNU make, Python 3, git.
- A checkout of Chimera with miniBox built, for the sandbox toolchain
  (Chimera's `AGENTS.md`, "Build").
- About 2 GB of disk.

## MAME's source

MAME is a git submodule at `extern/mame`, pinned to one commit.

```sh
waterbox/checkout-mame.sh
```

checks out the part of MAME this core builds (`waterbox/mame-sparse.txt`):
everything except the software lists (one hash file, `intv.hsi`, is kept),
the desktop renderer, the artwork and the manual. `git submodule update
--init extern/mame` gets the whole tree and works as well.

MAME is never edited in place. A change to it is a numbered patch in
`patches/`, applied by `waterbox/apply-patches.sh`, which the build runs.

## The machines

`waterbox/drivers.txt` lists the seven driver files built. MAME's own build
takes that list and works out which processors, chips and devices they need;
they declare 67 machines. `waterbox/machines.txt` says which of them the
package offers, and the system each one is.

## The two flavors

MAME is built twice:

- `native`: for the host. `run-native` is the reference the tests compare
  the sandbox with.
- `guest`: for miniBox's sandbox. This is `core.wbx`, and `run-wbx` runs it.

```sh
waterbox/build-core.sh native             # build/native/run-native
waterbox/build-core.sh guest              # waterbox/bin/core.wbx and run-wbx
waterbox/build-package.sh -r <chimera>    # the guest and the package
```

Each takes about 5 minutes on 14 processors. `-m <miniBox folder>` (or
`MINIBOX_DIR`) says where miniBox is when it is not in
`~/chimera/extern/chimera-common-minibox`; keep it the same for every build.

`build-core.sh` builds MAME's libraries first when they are missing or when
what they were built from has changed (`build-mame.sh`), then compiles this
core's own files with exactly the flags MAME compiled its own with
(`mame-flags.sh`), and links.

## Running a machine by hand

A work folder holds what the sandbox would see: the firmware under MAME's
names for it, the game, a `settings` file (`{"machine":"intv"}`) and a
`slots` file (`{"game":["astrosmash.int"]}`). Then:

```sh
build/native/run-native <folder> --frames 600 --report 100 --list-panel
waterbox/bin/run-wbx waterbox/bin/core.wbx <folder> --frames 600 --report 100
```

The run options are in `waterbox/gate-harness.h`. `tests/make-cpr.py` writes
a GX4000 cartridge that needs no firmware.

## The tests

```sh
CHIMERA_ROOT=<chimera> waterbox/run-gate.sh
```

builds both flavors and the package if needed and runs every test: the
package against MAME's database, the GX4000 test cartridge, and each machine
whose folder is in `tests/roms-local` (`intv`, `channelf`, `vectrex`). A
machine whose folder is absent is reported as skipped.

## The package

The machines' controls, settings and firmware are generated, not written:

```sh
build/native/run-native <any folder> --walk > walk.txt
waterbox/gen-config.py walk.txt
```

writes `waterbox/waterbox.config` and `waterbox/default_keybinds.json`. Do
this again when the MAME commit or `machines.txt` changes; the test script
fails if the two files are not what the walk gives.
