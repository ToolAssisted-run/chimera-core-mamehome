#!/bin/sh
# The MAME home systems core's test script.
#
# Written against chimera's docs/gates.md, and the ways a test script has
# already been watched to pass on a broken thing:
#
#   * a DEAD machine finishes at once and every digest agrees with itself, so
#     the machine tests first check that the machine got somewhere;
#   * a digest of the END misses a machine that ran differently and arrived
#     at the same place, so the reference and the sandbox are compared as a
#     STREAM of digests, one every 50 frames;
#   * a comparison that cannot fail proves nothing, so every "the same" has a
#     run beside it that must come out DIFFERENT through the same comparison;
#   * a sandbox build that failed was once packaged as the previous binary,
#     so the package test checks core.wbx is newer than its sources.
#
# The GX4000 has no ROM of its own, so the tests that use it run anywhere, CI
# included, on a cartridge tests/make-cpr.py writes. The other machines need
# their firmware, which cannot be distributed: put a folder per machine in
# tests/roms-local (intv, channelf, vectrex: the firmware under MAME's names,
# a game, and the "settings" and "slots" files), or point HOME_ROMS at such a
# folder. Each of those tests says SKIP when its folder is absent.
#
# Usage: waterbox/run-gate.sh [-r <chimera root>] [-m <miniBox dir>]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
chimera_root="${CHIMERA_ROOT:-$HOME/chimera}"
mb="${MINIBOX_DIR:-}"
roms="${HOME_ROMS:-$root/tests/roms-local}"
while getopts "r:m:" opt; do
	case "$opt" in
		r) chimera_root="$OPTARG" ;;
		m) mb="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
[ -n "$mb" ] || mb="$chimera_root/extern/chimera-common-minibox"

work="$root/build/gate"
rm -rf "$work"; mkdir -p "$work"
native="$root/build/native/run-native"
wbxrun="$here/bin/run-wbx"
core="$here/bin/core.wbx"
run="$chimera_root/build/meson-linux/chimera-run"
pkg="$root/build/package/mamehome.chimeraCore"
config="$here/waterbox.config"

pass=0; fail=0; skip=0
report() {
	case "$1" in
		PASS) pass=$((pass+1)) ;;
		FAIL) fail=$((fail+1)) ;;
		SKIP) skip=$((skip+1)) ;;
	esac
	printf '%-5s %-62s %s\n' "$1" "$2" "${3:-}"
}
finish() {
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	[ "$pass" -eq 0 ] && { echo "NOTHING RAN"; exit 1; }
	[ "$fail" -eq 0 ] || exit 1
	exit 0
}
# check <label> <detail> <condition...>: PASS or FAIL on a shell condition
check() {
	ck_label="$1"; ck_detail="$2"; shift 2
	if "$@"; then report PASS "$ck_label" "$ck_detail"; else report FAIL "$ck_label" "$ck_detail"; fi
}
stream() { awk '/^frame/' "$1"; }
same() { [ -s "$1" ] && [ -s "$2" ] && cmp -s "$1" "$2"; }
differ() { [ -s "$1" ] && [ -s "$2" ] && ! cmp -s "$1" "$2"; }
# index <panel listing> <control name>: a control's place on the panel
index() { awk -v n="'$2'" 'index($0, n) && $1=="panel" {print $2; exit}' "$1"; }
# copy_folder <from> <name> [settings json]: a work folder as the sandbox
# mounts a project - the files under their names, and "settings" replaced
copy_folder() {
	mkdir -p "$work/$2"
	cp "$1"/* "$work/$2/"
	[ -z "${3:-}" ] || printf '%s' "$3" > "$work/$2/settings"
}

# ---------------------------------------------------------------- 1. build
if sh "$here/build-core.sh" native -m "$mb" > "$work/native.log" 2>&1; then
	report PASS "the native reference builds"
else
	report FAIL "the native reference builds" "see $work/native.log"
fi
if sh "$here/build-package.sh" -m "$mb" -o "$(dirname "$pkg")" > "$work/package.log" 2>&1; then
	report PASS "the package builds" "$(grep -o 'sha1 [0-9a-f]*' "$work/package.log") $(du -h "$pkg" | cut -f1)"
else
	report FAIL "the package builds" "see $work/package.log"
fi
stale=""
for src in "$here"/mame-driver.cpp "$here"/wbx-entry.cpp "$here"/emulator-info.cpp "$here"/drivers.txt "$root"/patches/*.patch; do
	[ "$core" -nt "$src" ] || stale="$stale $(basename "$src")"
done
if [ -f "$core" ] && [ -z "$stale" ]; then
	report PASS "core.wbx is not older than its sources" "$(du -h "$core" | cut -f1)"
else
	report FAIL "core.wbx is not older than its sources" "older than:$stale"
fi

# MAME runs on a stack of its own, and to the sandbox that must be a stack:
# mapped with MAP_STACK, not taken from malloc. On Windows miniBox cannot
# deliver a fault on a page the stack pointer is in unless it was told the
# page is a stack, and a core built the other way dies on its first frame
# there. Linux runs both, so this is where it can be seen.
if nm "$root/build/guest/libco.o" 2>/dev/null | grep -q ' U mmap$' \
	&& ! nm "$root/build/guest/libco.o" 2>/dev/null | grep -q ' U malloc$'; then
	report PASS "MAME's stack is a MAP_STACK mapping" "what Windows needs to run it"
else
	report FAIL "MAME's stack is a MAP_STACK mapping" "libco.o takes it from malloc: the core dies on Windows"
fi

# The package is what MAME says: a walk over every machine of the build gives
# the same two files gen-config.py wrote.
"$native" "$work" --walk > "$work/walk.txt" 2> "$work/walk.err" || true
mkdir -p "$work/gen"
if python3 "$here/gen-config.py" "$work/walk.txt" "$work/gen" > "$work/gen.log" 2>&1 \
	&& same "$work/gen/waterbox.config" "$config" && same "$work/gen/default_keybinds.json" "$here/default_keybinds.json"; then
	report PASS "the committed package is what MAME's database gives" "$(cat "$work/gen.log")"
else
	report FAIL "the committed package is what MAME's database gives" "run gen-config.py on $work/walk.txt ($(tail -1 "$work/gen.log"))"
fi
python3 - "$config" "$here/default_keybinds.json" "$here/file_slots.json" > "$work/decl.log" 2>&1 <<'PY' && ok=1 || ok=0
import json, sys
cfg = json.load(open(sys.argv[1])); kb = json.load(open(sys.argv[2])); slots = json.load(open(sys.argv[3]))
assert cfg["romFile"] == "game" and [s["id"] for s in slots["slots"]] == ["game", "savedata"]
machines = cfg["settings"][0]["options"]
assert cfg["settings"][0]["name"] == cfg["machineSetting"] == "machine"
assert sorted(m["when"][0] for m in cfg["machines"]) == sorted(machines), "a machine with no entry, or an entry with no machine"
for m in cfg["machines"]:
    b = m["input"]["buttons"]
    assert len(b) == len(set(b)), m["label"] + ": a control is declared twice"
    assert set(kb["AllTrollers"][m["input"]["name"]]) == set(b), m["label"] + ": the key bindings are not its controls"
# every machine is left with one declaration of each setting
for name in machines:
    seen = [s["name"] for s in cfg["settings"][1:] if name in s["when"]]
    assert len(seen) == len(set(seen)), name + ": two declarations of one setting"
print("%d machines, %d settings, %d firmware files" % (len(machines), len(cfg["settings"]), len(cfg["firmware"])))
PY
if [ "$ok" = 1 ]; then
	report PASS "the declarations hold together" "$(cat "$work/decl.log")"
else
	report FAIL "the declarations hold together" "$(tail -1 "$work/decl.log")"
fi
# the machine entry the package declares is the core's, in the sandbox: its
# controls in the same order
# declared <machine>: that machine's controls in the package, one a line
declared() { python3 -c "
import json, sys
for m in json.load(open(sys.argv[1]))['machines']:
    if m['when'] == [sys.argv[2]]:
        print('\n'.join(m['input']['buttons']))" "$config" "$1"; }
reported() { sed -n "s/^panel [0-9]* '\(.*\)'.*/\1/p" "$1"; }

# ------------------------------------- 2. the GX4000: no firmware needed
mkdir -p "$work/gx" "$work/gx-nopad"
python3 "$root/tests/make-cpr.py" "$work/gx/test.cpr" > /dev/null
python3 "$root/tests/make-cpr.py" "$work/gx-nopad/test.cpr" nopad > /dev/null
for d in gx gx-nopad; do
	printf '{"machine":"gx4000"}' > "$work/$d/settings"
	printf '{"game":["test.cpr"]}' > "$work/$d/slots"
done
"$wbxrun" "$core" "$work/gx" --frames 1 --list-panel > "$work/gx.panel" 2> /dev/null || true
reported "$work/gx.panel" > "$work/gx.core-names"
declared gx4000 > "$work/gx.declared-names"
check "gx4000: the core's controls are the package's" "$(wc -l < "$work/gx.declared-names") controls" \
	same "$work/gx.core-names" "$work/gx.declared-names"

# ram <dir> <out>: the test program's memory (&8000-&803f) after the run
# that wrote <dir>'s domains: found by the signature the program leaves at &8030
ram() { python3 - "$1" > "$2" <<'PY'
import os, sys
for name in sorted(os.listdir(sys.argv[1])):
    data = open(os.path.join(sys.argv[1], name), "rb").read()
    at = data.find(b"CPRT")
    if at >= 0x30:
        print(" ".join("%02x" % b for b in data[at - 0x30:at + 0x10]))
        break
PY
}
# gx_run <name> <frames> [options]: a run of the test cartridge, its memory kept
gx_run() {
	gr_name="$1"; gr_frames="$2"; shift 2
	rm -rf "$work/$gr_name.dom"; mkdir -p "$work/$gr_name.dom"
	"$wbxrun" "$core" "$work/gx" --frames "$gr_frames" --report "$gr_frames" --dump-domains "$work/$gr_name.dom" "$@" > "$work/$gr_name.out" 2>&1 || true
	ram "$work/$gr_name.dom" "$work/$gr_name.ram"
}
# byte <ram file> <offset>: one byte of the program's memory, as a number
byte() { awk -v o="$2" '{print strtonum("0x" $(o+1))}' "$1"; }

gx_run gx-idle 120
frames="$(( $(byte "$work/gx-idle.ram" 0) + 256 * $(byte "$work/gx-idle.ram" 1) ))"
check "gx4000: the test cartridge runs and counts its frames" "$frames frames counted of 120" \
	sh -c "[ $frames -ge 100 ] && [ $frames -le 121 ]"
# every joystick control clears one bit of its row: the one it is wired to
jbits=""; jok=1
for c in "P1 Up" "P1 Down" "P1 Left" "P1 Right" "P1 Button 1" "P1 Button 2" "P2 Up" "P2 Down" "P2 Left" "P2 Right" "P2 Button 1" "P2 Button 2"; do
	i="$(index "$work/gx.panel" "$c")"
	[ -n "$i" ] || { jok=0; continue; }
	gx_run gx-press 120 --press "$i:100:40"
	changed="$(python3 -c "
import sys
a = open(sys.argv[1]).read().split(); b = open(sys.argv[2]).read().split()
out = []
for row in range(10):
    x, y = int(a[8 + row], 16), int(b[8 + row], 16)
    for bit in range(8):
        if (x >> bit) & 1 and not (y >> bit) & 1: out.append('%d.%d' % (row, bit))
print(','.join(out))" "$work/gx-idle.ram" "$work/gx-press.ram")"
	case "$changed" in *,*|"") jok=0 ;; esac
	case " $jbits " in *" $changed "*) jok=0 ;; esac
	jbits="$jbits $changed"
done
# the CPC's wiring: joystick 1 is row 9 and joystick 2 row 6 of the matrix,
# bits 0 to 5 up, down, left, right, fire 1 and fire 2
check "gx4000: each joystick control is its own bit of the keyboard matrix" "row.bit:$jbits" \
	sh -c "[ '$jok' = 1 ] && [ '$jbits' = ' 9.0 9.1 9.2 9.3 9.4 9.5 6.0 6.1 6.2 6.3 6.4 6.5' ]"
lg_pad="$(stream "$work/gx-idle.out" | tail -1 | awk '{print $NF}')"
gr_dir="$work/gx"; "$wbxrun" "$core" "$work/gx-nopad" --frames 120 --report 120 > "$work/gx-nopad.out" 2>&1 || true
lg_none="$(stream "$work/gx-nopad.out" | tail -1 | awk '{print $NF}')"
check "gx4000: lag frames are counted" "${lg_pad:-?} of 120 reading the joysticks, ${lg_none:-?} of 120 reading nothing" \
	sh -c "[ '${lg_pad:-x}' -le 2 ] && [ '${lg_none:-x}' = 120 ]"

# native == sandbox, as a stream, under a wander over the controls
machine_tests() { # <label> <folder> <frames>
	mt="$1"; mt_dir="$2"; mt_frames="$3"
	"$native" "$mt_dir" --frames "$mt_frames" --report 50 --exercise > "$work/$mt.n" 2> "$work/$mt.n.err" || true
	"$wbxrun" "$core" "$mt_dir" --frames "$mt_frames" --report 50 --exercise > "$work/$mt.w" 2> "$work/$mt.w.err" || true
	"$wbxrun" "$core" "$mt_dir" --frames "$mt_frames" --report 50 > "$work/$mt.still" 2> /dev/null || true
	"$wbxrun" "$core" "$mt_dir" --frames "$mt_frames" --report 50 --exercise --rerecord > "$work/$mt.rr" 2> /dev/null || true
	"$wbxrun" "$core" "$mt_dir" --frames "$mt_frames" --report 50 --exercise --session > "$work/$mt.ss" 2> /dev/null || true
	stream "$work/$mt.n" > "$work/$mt.ns"; stream "$work/$mt.w" > "$work/$mt.ws"; stream "$work/$mt.still" > "$work/$mt.sts"
	stream "$work/$mt.rr" > "$work/$mt.rrs"; stream "$work/$mt.ss" > "$work/$mt.sss"
	mt_n="$(wc -l < "$work/$mt.ws")"
	mt_vid="$(awk '{print $7}' "$work/$mt.ws" | sort -u | wc -l)"
	check "$mt: it runs, and its picture changes" "$mt_n reports, $mt_vid pictures" \
		sh -c "[ $mt_n = $((mt_frames / 50)) ] && [ $mt_vid -gt 1 ]"
	check "$mt: the sandbox is the reference, every 50 frames" "" same "$work/$mt.ns" "$work/$mt.ws"
	check "$mt: the controls reach it (a run without them differs)" "" differ "$work/$mt.ws" "$work/$mt.sts"
	check "$mt: a state saved and loaded every frame changes nothing" "" same "$work/$mt.ws" "$work/$mt.rrs"
	check "$mt: a state moved to a new sandbox changes nothing" "" same "$work/$mt.ws" "$work/$mt.sss"
}
machine_tests gx4000 "$work/gx" 600

# ------------------------------------ 3. machines that need firmware
for m in intv:3000 channelf:1500 vectrex:1500; do
	name="${m%%:*}"; frames="${m#*:}"
	if [ ! -f "$roms/$name/settings" ]; then
		report SKIP "$name: its tests" "no folder $roms/$name"
		continue
	fi
	copy_folder "$roms/$name" "$name"
	"$wbxrun" "$core" "$work/$name" --frames 1 --list-panel > "$work/$name.panel" 2> /dev/null || true
	reported "$work/$name.panel" > "$work/$name.core-names"
	declared "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['machine'])" "$roms/$name/settings")" > "$work/$name.declared-names"
	check "$name: the core's controls are the package's" "$(wc -l < "$work/$name.declared-names") controls" \
		same "$work/$name.core-names" "$work/$name.declared-names"
	machine_tests "$name" "$work/$name" "$frames"
done
# a firmware file missing: the machine is not built, and the file is named
if [ -f "$roms/intv/settings" ]; then
	copy_folder "$roms/intv" intv-nogrom
	rm -f "$work/intv-nogrom/ro-3-9503-003.u21"
	"$wbxrun" "$core" "$work/intv-nogrom" --frames 1 > "$work/intv-nogrom.run" 2>&1 || true
	check "intv: a missing firmware file is named, and nothing runs" "$(grep -o 'ro-3-9503-003.u21 - [a-z]*' "$work/intv-nogrom.run" | head -1)" \
		grep -q "Init failed.*ro-3-9503-003.u21 - missing" "$work/intv-nogrom.run"
	copy_folder "$roms/intv" intv-analog '{"machine":"intv","config.Controller Disc Emulation":"Analog"}'
	"$wbxrun" "$core" "$work/intv-analog" --frames 1 --list-panel > "$work/intv-analog.panel" 2> /dev/null || true
	check "intv: the disc is buttons or axes, as its switch says" "" \
		sh -c "grep -q \"'P1 Up-Right' active\" '$work/intv.panel' && grep -q \"'P1 Up-Right' -\" '$work/intv-analog.panel'"
fi

# ------------------------------------------------ 4. Chimera's own checks
# Through Chimera's engine, as a project with a movie, the way the window
# plays one: the GX4000 cartridge with P1 Up held in the movie, beside the
# same project with an idle movie; the joystick's row in memory says which.
if [ -x "$run" ] && [ -f "$pkg" ]; then
	for mv in up idle; do
		[ "$mv" = up ] && press="press=P1 Up:100:100" || press="press=P1 Down:0:0"
		python3 "$root/tests/make-project.py" "$pkg" "$work/gx-$mv.chimeraProject" 200 machine=gx4000 "$press" \
			-- "game=$work/gx/test.cpr" > "$work/gx-$mv.project.log" 2>&1 || true
		"$run" --project "$work/gx-$mv.chimeraProject" "$pkg" --files "$work/gx" \
			--dump "RAM Slot/:ram/0/m_pointer=$work/gx-$mv.engine.ram" > "$work/gx-$mv.engine" 2>&1 || true
	done
	row9() { od -An -tx1 -j $((0x8011)) -N1 "$1" 2> /dev/null | tr -d ' '; }
	check "gx4000: a project's movie reaches the machine in Chimera's engine" "joystick row: $(row9 "$work/gx-up.engine.ram") held, $(row9 "$work/gx-idle.engine.ram") idle" \
		sh -c "grep -q '^frames=200' '$work/gx-up.engine' && [ '$(row9 "$work/gx-up.engine.ram")' = fe ] && [ '$(row9 "$work/gx-idle.engine.ram")' = ff ]"
	if [ -f "$roms/intv/settings" ]; then
		fw=""
		for f in exec.bin ro-3-9503-003.u21; do fw="$fw --firmware $f=$roms/intv/$f"; done
		for mv in enter idle; do
			[ "$mv" = enter ] && press="press=P1 Enter:200:10" || press="press=P1 Enter:0:0"
			python3 "$root/tests/make-project.py" "$pkg" "$work/intv-$mv.chimeraProject" 400 machine=intv "$press" \
				"config.Controller Disc Emulation=Digital" "panel=$work/intv.panel" \
				-- "game=$roms/intv/astrosmash.int" > "$work/intv-$mv.project.log" 2>&1 || true
			# shellcheck disable=SC2086
			"$run" --project "$work/intv-$mv.chimeraProject" "$pkg" --files "$roms/intv" $fw \
				--screenshot "399=$work/intv-$mv.tga" > "$work/intv-$mv.engine" 2>&1 || true
		done
		check "intv: a project with its firmware plays a movie in Chimera's engine" "Enter starts Astrosmash" \
			sh -c "grep -q '^frames=400' '$work/intv-enter.engine' && grep -q '^frames=400' '$work/intv-idle.engine' && ! cmp -s '$work/intv-enter.tga' '$work/intv-idle.tga'"
	else
		report SKIP "intv: a project with its firmware plays a movie in Chimera's engine" "no folder $roms/intv"
	fi
else
	report SKIP "gx4000: a project's movie reaches the machine in Chimera's engine" "no chimera-run at $run, or no package"
fi
tests="$chimera_root/source/gui/Chimera.Tests.Client.Common/Chimera.Tests.Client.Common.csproj"
if [ -f "$tests" ] && command -v dotnet > /dev/null 2>&1 && [ -f "$pkg" ]; then
	if CHIMERA_CORES_DIR="$(dirname "$pkg")" env -u DISPLAY dotnet test "$tests" -c Release --no-build \
		--filter "FullyQualifiedName~InstalledCorePackagesTests|FullyQualifiedName~MnemonicUniquenessTests" > "$work/contract.log" 2>&1; then
		report PASS "Chimera's package checks" "$(grep -o 'Passed: *[0-9]*' "$work/contract.log" | tail -1)"
	else
		report FAIL "Chimera's package checks" "see $work/contract.log"
	fi
else
	report SKIP "Chimera's package checks" "no dotnet, or no chimera tests at $tests"
fi

finish
