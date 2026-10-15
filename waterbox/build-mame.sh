#!/bin/sh
# Builds the parts of MAME this core links, with MAME's own build system, for
# one flavor: native (the host compiler: the reference) or guest (miniBox's
# musl toolchain: what goes into core.wbx).
#
# THE EMULATOR IS UPSTREAM MAME, built the way MAME builds a chosen set of
# machines: waterbox/drivers.txt lists the driver files, MAME takes that list
# as its SOURCEFILTER, and its makedep works out every processor, chip, device
# and file format those files need.
# Of the projects that generates, only the libraries are built. MAME's
# frontend (its menus, Lua, plugins), its OSD layer (SDL, OpenGL, the audio
# and input back ends) and the executable are not: waterbox/ is this core's
# frontend and OSD.
#
# Usage: waterbox/build-mame.sh native|guest [-m <miniBox dir>] [-j N]
# Output: build/mame-<flavor>/linux_gcc/bin/x64/Release/*.a and the
# generated sources under build/mame-<flavor>/generated.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
flavor="${1:?native or guest}"; shift
mb="${MINIBOX_DIR:-$HOME/chimera/extern/chimera-common-minibox}"
jobs="$(nproc)"
while getopts "m:j:" opt; do
	case "$opt" in
		m) mb="$OPTARG" ;;
		j) jobs="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

mame="$root/extern/mame"
name="mame-$flavor"
sub="home"
builddir="$root/build/$name"
mkdir -p "$builddir"

sh "$here/apply-patches.sh"

# the driver files, written only when the list changes (MAME regenerates its
# projects when the filter is newer than they are)
flt="$builddir/$sub.flt"
grep -v -e '^#' -e '^$' "$here/drivers.txt" > "$flt.new"
if [ -f "$flt" ] && cmp -s "$flt" "$flt.new"; then rm -f "$flt.new"; else mv "$flt.new" "$flt"; fi
echo "driver files: $(wc -l < "$flt")"

# MAME's genie takes BUILDDIR and SOURCEFILTER as paths relative to the MAME
# tree (an absolute one is appended to it), so they are given that way.
# FORCE_DRC_C_BACKEND: a processor MAME recompiles runs on its portable back
# end in both flavors, so the reference and the sandbox run the same code.
params="SUBTARGET=$sub SOURCEFILTER=../../build/$name/$sub.flt BUILDDIR=../../build/$name
	NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 NO_USE_MIDI=1
	NO_OPENGL=1 USE_QTDEBUG=0 NOWERROR=1 PYTHON_EXECUTABLE=python3
	FORCE_DRC_C_BACKEND=1 SYMBOLS=0"
# Every MAME object is built with these: CHIMERA_CORE switches on this core's
# patches; SOUND_DISABLE_THREADING runs the sound manager's output stage inline
# instead of on a thread of its own, whose timing is the host's (a thread woken
# by a condition variable decides which frame a sample lands in) and which the
# sandbox's scheduler cannot run the same way.
archopts="ARCHOPTS=-DCHIMERA_CORE -DSOUND_DISABLE_THREADING"

case "$flavor" in
	native) ;;
	guest)
		sr="$mb/build/meson-cpp/guest-sysroot"
		[ -f "$sr/lib/musl-gcc.specs" ] || {
			echo "miniBox guest sysroot not found at $sr: build it (meson setup $mb/build/meson-cpp $mb -Dguest_cpp=true && ninja -C $mb/build/meson-cpp)" >&2
			exit 1
		}
		gccver="$(gcc -dumpfullversion)"
		# the flags every guest object in this project is built with (see
		# chimera-cores/azahar/waterbox/guest-toolchain.cmake for each one's reason)
		wb="-I$here/guest-shim -specs=$sr/lib/musl-gcc.specs -fvisibility=hidden -mcmodel=large -mstack-protector-guard=global -fno-stack-protector -fno-pic -fno-pie -fcf-protection=none"
		wbxx="$wb -nostdinc++ -I$sr/include/c++/$gccver -I$sr/include/c++/$gccver/x86_64-linux-musl"
		params="$params TARGETOS=linux PTR64=1 NOASM=1"
		export OVERRIDE_CC="gcc $wb"
		export OVERRIDE_CXX="g++ $wbxx"
		;;
	*) echo "flavor is native or guest" >&2; exit 2 ;;
esac

cd "$mame"
# generate the projects (and the genie tool, once), then build the libraries
# shellcheck disable=SC2086
projdir="$(make $params "$archopts" -s -p -n generate 2>/dev/null | sed -n 's/^PROJECTDIR := //p' | head -1)"
# Always regenerated: MAME remakes its projects when its own scripts change,
# not when the flags given here do, and a flag that never reaches the
# makefiles is an object built the old way that nothing reports.
rm -f "$projdir/gmake-linux/Makefile"
# shellcheck disable=SC2086
make $params "$archopts" generate "$projdir/gmake-linux/Makefile"
# every library project MAME generated; not its frontend, its OSD's SDL half
# or the executable
libs="$(sed -n 's/^PROJECTS := //p' "$projdir/gmake-linux/Makefile" | tr ' ' '\n' \
	| grep -v -x -e "$sub" -e "mame$sub" -e frontend -e osd_sdl -e qtdbg_sdl -e precompile \
		-e lualibs -e lua -e linenoise -e sqlite3 -e bgfx -e bimg -e bx | tr '\n' ' ')"
echo "libraries: $libs"
make -C "$projdir/gmake-linux" config=release64 -j"$jobs" precompile
# shellcheck disable=SC2086
make -C "$projdir/gmake-linux" config=release64 -j"$jobs" $libs

# The driver list: the machines this core runs (makedep's own list, as
# MAME's executable would compile it).
gen="$builddir/generated/mame/$sub"
mkdir -p "$gen"
python3 scripts/build/makedep.py -r "$mame/" driverlist src/mame/mame.lst -f "$flt" > "$gen/drivlist.cpp"
echo "built: $builddir/linux_gcc/bin/x64/Release"
