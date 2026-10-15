#!/usr/bin/env python3
"""Prints the test harness's --press options that type a text on an Amstrad
CPC's keyboard, for the core's tests.

usage: type-keys.py <panel listing> <first frame> <text>

<panel listing> is the harness's --list-panel output for the machine. A
letter is its key, a capital letter or a character on a key's second place
(" on 2) is Shift with it, "\\n" is Return, and the names of the core's own
controls in braces ({Next Disk}) press them. Each key is held 4 frames, and
the next starts 8 frames after it.
"""
import re
import sys


def main():
    panel, first, text = sys.argv[1], int(sys.argv[2]), sys.argv[3].replace("\\n", "\n")
    index = {}
    for line in open(panel):
        m = re.match(r"panel (\d+) '(.*)' ", line)
        if m:
            index[m.group(2)] = int(m.group(1))
    # each character: the key, and whether Shift goes with it
    plain, shifted = {}, {}
    for name in index:
        parts = name.split(" ")
        if len(name) == 1 and name.isalpha():
            plain[name.lower()] = name
            shifted[name] = name
        elif len(parts) >= 2 and all(len(p) == 1 for p in parts):
            plain.setdefault(parts[0], name)
            shifted.setdefault(parts[1], name)
    plain.update({" ": "Space", "\n": "Return"})
    out, frame = [], first
    for token in re.findall(r"\{[^}]*\}|.", text, re.S):
        keys = []
        if token.startswith("{"):
            keys = [token[1:-1]]
        elif token in plain:
            keys = [plain[token]]
        elif token in shifted:
            keys = ["Shift", shifted[token]]
        else:
            sys.exit("no key types %r" % token)
        for k in keys:
            if k not in index:
                sys.exit("the panel has no control %r" % k)
            out.append("--press %d:%d:4" % (index[k], frame))
        frame += 8
    print(" ".join(out))


if __name__ == "__main__":
    main()
