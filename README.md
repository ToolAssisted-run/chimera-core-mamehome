# chimera-core-mamehome

Seven home systems of [MAME](https://github.com/mamedev/mame) as one
[Chimera](https://github.com/ToolAssisted-run/chimera) core, running in
miniBox's sandbox: the Atari 7800, the Intellivision, the Vectrex, the
Odyssey 2 (and Videopac), the Channel F, the Amstrad CPC (with the CPC+ and
the GX4000) and the TI-83.

MAME is not forked: `extern/mame` is upstream at a pinned commit, built with
MAME's own build system for seven driver files (`waterbox/drivers.txt`),
with a few small patches in `patches/`. Of that build only the libraries are
used. MAME's own frontend and its SDL layer are replaced by `waterbox/`: no
menus, no Lua, no threads, no host clock, no files written. A Chimera frame
is one turn of MAME's own machine loop, from one vertical blank of the
screen to the next.

## Machines

The Machine setting picks one, by MAME's name for it. The project keeps it
and the movie records it.

| System | Machines |
|---|---|
| Atari 7800 | `a7800` (NTSC), `a7800p` (PAL) |
| Intellivision | `intv`, `intv2`, `intvsrs` (Sears), `intvoice` (with IntelliVoice), `intvecs` (with the ECS and IntelliVoice) |
| Vectrex | `vectrex` |
| Odyssey 2 | `odyssey2`, `videopac`, `videopacf` (C52), `videopacp` (G7400), `jopac` |
| Channel F | `channelf`, `channlf2` |
| Amstrad CPC | `cpc464`, `cpc664`, `cpc6128` and its French, Swedish and Spanish models, `cpc464p`, `cpc6128p`, `gx4000` |
| TI-83 | `ti83` (OS 1.08 by default; the BIOS setting chooses another) |

## What a project needs

- **The game**: a cartridge, or for a CPC a disk (`.dsk`), a tape (`.cdt`,
  `.wav`) or a snapshot (`.sna`). Each file goes into the first of the
  machine's slots or drives that takes its kind, so a second disk goes into
  the second drive. The Vectrex and the Channel F also start with no
  cartridge (Mine Storm, and the Channel F's built-in games). For the TI-83,
  a program or group file (`.83p`, `.83g`): the core sends it over the link
  cable three seconds after power-on, as TI's link software does, and again
  until the calculator takes it, so the movie only has to switch the
  calculator on (ON) and run the program (PRGM, ENTER, ENTER).
- **Firmware**: the machine's own ROMs, with the contents MAME expects. The
  Firmware page asks for the ones the chosen machine needs, and the core
  checks each before the machine is built. The GX4000, the CPC464+ and the
  CPC6128+ need none. The Odyssey 2's character ROM (`charset_i8244.bin`) is
  a chip's own ROM that MAME keeps as a file: it is asked for too.
- **Save data** (optional): the files Export Save Data wrote.

The package carries no ROM.

## Controls

Each machine has its own controls, named after MAME's: `P1 Up`,
`P1 Button 1`, and the driver's own names where it has them (`P1 Push Down`
on the Channel F, `P1 Upper` and the keypad's `P1 1` to `P1 Enter` on the
Intellivision, `Reset`, `Select` and `Pause` on the 7800, every key of a
CPC's keyboard). Where one machine has two of the same controller (the
Intellivision's hand controllers), the left one is P1.

An analog control (the Vectrex's sticks, the Intellivision's disc in analog
mode) is an axis: 0 is where it rests, and it goes as far each way as the
machine's control does. A mouse or a trackball takes the value as its
movement this frame.

Lag frames are counted: a frame in which the machine read none of its
controls.

## Settings

Besides the machine: its BIOS where MAME has more than one, and each switch
and set-up choice of the machine at MAME's default (the 7800's difficulty
switches, the Intellivision's disc as sixteen buttons or two axes, the
Vectrex's 3D Imager, a CPC's monitor and joystick port). They are part of
the machine: a movie needs the same values.

## Memory

- Each processor's address space is a bus (`maincpu` first).
- Each named block of the machine's memory, the RAM a processor's memory map
  declares, and the arrays a driver keeps its RAM in (the Intellivision's)
  are memory domains under MAME's names.

## Not there yet

- A CPC disk is not swapped while the machine runs.
- Only the GX4000 is tested on CI; the others are tested where their
  firmware is.

## Using it in Chimera

Chimera ships no cores and downloads nothing. Put the `.chimeraCore` package
in the `Cores` folder beside `Chimera.exe`; File > Core Manager lists it. The
same file works on Linux and on Windows.

## Building

[docs/BUILDING.md](docs/BUILDING.md) has the instructions,
[docs/PLAN.md](docs/PLAN.md) what was decided and measured, and
[AGENTS.md](AGENTS.md) is the guide for an AI coding agent. In short:

```sh
waterbox/checkout-mame.sh                       # MAME at the pinned commit
waterbox/build-core.sh native                   # the reference
waterbox/build-package.sh -r <chimera>          # core.wbx and the package
CHIMERA_ROOT=<chimera> waterbox/run-gate.sh     # the tests
```

## Licence

The integration in this repository is MIT. MAME as a whole is GPL-2.0 or
later, and the package is distributed under it; `waterbox/package-licenses.json`
lists every component and its terms.
