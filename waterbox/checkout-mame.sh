#!/bin/sh
# Checks out the part of MAME this core builds - waterbox/mame-sparse.txt -
# at the commit extern/mame is pinned to: a blobless, sparse, depth-1 clone.
# A full `git submodule update --init extern/mame` works as well; this leaves
# out the software lists of the home systems and the desktop renderer, about
# half of MAME's tree.
#
# Usage: waterbox/checkout-mame.sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dir="$root/extern/mame"
pin="$(git -C "$root" ls-files -s extern/mame | awk '{print $2}')"
url="$(git -C "$root" config -f .gitmodules submodule.extern/mame.url)"
if [ -e "$dir/.git" ]; then
	have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
	[ "$have" = "$pin" ] && { echo "extern/mame is at $pin"; exit 0; }
	echo "extern/mame is checked out at ${have:-nothing}, not the pinned $pin" >&2
	exit 1
fi
mkdir -p "$dir"
git -C "$dir" init -q
git -C "$dir" remote add origin "$url"
grep -v '^#' "$here/mame-sparse.txt" | git -C "$dir" sparse-checkout set --no-cone --stdin
git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$pin"
git -C "$dir" checkout -q FETCH_HEAD
echo "extern/mame: $pin, sparse ($(du -sh --exclude=.git "$dir" | cut -f1))"
