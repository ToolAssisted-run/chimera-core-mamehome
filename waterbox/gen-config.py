#!/usr/bin/env python3
"""Writes the package's declarations from MAME itself: waterbox.config (what
Chimera is told) and default_keybinds.json.

`run-native <any folder> --walk` describes every machine of the build without
running it: its controls (named by the core's own rule, mame-driver.cpp), its
firmware files, its BIOS choices, its switches and its media devices. This
script keeps the machines machines.txt lists and writes, for each, a machine
entry (the system it is, its controls with their movie letters, the
extensions that are its), the settings (the machine, its BIOS, its switches)
and the firmware it needs. So the package is exact for the MAME commit the
core is pinned to, and is written again when the pin moves. run-gate.sh
checks the core's controls against what this wrote. What every machine
shares (picture, sound, memory) is waterbox.template.json.

usage: waterbox/gen-config.py <walk output> [OUTDIR]
       (default OUTDIR: beside this script)
"""
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


# ---- the machines ------------------------------------------------------------
def read_machines(path):
    out = []
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, system, label = line.split(None, 2)
        out.append((name, system, label))
    return out


def read_walk(path):
    machines = {}
    cur = None
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        kind, _, rest = line.partition(" ")
        f = rest.split("\t")
        if kind == "machine":
            cur = {"name": f[0], "title": f[1], "year": f[2], "maker": f[3], "parent": f[4], "status": f[5],
                   "bios": [], "files": [], "media": [], "switches": [], "buttons": [], "axes": []}
            machines[f[0]] = cur
        elif kind == "bios":
            cur["bios"].append({"name": f[0], "description": f[1], "default": f[2] == "1"})
        elif kind == "file":
            cur["files"].append({"name": f[0], "size": int(f[1]), "sha1": f[2].upper(), "crc": f[3], "set": f[4],
                                 "bios": None if f[5] == "-" else f[5], "required": f[6] == "1"})
        elif kind == "media":
            cur["media"].append({"option": f[0], "extensions": f[1].split(","), "required": f[2] == "1"})
        elif kind == "switch":
            cur["switches"].append({"kind": f[0], "name": f[1], "default": f[2], "options": f[3].split("|")})
        elif kind == "button":
            cur["buttons"].append(rest)
        elif kind == "axis":
            cur["axes"].append({"name": f[0], "min": int(f[1]), "max": int(f[2]), "relative": f[3] == "1"})
        elif kind == "failed":
            sys.exit("the walk could not describe " + rest)
    return machines


# ---- movie letters -----------------------------------------------------------
# A control's letter is the one character it writes into a movie. Declared by
# the name without the player ("Up" for P1 Up and P2 Up), and never twice in
# one player's controls while there are letters left.
PREFERRED = {
    "Up": "U", "Down": "D", "Left": "L", "Right": "R",
    "Button 1": "1", "Button 2": "2", "Button 3": "3", "Button 4": "4", "Button 5": "5", "Button 6": "6",
    "Reset": "r", "Select": "s", "Pause": "p", "Start": "S",
    "Upper": "T", "Lower-Left": "l", "Lower-Right": "g", "Clear": "C", "Enter": "E",
    "Push Down": "v", "Pull Up": "^", "Twist Clockwise": ">", "Twist Counterclockwise": "<",
    "Up-Up-Left": "a", "Up-Left": "b", "Left-Up-Left": "c", "Left-Down-Left": "d", "Down-Left": "e",
    "Down-Down-Left": "f", "Down-Down-Right": "h", "Down-Right": "i", "Right-Down-Right": "j",
    "Right-Up-Right": "k", "Up-Right": "m", "Up-Up-Right": "n",
    "Previous Disk": "{", "Next Disk": "}", "Eject Disk": "~",
}
POOL = [chr(c) for c in range(0x21, 0x7f) if chr(c) not in ".|"]


def bare(name):
    m = re.match(r"^P(\d+) (.+)$", name)
    return m.group(2) if m else name


def player_of(name):
    m = re.match(r"^(P\d+) ", name)
    return m.group(1) if m else "console"


def letters(buttons):
    """{declared key: letter}: by the bare name where every player can share
    it, by the whole name where a clash forces it."""
    groups = collections.OrderedDict()
    for b in buttons:
        groups.setdefault(player_of(b), []).append(b)
    declared = {}

    def candidates(name):
        b = bare(name)
        if b in PREFERRED:
            yield PREFERRED[b]
        for ch in re.findall(r"[A-Za-z0-9]", b):
            yield ch
            yield ch.swapcase()
        yield from POOL

    for g, names in groups.items():
        used = set()
        for name in names:
            key = bare(name)
            if key in declared and declared[key] not in used:
                used.add(declared[key])
                continue
            k = key if key not in declared else name
            for ch in candidates(name):
                if ch not in used:
                    declared[k] = ch
                    used.add(ch)
                    break
            else:
                # more keys than letters: Chimera's checks allow repeats past 40
                declared[k] = next(candidates(name))
    return declared


def axis_header(name):
    m = re.match(r"^P(\d+) (.+)$", name)
    words = re.findall(r"[A-Za-z0-9]+", m.group(2) if m else name)
    head = "".join(w if w.isdigit() else w[0].upper() for w in words)
    return (("P" + m.group(1)) if m else "") + head[:5]


# ---- default key bindings ----------------------------------------------------
PAD = {
    "Up": "Up, J{n} POV1U, X{n} DpadUp, X{n} LStickUp",
    "Down": "Down, J{n} POV1D, X{n} DpadDown, X{n} LStickDown",
    "Left": "Left, J{n} POV1L, X{n} DpadLeft, X{n} LStickLeft",
    "Right": "Right, J{n} POV1R, X{n} DpadRight, X{n} LStickRight",
    "Button 1": "Z, J{n} B1, X{n} A", "Button 2": "X, J{n} B2, X{n} B",
    "Button 3": "C, J{n} B3, X{n} X", "Button 4": "V, J{n} B4, X{n} Y",
    "Upper": "Z, J{n} B1, X{n} A", "Lower-Left": "X, J{n} B2, X{n} B", "Lower-Right": "C, J{n} B3, X{n} X",
    "Push Down": "Z, J{n} B1, X{n} A", "Pull Up": "X, J{n} B2, X{n} B",
    "Twist Clockwise": "C, J{n} B3, X{n} RightShoulder", "Twist Counterclockwise": "V, J{n} B4, X{n} LeftShoulder",
}
KEYPAD = {str(d): "Keypad%d" % d for d in range(10)}
KEYPAD.update({"Clear": "KeypadDecimal", "Enter": "KeypadEnter"})
CONSOLE = {"Reset": "F1", "Select": "F2", "Pause": "F3",
           "TIME (Button 1)": "Number1", "HOLD (Button 2)": "Number2", "MODE (Button 3)": "Number3",
           "START (Button 4)": "Number4",
           "Previous Disk": "PageUp", "Next Disk": "PageDown", "Eject Disk": "Insert"}
# a computer's key, by its name, to the PC key in the same place
KEYS = {"Space": "Space", "Return": "Enter", "Enter": "Enter", "Shift": "Shift, LeftShift", "Control": "Ctrl",
        "Esc": "Escape", "Tab": "Tab", "Caps Lock": "CapsLock", "Del": "Backspace", "Clr": "Delete",
        "Copy": "End", "Cursor Up": "Up", "Cursor Down": "Down", "Cursor Left": "Left", "Cursor Right": "Right",
        "Ctrl": "Ctrl", "Alt": "Alt"}


def binding(name, keyboard):
    m = re.match(r"^P(\d+) (.+)$", name)
    n, b = (int(m.group(1)), m.group(2)) if m else (0, name)
    if n:
        if b in PAD:
            text = PAD[b].format(n=n)
            # the keyboard is player 1's alone, and a computer's keys are its own
            if n > 1 or keyboard:
                text = ", ".join(p for p in text.split(", ") if p.startswith(("J", "X")))
            return text
        if n == 1 and b in KEYPAD:
            return KEYPAD[b]
        return ""
    if b in CONSOLE:
        return CONSOLE[b]
    if keyboard:
        # a key MAME names by its characters ("1 !"): by its first
        b = b.split(" ")[0] if b not in KEYS and " " in b and len(b.split(" ")[0]) == 1 else b
        if b in KEYS:
            return KEYS[b]
        if re.fullmatch(r"[A-Z]", b):
            return b
        if re.fullmatch(r"[0-9]", b):
            return "Number" + b
        m = re.fullmatch(r"f([0-9])", b)
        if m:
            return "Keypad" + m.group(1)
    return ""


# ---- firmware ----------------------------------------------------------------
def firmware_entries(chosen, walk):
    """One entry for each firmware file, with the condition it is needed on:
    the machines that read it, and for a BIOS's file, that BIOS."""
    by_file = collections.OrderedDict()
    for name, _, _ in chosen:
        for f in walk[name]["files"]:
            if f["required"]:
                by_file.setdefault((f["name"], f["sha1"]), {"file": f, "uses": []})["uses"].append((name, f["bios"]))
    ids = collections.Counter(k[0] for k in by_file)
    out = []
    for (fname, sha1), entry in by_file.items():
        f = entry["file"]
        plain, rest = [], []
        for machine, bios in entry["uses"]:
            if bios is None:
                plain.append(machine)
                continue
            m = walk[machine]
            desc = {b["name"]: b["description"] for b in m["bios"]}
            default = next(b["name"] for b in m["bios"] if b["default"])
            # a setting left alone has no value to test: the default BIOS is
            # "none of the others"
            if bios == default:
                cond = {"not": {"setting": "bios", "in": [desc[b["name"]] for b in m["bios"] if b["name"] != default]}}
            else:
                cond = {"setting": "bios", "in": [desc[bios]]}
            rest.append({"all": [{"setting": "machine", "in": [machine]}, cond]})
        parts = ([{"setting": "machine", "in": plain}] if plain else []) + rest
        when = parts[0] if len(parts) == 1 else {"any": parts}
        titles = list(dict.fromkeys(walk[machine]["title"] for machine, _ in entry["uses"]))
        owner = f["set"]
        what = ("a ROM of the " + walk[owner]["title"]) if owner in walk else ("the ROM of a chip inside it (MAME's device " + owner + ")")
        size = f["size"]
        size_text = ("%d KB" % (size // 1024)) if size >= 1024 and size % 1024 == 0 else ("%d bytes" % size)
        out.append({
            "id": fname if ids[fname] == 1 else fname + "@" + owner,
            "display": "%s: %s" % (titles[0] if len(titles) == 1 else walk[entry["uses"][0][0]]["title"].split(" (")[0], fname),
            "description": "%s (%s), which MAME names %s. Used by: %s. It is part of the machine, so you supply it, and the core checks it is the right one." % (
                what[0].upper() + what[1:], size_text, fname, ", ".join(titles)),
            "size": size,
            "sha1": sha1,
            "name": fname,
            "requiredWhen": when,
        })
    return out


# the extensions that open a file as this machine with no project, where only
# one system takes them
EXTENSIONS = {
    "a7800": [".a78"], "intv": [".int", ".itv"], "vectrex": [".vec", ".gam"], "channelf": [".chf"],
    "cpc6128": [".dsk", ".cdt", ".sna"], "gx4000": [".cpr"], "ti83": [".83p", ".83g"],
}
# the shape a system's screen was shown in, where it is not 4:3
SHAPE = {"VEC": (480, 640), "TI83": (480, 320)}


def main():
    walk_path = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else HERE
    chosen = read_machines(os.path.join(HERE, "machines.txt"))
    walk = read_walk(walk_path)
    for name, _, _ in chosen:
        if name not in walk:
            sys.exit("the walk has no machine " + name)
    labels = {system: label for _, system, label in chosen}

    machines = []
    keybinds = collections.OrderedDict()
    for name, system, label in chosen:
        m = walk[name]
        for b in m["buttons"] + [a["name"] for a in m["axes"]]:
            if "?" in b or not b.isascii():
                sys.exit("%s: the control '%s' has a character the core could not spell" % (name, b))
        keyboard = len(m["buttons"]) > 40
        input_name = m["title"] + " Controls"
        entry = {
            "id": system,
            "label": m["title"],
            "when": [name],
            "input": {"name": input_name, "buttons": m["buttons"], "mnemonics": letters(m["buttons"])},
        }
        if m["axes"]:
            entry["input"]["axes"] = [{"name": a["name"], "min": a["min"], "max": a["max"], "neutral": 0,
                                       "header": axis_header(a["name"])} for a in m["axes"]]
        entry["virtualWidth"], entry["virtualHeight"] = SHAPE.get(system, (640, 480))
        if name in EXTENSIONS:
            entry["extensions"] = {e: system for e in EXTENSIONS[name]}
        machines.append(entry)
        keybinds[input_name] = collections.OrderedDict((b, binding(b, keyboard)) for b in m["buttons"])

    # the settings: the machine, then each machine's BIOS and switches, one
    # declaration for each different one, with the machines that have it
    systems_text = []
    for system in dict.fromkeys(s for _, s, _ in chosen):
        names = [n for n, s, _ in chosen if s == system]
        systems_text.append("%s: %s" % (labels[system], ", ".join("%s (%s)" % (n, walk[n]["title"]) for n in names)))
    settings = [{
        "name": "machine",
        "display": "Machine",
        "type": "enum",
        "options": [n for n, _, _ in chosen],
        "default": chosen[0][0],
        "description": "Which machine this project is, by MAME's name for it. The choice is saved in the project and recorded in the movie. "
                       + "; ".join(systems_text) + ".",
    }]
    decls = collections.OrderedDict()
    for name, _, _ in chosen:
        m = walk[name]
        if len(m["bios"]) > 1:
            opts = [b["description"] for b in m["bios"]]
            default = next(b["description"] for b in m["bios"] if b["default"])
            decls.setdefault(("bios", tuple(opts), default), {
                "name": "bios", "display": "BIOS", "type": "enum", "options": opts, "default": default,
                "description": "Which of the machine's BIOS versions it starts with. The default is MAME's. A movie needs the same one to play back.",
                "when": []})["when"].append(name)
        for sw in m["switches"]:
            sname = sw["kind"] + "." + sw["name"]
            what = "A switch on the console" if sw["kind"] == "dip" else "A part of the machine's set-up"
            decls.setdefault((sname, tuple(sw["options"]), sw["default"]), {
                "name": sname, "display": sw["name"], "type": "enum", "options": sw["options"], "default": sw["default"],
                "description": "%s, as MAME names it: '%s'. The machine reads it, so a movie needs the same value to play back. The default is MAME's." % (what, sw["name"]),
                "when": []})["when"].append(name)
    settings += list(decls.values())

    config = json.load(open(os.path.join(HERE, "waterbox.template.json")))
    config["systemNames"] = {s: labels[s] for s in dict.fromkeys(s for _, s, _ in chosen)}
    config["settings"] = settings
    config["machineSetting"] = "machine"
    config["machines"] = machines
    config["firmware"] = firmware_entries(chosen, walk)
    with open(os.path.join(outdir, "waterbox.config"), "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=True)
        f.write("\n")
    kb = {"_comment": ["Player 1's joystick on the arrows and Z X C V as well as the first pad, player 2's on the second pad; "
                       "the Intellivision's keypad on the number pad; console switches on F1-F3 (Channel F: 1-4); a computer's keys "
                       "on the PC keys in the same place and its joysticks on the pads only. Everything else ships unbound."],
          "AllTrollers": keybinds}
    with open(os.path.join(outdir, "default_keybinds.json"), "w") as f:
        json.dump(kb, f, indent=1, ensure_ascii=True)
        f.write("\n")
    print("machines %d, settings %d, firmware %d" % (len(machines), len(settings), len(config["firmware"])))


if __name__ == "__main__":
    main()
