#!/bin/sh
# Prints the compiler and flags MAME's own build compiles a driver file with,
# for one flavor (native|guest), with the source, the output and the
# dependency flags taken out: this core's own sources are built with exactly
# what the MAME code they include was built with, so the two can never
# disagree about a define or a header.
#
# Usage: waterbox/mame-flags.sh native|guest   (after build-mame.sh)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
flavor="${1:?native or guest}"
name="mame-$flavor"
sub="home"
proj="$root/build/$name/projects/sdl/mame$sub/gmake-linux"
# the first driver file of the build: MAME groups them in a project a maker
first="$(head -1 "$root/build/$name/$sub.flt")"
maker="${first%%/*}"
file="$(basename "$first")"
[ -f "$proj/$maker.make" ] || { echo "run waterbox/build-mame.sh $flavor first" >&2; exit 1; }
cd "$proj"
obj="$(make -f "$maker.make" config=release64 -p -n 2>/dev/null | sed -n 's/^OBJDIR = //p' | head -1)/extern/mame/src/mame/${first%.cpp}.o"
cmd="$(make -f "$maker.make" config=release64 -n -B "$obj" 2>/dev/null | grep -- ' -c ' | grep "$file" | head -1)"
[ -n "$cmd" ] || { echo "could not find how MAME compiles $first in $proj" >&2; exit 1; }
# relative include paths are relative to the project directory: make them absolute
printf '%s\n' "$cmd" | python3 -c '
import os, shlex, sys
proj, file = sys.argv[1], sys.argv[2]
args = shlex.split(sys.stdin.read())
out, skip = [], False
for i, a in enumerate(args):
    if skip:
        skip = False
        continue
    if a in ("-o", "-MF", "-MT", "-MQ"):
        skip = True
        continue
    if a in ("-c", "-MMD", "-MP", "-MD") or a.endswith("/" + file):
        continue
    if a.startswith("-I") and not a.startswith("-I/"):
        a = "-I" + os.path.normpath(os.path.join(proj, a[2:]))
    out.append(a)
print(" ".join(shlex.quote(a) for a in out))
' "$proj" "$file"
