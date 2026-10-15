#!/bin/sh
# Builds this core for one flavor, from the MAME libraries build-mame.sh made:
#
#   native: build/native/run-native (the reference the tests compare with:
#           the exports and the driver linked for the host)
#   guest:  waterbox/bin/core.wbx (the exports and the driver in miniBox's
#           sandbox) and waterbox/bin/run-wbx (the host that runs it)
#
# Every object here is compiled with exactly the flags MAME's own build gave
# a driver file (mame-flags.sh), so this code and the MAME code it includes
# can never disagree about a define or a header.
#
# Usage: waterbox/build-core.sh native|guest [-m <miniBox dir>] [-j N]
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
tail=""
sub="home"
mb="$(cd "$mb" && pwd)"
mame="$root/extern/mame"
mdir="$root/build/mame-$flavor$tail"
lib="$mdir/linux_gcc/bin/x64/Release"
# MAME's libraries. Rebuilt from nothing whenever what decides HOW they are
# compiled changes - build-mame.sh's flags, the compiler, and for the guest the
# toolchain - because a flag change rebuilds nothing in MAME's makefiles, and
# an object built the old way reports nothing either. Rebuilt by make, which
# compiles only what changed, whenever WHAT is compiled changes: the pinned
# commit, the patch series, the list of driver files.
how="$( {
	cat "$here/build-mame.sh"
	gcc -dumpfullversion
	[ "$flavor" = guest ] && cat "$mb/build/meson-cpp/guest-sysroot/lib/musl-gcc.specs"
} 2>/dev/null | sha1sum | cut -c1-40)"
what="$( {
	git -C "$root" ls-files -s extern/mame
	cat "$here/drivers.txt" "$root"/patches/*.patch
} 2>/dev/null | sha1sum | cut -c1-40)"
stamp="$mdir/chimera-inputs"
if [ -f "$stamp" ] && [ "$(sed -n 1p "$stamp")" != "$how" ]; then
	echo "MAME's $flavor flags or toolchain changed: rebuilding it from nothing"
	rm -rf "$mdir"
fi
if [ ! -f "$lib/libemu.a" ] || [ "$(sed -n 2p "$stamp" 2>/dev/null)" != "$what" ]; then
	sh "$here/build-mame.sh" "$flavor" -m "$mb" -j "$jobs"
	printf '%s\n%s\n' "$how" "$what" > "$stamp"
fi
obj="$root/build/$flavor$tail"
mkdir -p "$obj"

cxxcmd="$(sh "$here/mame-flags.sh" "$flavor")"
# shellcheck disable=SC2086
eval set -- $cxxcmd
cxx="$1"; shift
cxxflags="$*"

case "$flavor" in
	native)
		cc="gcc"
		cflags="-O2"
		shim="-I$here/native-shim"
		;;
	guest)
		sr="$mb/build/meson-cpp/guest-sysroot"
		cc="gcc -specs=$sr/lib/musl-gcc.specs -fvisibility=hidden -mcmodel=large -fno-stack-protector -fno-pic -fno-pie -fcf-protection=none"
		cflags="-O2"
		shim="-I$mb/extern/emulibc"
		;;
esac
guestinc="-I$mb/source/guest/include -I$mb/extern/jsmn"

compile_cxx() { # <source> <object> [extra flags]  (sh has no locals: cc_* names only)
	cc_src="$1"; cc_obj="$2"; shift 2
	# shellcheck disable=SC2086
	eval "$cxx" $cxxflags -I"$here" -I"$mame/src" -Wno-suggest-override "$@" -c "$cc_src" -o "$cc_obj"
}

# the hash files MAME reads for a cartridge with no header (intv.hsi: how an
# Intellivision .bin is laid out), carried in the core as text (patch 0007)
python3 - "$mame/hash" > "$obj/hash-files.inc.new" <<'PY'
import glob, os, sys
print("// written by build-core.sh from MAME's hash folder")
print("static const struct { const char *system, *text; } kHashFiles[] = {")
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.hsi"))):
    text = open(path, encoding="utf-8").read()
    print('\t{ "%s", R"chimera(%s)chimera" },' % (os.path.basename(path)[:-4], text))
print("\t{ nullptr, nullptr } };")
PY
if cmp -s "$obj/hash-files.inc" "$obj/hash-files.inc.new"; then rm -f "$obj/hash-files.inc.new"; else mv "$obj/hash-files.inc.new" "$obj/hash-files.inc"; fi

objs=""
# MAME's OSD interface pieces the emulator core calls (input sequences, the
# network handler base, audio info) - the rest of MAME's OSD layer is not used
for part in inputseq nethandler audio; do
	compile_cxx "$mame/src/osd/interface/$part.cpp" "$obj/osd-$part.o"
	objs="$objs $obj/osd-$part.o"
done
compile_cxx "$mdir/generated/mame/$sub/drivlist.cpp" "$obj/drivlist.o"
# MAME's own check of a machine's files (its frontend's, the one file of it
# this core uses)
compile_cxx "$mame/src/frontend/mame/audit.cpp" "$obj/audit.o" -I"$mame/src/frontend/mame"
compile_cxx "$here/mame-driver.cpp" "$obj/mame-driver.o" -I"$mame/src/emu" -I"$obj"
compile_cxx "$here/emulator-info.cpp" "$obj/emulator-info.o"
compile_cxx "$here/wbx-entry.cpp" "$obj/wbx-entry.o" $shim $guestinc
# MAME runs on a libco cothread, and that stack must come from mmap with
# MAP_STACK rather than malloc: miniBox tracks writes by protecting pages, and on
# Windows a fault on the page the stack pointer is in cannot be delivered at all
# unless the sandbox was told the page is a stack (miniBox memblock.c). Out of
# malloc, the process died on its first frame with 0xC0000005 and no word -
# mame_main's stack probe was the first write.
# shellcheck disable=SC2086
eval $cc $cflags -DCO_MMAP_STACKS=1 -c "$here/libco/libco.c" -o "$obj/libco.o"
objs="$objs $obj/drivlist.o $obj/audit.o $obj/mame-driver.o $obj/emulator-info.o $obj/libco.o"

# every library build-mame.sh made: the machines (one library a maker), the
# devices, the emulator and the third-party code
libs="$(ls "$lib"/mame_$sub/*.a "$lib"/*.a | grep -v -e /libfrontend.a -e /libqtdbg_sdl.a -e /libprecompile.a | tr '\n' ' ')"

case "$flavor" in
	native)
		gcc -O2 -I"$here" -I"$here/native-shim" -c "$here/run-native.c" -o "$obj/run-native.o"
		# shellcheck disable=SC2086
		g++ -o "$obj/run-native" $objs "$obj/wbx-entry.o" "$obj/run-native.o" \
			-Wl,--start-group $libs -Wl,--end-group -lpthread -ldl -lutil
		echo "built $obj/run-native"
		;;
	guest)
		mbuild="$mb/build/meson-cpp"
		compile_cxx "$here/guest-syscalls.cpp" "$obj/guest-syscalls.o"
		if [ -n "$tail" ]; then bin="$obj"; else bin="$here/bin"; fi
		mkdir -p "$bin"
		# shellcheck disable=SC2086
		g++ -specs "$sr/lib/musl-gcc.specs" -mcmodel=large -fno-pic -fno-pie \
			-static -no-pie -Wl,--eh-frame-hdr,-O2,--no-relax,-z,stack-size=8388608 -T "$mb/source/guest/linkscript.T" \
			-Wl,-u,pthread_once -Wl,-u,pthread_cond_wait -Wl,-u,pthread_cond_broadcast -Wl,-u,pthread_key_create \
			-o "$bin/core.wbx" $objs "$obj/wbx-entry.o" "$obj/guest-syscalls.o" \
			"$mbuild/source/guest/cxxglue.c.o" "$mbuild/source/guest/emulibc.c.o" \
			-Wl,--start-group $libs -Wl,--end-group \
			-L"$sr/lib" -lstdc++ -lgcc -lgcc_eh -lc
		sh "$mb/source/guest/check-wbx.sh" "$bin/core.wbx"
		mbhost="$mb/build/meson-linux/source/host"
		gcc -O2 -Wall -I"$mb/source/host" -I"$here" -o "$bin/run-wbx" "$here/run-wbx.c" \
			"$mbhost/libminiboxhost.so" -Wl,-rpath,"$mbhost"
		echo "built $bin/core.wbx $bin/run-wbx"
		;;
esac
