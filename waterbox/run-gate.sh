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
# every key the default bindings name is one Chimera sends (a binding to a
# name it never sends never fires)
if [ -f "$chimera_root/source/ui/qt/key_codes.inc" ]; then
	if python3 "$root/tests/check-key-names.py" "$chimera_root" "$here/default_keybinds.json" > "$work/keynames.log" 2>&1; then
		report PASS "the default key bindings name keys Chimera sends" "$(tail -1 "$work/keynames.log")"
	else
		report FAIL "the default key bindings name keys Chimera sends" "$(tail -1 "$work/keynames.log")"
	fi
else
	report SKIP "the default key bindings name keys Chimera sends" "no Chimera source at $chimera_root"
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

# A keyboard's keys are where a person looks for them (chimera#310): a key named
# by a single letter or digit writes that character into a movie and heads its
# TAStudio column with it, and the CPC's keys run along its rows, its top row
# first. Read from the package, which gen-config.py writes from the core.
keys_out="$(python3 - "$here/waterbox.config" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
bad = []
for m in c["machines"]:
    inp = m["input"]
    for b in inp["buttons"]:
        if len(b) == 1 and b.isalnum() and inp.get("mnemonics", {}).get(b) != b:
            bad.append(f"{m['label']}: {b} is {inp.get('mnemonics', {}).get(b)}")
cpc = next(m for m in c["machines"] if m.get("label") == "Amstrad CPC464")
top = [b for b in cpc["input"]["buttons"] if not b.startswith("P")][:5]
if top != ["Esc", "1 !", "2 \" ~", "3 #", "4 $"]:
    bad.append(f"CPC464 starts {top}")
print("; ".join(bad) if bad else "ok")
PYEOF
)"
check "keyboards: a letter or digit key is its own letter, and the CPC's keys follow its rows" "$keys_out" [ "$keys_out" = ok ]

# ram <dir> <signature> <out>: the test program's memory (64 bytes) after
# the run that wrote <dir>'s domains: found by the signature the program
# leaves 0x30 bytes in
ram() { python3 - "$1" "$2" > "$3" <<'PY'
import os, sys
for name in sorted(os.listdir(sys.argv[1])):
    data = open(os.path.join(sys.argv[1], name), "rb").read()
    at = data.find(sys.argv[2].encode())
    if at >= 0x30:
        print(" ".join("%02x" % b for b in data[at - 0x30:at + 0x10]))
        break
PY
}
# prog_run <folder> <signature> <name> <frames> [options]: a run of a test
# cartridge in the sandbox, its memory kept
prog_run() {
	pr_dir="$1"; pr_sig="$2"; pr_name="$3"; pr_frames="$4"; shift 4
	rm -rf "$work/$pr_name.dom"; mkdir -p "$work/$pr_name.dom"
	"$wbxrun" "$core" "$pr_dir" --frames "$pr_frames" --report "$pr_frames" --dump-domains "$work/$pr_name.dom" "$@" > "$work/$pr_name.out" 2>&1 || true
	ram "$work/$pr_name.dom" "$pr_sig" "$work/$pr_name.ram"
}
# byte <ram file> <offset>: one byte of the program's memory, as a number
byte() { awk -v o="$2" '{print strtonum("0x" $(o+1))}' "$1"; }
# wiring <label> <folder> <signature> <panel> <first byte> <bytes> <expected> <control>...:
# each control, held from frame 100 to the end of a 120-frame run, changes
# the bits of the program's copy of the machine's inputs that the expected
# list says, in order: "row.bit" for a bit that goes to 0 and "row.bit+"
# for one that goes to 1, several of one control joined by ","
wiring() {
	wr_label="$1"; wr_dir="$2"; wr_sig="$3"; wr_panel="$4"; wr_first="$5"; wr_n="$6"; wr_want="$7"; shift 7
	prog_run "$wr_dir" "$wr_sig" "$wr_label-idle" 120
	wr_got=""
	for c in "$@"; do
		i="$(index "$wr_panel" "$c")"
		[ -n "$i" ] || { wr_got="$wr_got ?"; continue; }
		prog_run "$wr_dir" "$wr_sig" "$wr_label-press" 120 --press "$i:100:40"
		wr_got="$wr_got $(python3 -c "
import sys
a = open(sys.argv[1]).read().split(); b = open(sys.argv[2]).read().split()
first, n = int(sys.argv[3]), int(sys.argv[4])
out = []
for row in range(n):
    x, y = int(a[first + row], 16), int(b[first + row], 16)
    for bit in range(8):
        if (x >> bit) & 1 and not (y >> bit) & 1: out.append('%d.%d' % (row, bit))
        if not (x >> bit) & 1 and (y >> bit) & 1: out.append('%d.%d+' % (row, bit))
print(','.join(out) or '-')" "$work/$wr_label-idle.ram" "$work/$wr_label-press.ram" "$wr_first" "$wr_n")"
	done
	check "$wr_label: each control reaches the input it is wired to" "$wr_got" [ "$wr_got" = " $wr_want" ]
}

prog_run "$work/gx" CPRT gx-idle 120
frames="$(( $(byte "$work/gx-idle.ram" 0) + 256 * $(byte "$work/gx-idle.ram" 1) ))"
check "gx4000: the test cartridge runs and counts its frames" "$frames frames counted of 120" \
	sh -c "[ $frames -ge 100 ] && [ $frames -le 121 ]"
# the CPC's wiring: joystick 1 is row 9 and joystick 2 row 6 of the keyboard
# matrix, bits 0 to 5 up, down, left, right, fire 1 and fire 2
wiring gx4000 "$work/gx" CPRT "$work/gx.panel" 8 10 "9.0 9.1 9.2 9.3 9.4 9.5 6.0 6.1 6.2 6.3 6.4 6.5" \
	"P1 Up" "P1 Down" "P1 Left" "P1 Right" "P1 Button 1" "P1 Button 2" "P2 Up" "P2 Down" "P2 Left" "P2 Right" "P2 Button 1" "P2 Button 2"
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
for m in intv:3000 channelf:1500 vectrex:1500 a7800:1500 odyssey2:1500 cpc:3000 ti83:1500 bbc:3000; do
	name="${m%%:*}"; frames="${m#*:}"
	if [ ! -f "$roms/$name/settings" ]; then
		report SKIP "$name: its tests" "no folder $roms/$name"
		continue
	fi
	copy_folder "$roms/$name" "$name"
	# the 7800's game is a cartridge the test writes (its folder holds the BIOS)
	[ "$name" = a7800 ] && python3 "$root/tests/make-a78.py" "$work/a7800/test.a78" > /dev/null
	[ "$name" = odyssey2 ] && python3 "$root/tests/make-o2.py" "$work/odyssey2/test.bin" > /dev/null
	[ "$name" = ti83 ] && python3 "$root/tests/make-83p.py" "$work/ti83/test.83p" > /dev/null
	"$wbxrun" "$core" "$work/$name" --frames 1 --list-panel > "$work/$name.panel" 2> /dev/null || true
	reported "$work/$name.panel" > "$work/$name.core-names"
	declared "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['machine'])" "$roms/$name/settings")" > "$work/$name.declared-names"
	check "$name: the core's controls are the package's" "$(wc -l < "$work/$name.declared-names") controls" \
		same "$work/$name.core-names" "$work/$name.declared-names"
	machine_tests "$name" "$work/$name" "$frames"
done
# the 7800's wiring, through MAME's driver: P1's directions are SWCHA's high
# four bits and P2's its low four; each button of a two-button joystick sets
# its own TIA input and clears its player's fire input; the console's
# switches are SWCHB's bits 0, 1 and 3
if [ -f "$work/a7800/test.a78" ]; then
	wiring a7800 "$work/a7800" A78T "$work/a7800.panel" 2 12 \
		"0.4 0.5 0.6 0.7 7.7+,10.7 6.7+,10.7 0.0 0.1 0.2 0.3 9.7+,11.7 8.7+,11.7 1.0 1.1 1.3" \
		"P1 Up" "P1 Down" "P1 Left" "P1 Right" "P1 Button 1" "P1 Button 2" \
		"P2 Up" "P2 Down" "P2 Left" "P2 Right" "P2 Button 1" "P2 Button 2" Reset Select Pause
fi
# the Odyssey 2's wiring: joystick 0 is P1 and joystick 1 P2, each read on
# the data bus with up, right, down and left in bits 0 to 3 and fire in bit 4
if [ -f "$work/odyssey2/test.bin" ]; then
	wiring odyssey2 "$work/odyssey2" 'O2T!' "$work/odyssey2.panel" 22 2 \
		"0.0 0.2 0.3 0.1 0.4 1.0 1.2 1.3 1.1 1.4" \
		"P1 Up" "P1 Down" "P1 Left" "P1 Right" "P1 Button 1" "P2 Up" "P2 Down" "P2 Left" "P2 Right" "P2 Button 1"
fi
# the TI-83: a program file goes over the link cable (patch 0008) a few
# seconds after power-on; ON, then PRGM, ENTER, ENTER runs it, and it shows
# 4242. Beside it the same keys with no file, which find no program.
if [ -f "$work/ti83/test.83p" ]; then
	copy_folder "$work/ti83" ti83-nofile
	rm -f "$work/ti83-nofile/test.83p"; printf '{}' > "$work/ti83-nofile/slots"
	ti_keys() { for k in "ON/OFF:30:10" "PRGM:400:5" "ENTER:450:5" "ENTER:500:5"; do
		printf -- '--press %s:%s ' "$(index "$work/ti83.panel" "${k%%:*}")" "${k#*:}"; done; }
	for d in ti83 ti83-nofile; do
		rm -rf "$work/$d.dom"; mkdir -p "$work/$d.dom"
		# shellcheck disable=SC2046
		"$wbxrun" "$core" "$work/$d" --frames 600 --report 600 $(ti_keys) --dump-domains "$work/$d.dom" --vid-out "$work/$d.vid" > "$work/$d.keys" 2>&1 || true
	done
	has_program() { python3 -c "
import glob, sys
d = open(glob.glob(sys.argv[1] + '/*-nvram')[0], 'rb').read()
sys.exit(0 if d.find(bytes.fromhex('de34323432')) >= 0 and d.find(b'AREMIHC') >= 0 else 1)" "$1" 2> /dev/null; }
	if has_program "$work/ti83.dom" && ! has_program "$work/ti83-nofile.dom"; then
		report PASS "ti83: the program is in RAM after the transfer, and not without the file" "its tokens and its catalogue entry"
	else
		report FAIL "ti83: the program is in RAM after the transfer, and not without the file"
	fi
	check "ti83: run by its keys, it changes the screen" "PRGM, ENTER, ENTER" differ "$work/ti83.vid" "$work/ti83-nofile.vid"
fi
# The CPC's disks: two disks the test writes (tests/make-dsk.py), one file
# on each, in one list for drive A. What CAT read is in AMSDOS's directory
# buffer in RAM ("ONE     TXT"), so the RAM after a run says which disk was
# in. Typed with tests/type-keys.py.
if [ -f "$roms/cpc/settings" ]; then
	copy_folder "$roms/cpc" cpcd
	python3 "$root/tests/make-dsk.py" "$work/cpcd/one.dsk" ONE > /dev/null
	python3 "$root/tests/make-dsk.py" "$work/cpcd/two.dsk" TWO > /dev/null
	printf '{"game":["one.dsk","two.dsk"]}' > "$work/cpcd/slots"
	"$wbxrun" "$core" "$work/cpcd" --frames 1 --list-panel > "$work/cpcd.panel" 2> /dev/null || true
	keys() { python3 "$root/tests/type-keys.py" "$work/cpcd.panel" "$1" "$2"; }
	# disk_run <name> <frames> <key options...>: the RAM after the run, as one file
	disk_run() {
		dr_name="$1"; dr_frames="$2"; shift 2
		rm -rf "$work/$dr_name.dom"; mkdir -p "$work/$dr_name.dom"
		"$wbxrun" "$core" "$work/cpcd" --frames "$dr_frames" --report "$dr_frames" "$@" --dump-domains "$work/$dr_name.dom" > "$work/$dr_name.out" 2>&1 || true
		cat "$work/$dr_name.dom"/*RAM* > "$work/$dr_name.ram" 2> /dev/null || true
	}
	check "cpc: a machine with a drive has the disk controls, one without has none" "" \
		sh -c "grep -q \"'Next Disk' active\" '$work/cpcd.panel' && ! grep -q 'Next Disk' '$work/gx.panel'"
	# shellcheck disable=SC2046
	disk_run cpcd-one 500 $(keys 150 'cat\n')
	# shellcheck disable=SC2046
	disk_run cpcd-two 700 $(keys 150 'cat\n') $(keys 300 '{Next Disk}') $(keys 350 'cat\n')
	check "cpc: Next Disk puts the second disk in" "CAT reads ONE, then TWO after Next Disk" \
		sh -c "grep -q -a 'ONE     TXT' '$work/cpcd-one.ram' && ! grep -q -a 'TWO     TXT' '$work/cpcd-one.ram' && grep -q -a 'TWO     TXT' '$work/cpcd-two.ram'"
	# what a program saves to disk one is still on it after the disk went out
	# and came back, CAT reading the directory afresh from the disk in between
	# shellcheck disable=SC2046
	disk_run cpcd-save 1100 $(keys 150 'save"x"\n') $(keys 600 '{Next Disk}') $(keys 640 'cat\n') $(keys 800 '{Previous Disk}') $(keys 840 'cat\n')
	# shellcheck disable=SC2046
	disk_run cpcd-nosave 1100 $(keys 600 '{Next Disk}') $(keys 640 'cat\n') $(keys 800 '{Previous Disk}') $(keys 840 'cat\n')
	check "cpc: what is saved to a disk stays on it when it comes out and goes back" "X.BAS after Next Disk and Previous Disk" \
		sh -c "grep -q -a 'X       BAS' '$work/cpcd-save.ram' && ! grep -q -a 'X       BAS' '$work/cpcd-nosave.ram' && grep -q -a 'ONE     TXT' '$work/cpcd-save.ram'"
	# shellcheck disable=SC2046
	disk_run cpcd-eject 600 $(keys 150 '{Eject Disk}') $(keys 200 'cat\n')
	check "cpc: Eject Disk leaves the drive empty" "CAT then reads no directory" \
		sh -c "! grep -q -a 'ONE     TXT' '$work/cpcd-eject.ram' && [ -s '$work/cpcd-eject.ram' ]"
	# the swaps run the same in the reference and in the sandbox, and through
	# savestates
	# shellcheck disable=SC2046
	set -- $(keys 150 'save"x"\n') $(keys 600 '{Next Disk}') $(keys 640 'cat\n') $(keys 800 '{Previous Disk}') $(keys 840 'cat\n')
	"$native" "$work/cpcd" --frames 1100 --report 50 "$@" > "$work/cpcd-swap.n" 2> /dev/null || true
	"$wbxrun" "$core" "$work/cpcd" --frames 1100 --report 50 "$@" > "$work/cpcd-swap.w" 2> /dev/null || true
	"$wbxrun" "$core" "$work/cpcd" --frames 1100 --report 50 "$@" --rerecord > "$work/cpcd-swap.rr" 2> /dev/null || true
	stream "$work/cpcd-swap.n" > "$work/cpcd-swap.ns"; stream "$work/cpcd-swap.w" > "$work/cpcd-swap.ws"; stream "$work/cpcd-swap.rr" > "$work/cpcd-swap.rrs"
	check "cpc: swaps run the same in the sandbox and with a state saved and loaded every frame" "" \
		sh -c "cmp -s '$work/cpcd-swap.ns' '$work/cpcd-swap.ws' && cmp -s '$work/cpcd-swap.ws' '$work/cpcd-swap.rrs' && [ -s '$work/cpcd-swap.ws' ]"
	# Export Save Data hands out each disk the machine wrote to - in the drive
	# or taken out - under its own name, as an Extended DSK; taken back as the
	# game of a new project it is the disk as the machine left it
	mkdir -p "$work/cpcd-x1" "$work/cpcd-x2" "$work/cpcd-x0"
	# shellcheck disable=SC2046
	"$wbxrun" "$core" "$work/cpcd" --frames 600 --report 600 $(keys 150 'save"x"\n') --savedata-out "$work/cpcd-x1" > /dev/null 2>&1 || true
	# shellcheck disable=SC2046
	"$wbxrun" "$core" "$work/cpcd" --frames 700 --report 700 $(keys 150 'save"x"\n') $(keys 600 '{Next Disk}') --savedata-out "$work/cpcd-x2" > /dev/null 2>&1 || true
	# shellcheck disable=SC2046
	"$wbxrun" "$core" "$work/cpcd" --frames 600 --report 600 $(keys 150 'cat\n') --savedata-out "$work/cpcd-x0" > /dev/null 2>&1 || true
	check "cpc: Export Save Data hands out the disk written to, and only that" "$(ls "$work/cpcd-x1" | tr '\n' ' ')" \
		sh -c "[ \"\$(ls '$work/cpcd-x1')\" = one.dsk ] && [ \"\$(ls '$work/cpcd-x2')\" = one.dsk ] && [ -z \"\$(ls '$work/cpcd-x0')\" ]"
	check "cpc: the exported disk is the given one except where the machine wrote" "every track but the directory's the same, sector by sector" \
		python3 - "$work/cpcd/one.dsk" "$work/cpcd-x1/one.dsk" <<'PY'
import sys
def sectors(path):
    d = open(path, "rb").read()
    ext = d.startswith(b"EXTENDED")
    tracks, sides = d[48], d[49]
    out, at = {}, 256
    for t in range(tracks * sides):
        size = d[52 + t] * 256 if ext else d[50] | d[51] << 8
        if not size: continue
        b = d[at:at + size]
        n, at2 = b[21], 256 * ((0x18 + 8 * b[21] + 255) // 256)
        for i in range(n):
            e = b[0x18 + 8 * i:0x18 + 8 * i + 8]
            length = (e[6] | e[7] << 8) if ext else 128 << e[3]
            out[(e[0], e[1], e[2])] = (bytes(b[at2:at2 + length]), e[4], e[5])
            at2 += length
        at += size
    return out
a, b = sectors(sys.argv[1]), sectors(sys.argv[2])
assert set(a) == set(b), "the sectors differ"
assert all(st1 == 0 and st2 == 0 for _, st1, st2 in b.values()), "an error status"
changed = [k for k in a if a[k][0] != b[k][0]]
assert changed and all(k[0] == 0 for k in changed), changed
PY
	mkdir -p "$work/cpcd-back"
	cp "$work/cpcd"/*.rom "$work/cpcd-back/"; cp "$work/cpcd-x1/one.dsk" "$work/cpcd-back/"
	printf '{"machine":"cpc6128"}' > "$work/cpcd-back/settings"; printf '{"game":["one.dsk"]}' > "$work/cpcd-back/slots"
	rm -rf "$work/cpcd-back.dom"; mkdir -p "$work/cpcd-back.dom"
	# shellcheck disable=SC2046
	"$wbxrun" "$core" "$work/cpcd-back" --frames 500 --report 500 $(keys 150 'cat\n') --dump-domains "$work/cpcd-back.dom" > /dev/null 2>&1 || true
	check "cpc: the exported disk, taken back as a game, has the saved file" "CAT lists X.BAS" \
		sh -c "cat '$work/cpcd-back.dom'/*RAM* | grep -q -a 'X       BAS'"
	# the same through Chimera's engine: a project whose movie types SAVE"X",
	# and Export Save Data at its end
	if [ -x "$run" ] && [ -f "$pkg" ]; then
		keys 150 'save"x"\n' | python3 -c "
import re, sys
names = {}
for line in open(sys.argv[1]):
    m = re.match(r\"panel (\\d+) '(.*)' \", line)
    if m: names[m.group(1)] = m.group(2)
for i, f in re.findall(r'--press (\\d+):(\\d+):4', sys.stdin.read()):
    print('%s:%s:4' % (names[i], f))" "$work/cpcd.panel" > "$work/cpcd-engine.presses"
		mkdir -p "$work/cpcd-engine" "$work/cpcd-engine.out"
		cp "$work/cpcd/one.dsk" "$work/cpcd/two.dsk" "$work/cpcd-engine/"
		python3 "$root/tests/make-project.py" "$pkg" "$work/cpcd-engine/cpc.chimeraProject" 600 machine=cpc6128 \
			"pressfile=$work/cpcd-engine.presses" "panel=$work/cpcd.panel" \
			-- "game=$work/cpcd-engine/one.dsk" "game=$work/cpcd-engine/two.dsk" > "$work/cpcd-engine.log" 2>&1 || true
		"$run" --project "$work/cpcd-engine/cpc.chimeraProject" "$pkg" --files "$work/cpcd-engine" \
			--firmware "cpc6128.rom=$work/cpcd/cpc6128.rom" --firmware "cpcados.rom=$work/cpcd/cpcados.rom" \
			--export-savedata "$work/cpcd-engine.out" >> "$work/cpcd-engine.log" 2>&1 || true
		check "cpc: Chimera's engine exports the disk a project's movie saved to" "$(ls "$work/cpcd-engine.out" | tr '\n' ' ')" \
			sh -c "[ -f '$work/cpcd-engine.out/one.dsk' ] && cmp -s '$work/cpcd-engine.out/one.dsk' '$work/cpcd-x1/one.dsk'"
	else
		report SKIP "cpc: Chimera's engine exports the disk a project's movie saved to" "no chimera-run or package"
	fi
	# nothing is written to the files the machine was given
	check "cpc: the disk files given are never written" "" \
		sh -c "python3 '$root/tests/make-dsk.py' '$work/one.check' ONE > /dev/null && cmp -s '$work/one.check' '$work/cpcd/one.dsk'"
fi
# a firmware file missing: the machine is not built, and the file is named
if [ -f "$roms/intv/settings" ]; then
	copy_folder "$roms/intv" intv-nogrom
	rm -f "$work/intv-nogrom/ro-3-9503-003.u21"
	"$wbxrun" "$core" "$work/intv-nogrom" --frames 1 > "$work/intv-nogrom.run" 2>&1 || true
	check "intv: a missing firmware file is named, and nothing runs" "$(grep -o 'ro-3-9503-003.u21 - [a-z]*' "$work/intv-nogrom.run" | head -1)" \
		grep -q "Init failed.*ro-3-9503-003.u21 - missing" "$work/intv-nogrom.run"
	# what the New Project window is told before its Firmware page: the files the machine reads,
	# none of them said to be missing, as the window has handed the core no firmware yet (chimera#364)
	"$wbxrun" "$core" "$work/intv-nogrom" --suggest > "$work/intv-nogrom.suggest" 2>&1 || true
	check "intv: the wizard's note names the firmware and calls none missing" "$(grep -o 'It reads [^.]*' "$work/intv-nogrom.suggest" | head -1)" \
		sh -c "grep -q 'The Firmware page asks for them' '$work/intv-nogrom.suggest' && ! grep -q 'missing' '$work/intv-nogrom.suggest'"
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
tests="$chimera_root/build/meson-linux/source/ui/test-packages"
if [ -x "$tests" ] && [ -f "$pkg" ]; then
	if CHIMERA_CORES_DIR="$(dirname "$pkg")" env -u DISPLAY "$tests" > "$work/contract.log" 2>&1; then
		report PASS "Chimera's package checks" "$(tail -1 "$work/contract.log")"
	else
		report FAIL "Chimera's package checks" "see $work/contract.log"
	fi
else
	report SKIP "Chimera's package checks" "no test-packages program at $tests, or no package"
fi

finish
