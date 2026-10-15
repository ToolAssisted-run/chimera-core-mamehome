#!/bin/bash
# The window test: the package loaded by Chimera itself (Chimera.exe under
# Mono, on a private Xvfb display, with nobody at it), not by its headless
# runner. Asked:
#  - the GX4000 test cartridge (tests/make-cpr.py, no firmware) runs in the
#    window: Chimera takes the package as the core for the machine the
#    project names, the machine runs the frames asked for, and its memory
#    after them is byte for byte what Chimera's headless runner leaves;
#  - the keys the package ships become Chimera's keys for the machine;
#  - with the Intellivision (when tests/roms-local/intv is there): without
#    its firmware the project is refused and a firmware file is named; with
#    the firmware in Chimera's configuration, Astrosmash's RAM after the
#    frames is what the headless runner leaves.
#
# Usage: tests/run-frontend.sh --chimera-root <chimera checkout> [--frames N] [--keep]
#   --keep   leave the work folder (logs, configurations, projects) and say where it is
# Needs: mono, Xvfb, Chimera built with its window (dotnet build), and the
# package installed in that checkout (waterbox/build-package.sh -r <chimera>).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
wb="$root/waterbox"
frames=300
chimera_root=""
keep=""
while [ $# -gt 0 ]; do
	case "$1" in
		--keep) keep=1 ;;
		--chimera-root) chimera_root="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
	shift
done
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || { echo "say where Chimera is: --chimera-root <chimera checkout>" >&2; exit 2; }
chimera_root="$(cd "$chimera_root" && pwd)"
roms="${HOME_ROMS:-$here/roms-local}"

emu_exe="$chimera_root/build/Chimera.exe"
package="$chimera_root/build/Cores/mamehome.chimeraCore"
bin="$wb/bin"
runner="$chimera_root/build/meson-linux/chimera-run"
[ -f "$emu_exe" ] || { echo "Chimera's window is not built: $emu_exe" >&2; exit 1; }
[ -f "$package" ] || { echo "the package is not installed: $package (run waterbox/build-package.sh -r $chimera_root)" >&2; exit 1; }
[ -x "$bin/run-wbx" ] || { echo "the sandbox build is not there: $bin/run-wbx" >&2; exit 1; }
[ -x "$runner" ] || { echo "Chimera's headless runner is not built: $runner" >&2; exit 1; }

work="$(mktemp -d)"
xvfb_pid=""
cleanup() {
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null
	if [ -n "$keep" ]; then echo "work folder kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

export LD_LIBRARY_PATH="$chimera_root/build/dll:$chimera_root/build:/usr/lib/x86_64-linux-gnu"
export MONO_CRASH_NOFILE=1 MONO_WINFORMS_XIM_STYLE=disabled ALSOFT_DRIVERS=null
# always a display of this test's own: nobody's desktop is drawn on
command -v Xvfb >/dev/null || { echo "Xvfb not found (apt install xvfb)" >&2; exit 1; }
for n in 90 91 92 93 94 95 96; do
	if [ ! -e "/tmp/.X11-unix/X$n" ]; then
		Xvfb ":$n" -screen 0 640x480x24 -nolisten tcp > /dev/null 2>&1 & xvfb_pid=$!
		export DISPLAY=":$n"; break
	fi
done
[ -n "$xvfb_pid" ] || { echo "no free display number for Xvfb" >&2; exit 1; }
sleep 1

config="$work/config.ini"
( cd "$chimera_root" && timeout 120 mono "$emu_exe" --headless "--config=$config" "--lua=$here/exit.lua" ) > "$work/bootstrap.log" 2>&1
[ -f "$config" ] || { echo "Chimera did not write a configuration:"; tail -5 "$work/bootstrap.log"; exit 1; } >&2
sed -i 's/"DispMethod": [0-9]/"DispMethod": 1/' "$config"

ok=0
failed=0
skipped=0
report() {
	printf '%-16s %-5s %s\n' "$1" "$2" "$3"
	case "$2" in PASS) ok=$((ok + 1)) ;; SKIP) skipped=$((skipped + 1)) ;; *) failed=$((failed + 1)) ;; esac
}

# project <tag> <machine> <settings json for the probe> <game or ""> [<setting>=<value>...]: a
# project with an idle movie in the machine's live controls, its game beside it
project() {
	local tag="$1" machine="$2" probe_settings="$3" game="$4"; shift 4
	local dir="$work/$tag" probe="$work/$tag.probe" slots='{}' gamearg=""
	mkdir -p "$dir" "$probe"
	cp "$roms_dir"/* "$probe/" 2> /dev/null
	if [ -n "$game" ]; then
		cp "$game" "$dir/"; cp "$game" "$probe/"
		slots="{\"game\":[\"$(basename "$game")\"]}"; gamearg="game=$dir/$(basename "$game")"
	fi
	printf '%s' "$slots" > "$probe/slots"; printf '%s' "$probe_settings" > "$probe/settings"
	"$bin/run-wbx" "$bin/core.wbx" "$probe" --frames 1 --list-panel > "$work/$tag.panel" 2> /dev/null
	rm -rf "$probe"
	python3 "$here/make-project.py" "$package" "$dir/$tag.chimeraProject" "$frames" "machine=$machine" "panel=$work/$tag.panel" "$@" \
		-- $gamearg > "$work/$tag.log" 2>&1
}
# in_window <tag> <configuration> <system> <domain or "">: the project in Chimera's window
in_window() {
	local tag="$1" cfg="$2" system="$3" domain="$4" job="$work/job.$1.txt"
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\ndomain=%s\nsystem=%s\n' "$frames" "$work/$tag.ram.bin" "$work/$tag.meta.txt" "$domain" "$system" > "$job"
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout 900 mono "$emu_exe" --headless \
		"--config=$cfg" "--project=$work/$tag/$tag.chimeraProject" "--lua=$here/frontend-ram.lua" ) >> "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}
value() { sed -n "s/^$2=//p" "$work/$1.meta.txt" 2>/dev/null; }

python3 "$here/settings-config.py" "$config" "$work/config.base.ini" '{}'

# the GX4000: no firmware
roms_dir="$work/none"; mkdir -p "$roms_dir"
python3 "$here/make-cpr.py" "$work/test.cpr" > /dev/null
gxdomain="RAM Slot/:ram/0/m_pointer"
project gx gx4000 '{"machine":"gx4000"}' "$work/test.cpr"
"$runner" --project "$work/gx/gx.chimeraProject" "$package" --files "$work/gx" --dump "$gxdomain=$work/gx.engine.bin" > "$work/gx.engine.log" 2>&1
if ! in_window gx "$work/config.base.ini" AmstradCPC "$gxdomain"; then
	report "window:gx4000" FAIL "Chimera did not finish the run: $(value gx detail) $(tail -2 "$work/gx.log" | tr '\n' ' ' | cut -c1-200)"
elif [ "$(value gx frames)" = "$frames" ] && [ -s "$work/gx.engine.bin" ] && cmp -s "$work/gx.engine.bin" "$work/gx.ram.bin"; then
	report "window:gx4000" PASS "the GX4000 test cartridge ran $frames frames in Chimera's window; its RAM ($(wc -c < "$work/gx.ram.bin") bytes) is what the headless runner leaves"
else
	report "window:gx4000" FAIL "frames $(value gx frames) of $frames, or the memory differs from the headless runner's"
fi

controller="Amstrad GX4000 Controls"
python3 "$here/forget-controller.py" "$work/config.base.ini" "$work/config.keys.ini" "$controller"
if in_window gx "$work/config.keys.ini" AmstradCPC ""; then
	if python3 "$here/check-keybinds.py" "$work/config.keys.ini" "$wb/default_keybinds.json" "$controller" "P1 Up" > "$work/keys.txt" 2>&1; then
		report "window:keys" PASS "$(cat "$work/keys.txt")"
	else
		report "window:keys" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "window:keys" FAIL "Chimera did not finish the run: $(tail -2 "$work/gx.log" | tr '\n' ' ' | cut -c1-200)"
fi

# the Intellivision, with its firmware from Chimera's configuration
if [ ! -f "$roms/intv/exec.bin" ] || [ ! -f "$roms/intv/ro-3-9503-003.u21" ] || [ ! -f "$roms/intv/astrosmash.int" ]; then
	report "window:refusal" SKIP "needs $roms/intv (exec.bin, ro-3-9503-003.u21, astrosmash.int)"
	report "window:firmware" SKIP "needs $roms/intv"
else
	fwdir="$work/firmware"; mkdir -p "$fwdir"
	cp "$roms/intv/exec.bin" "$roms/intv/ro-3-9503-003.u21" "$fwdir/"
	roms_dir="$fwdir"
	intvsettings='{"machine":"intv","config.Controller Disc Emulation":"Digital"}'
	project intv intv "$intvsettings" "$roms/intv/astrosmash.int" "config.Controller Disc Emulation=Digital"
	if in_window intv "$work/config.base.ini" INTV ""; then
		report "window:refusal" FAIL "the project opened without its firmware"
	elif grep -q -e "exec.bin" -e "ro-3-9503-003.u21" "$work/intv.log"; then
		report "window:refusal" PASS "without the firmware the project is not opened, and a file is named: $(grep -o -m1 '[^.]*\(exec.bin\|ro-3-9503-003.u21\)[^.]*' "$work/intv.log" | head -1 | cut -c1-120)"
	else
		report "window:refusal" FAIL "refused, but no firmware file is named: $(tail -2 "$work/intv.log" | tr '\n' ' ' | cut -c1-200)"
	fi
	rm -f "$work/intv.meta.txt"
	domain="Intellivision/:/0/m_ram16"
	"$runner" --project "$work/intv/intv.chimeraProject" "$package" --files "$work/intv" \
		--firmware "exec.bin=$fwdir/exec.bin" --firmware "ro-3-9503-003.u21=$fwdir/ro-3-9503-003.u21" \
		--dump "$domain=$work/intv.engine.bin" > "$work/intv.engine.log" 2>&1
	python3 "$here/settings-config.py" "$config" "$work/config.fw.ini" '{}' \
		"{\"exec.bin\": \"$fwdir/exec.bin\", \"ro-3-9503-003.u21\": \"$fwdir/ro-3-9503-003.u21\"}"
	if ! in_window intv "$work/config.fw.ini" INTV "$domain"; then
		report "window:firmware" FAIL "Chimera did not finish the run: $(value intv detail) $(tail -2 "$work/intv.log" | tr '\n' ' ' | cut -c1-200)"
	elif [ -s "$work/intv.engine.bin" ] && cmp -s "$work/intv.engine.bin" "$work/intv.ram.bin"; then
		report "window:firmware" PASS "Astrosmash opened with the firmware from Chimera's configuration: after $frames frames its RAM ($(wc -c < "$work/intv.ram.bin") bytes) is what the headless runner leaves"
	else
		report "window:firmware" FAIL "the memory differs from the headless runner's (or one of the two is missing)"
	fi
fi

echo
echo "$ok passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
