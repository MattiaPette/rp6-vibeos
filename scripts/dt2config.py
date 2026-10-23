#!/usr/bin/env python3
"""Print the Kconfig symbols for the drivers an RP6 device tree actually uses.

Usage: dt2config.py <kernel-src> <decompiled.dts>

Walks every enabled node of the decompiled DTB, finds the C file in the kernel
tree that matches its compatible string, and maps that file to the Kconfig
symbol in its directory's Makefile. Everything is printed as built in (=y) so
the rootfs can be mounted without an initramfs; kernel/rp6.config turns the
drivers that load firmware at probe back into modules. Nodes with no matching
driver go to stderr so they can be checked by hand.
"""
import os
import re
import subprocess
import sys

src, dts = sys.argv[1], sys.argv[2]


def enabled_compatibles(path):
    """Return the compatible lists of nodes that are not disabled (nor under a disabled parent)."""
    out = []
    stack = []  # one dict per open node
    for line in open(path):
        line = line.strip()
        if line.endswith("{"):
            stack.append({"compat": [], "disabled": bool(stack) and stack[-1]["disabled"]})
        elif line == "};" and stack:
            node = stack.pop()
            if not node["disabled"] and node["compat"]:
                out.append(tuple(node["compat"]))
        elif stack and line.startswith("compatible ="):
            # dtc prints string lists either as "a", "b" or as "a\0b"
            stack[-1]["compat"] = [c for s in re.findall(r'"([^"]+)"', line)
                                   for c in s.split("\\0") if c]
        elif stack and re.match(r'status = "(disabled|fail)', line):
            stack[-1]["disabled"] = True
    return sorted(set(out))


def files_for(compat):
    """C files that list compat in an of_device_id table, not just mention it."""
    res = subprocess.run(
        ["git", "-C", src, "grep", "-n", "-F", f'"{compat}"', "--",
         "drivers", "sound", "arch/arm64"],
        capture_output=True, text=True)
    files = set()
    for hit in res.stdout.splitlines():
        path, _, text = hit.split(":", 2)
        if path.endswith(".c") and ".compatible" in text:
            files.add(path)
    return sorted(files)


def symbol_for(cfile):
    d, base = os.path.split(cfile)
    obj = base[:-2] + ".o"
    try:
        mk = open(os.path.join(src, d, "Makefile")).read().replace("\\\n", " ")
    except FileNotFoundError:
        return None
    for line in mk.splitlines():
        m = re.match(r"\s*obj-\$\((CONFIG_\w+)\)\s*[+:]?=(.*)", line)
        if m and obj in m.group(2).split():
            return m.group(1)
    # Composite objects: foo-y += bar.o, then obj-$(CONFIG_X) += foo.o
    for line in mk.splitlines():
        m = re.match(r"\s*([\w-]+)-(?:y|objs|\$\(CONFIG_\w+\))\s*[+:]?=(.*)", line)
        if m and obj in m.group(2).split():
            return symbol_for(os.path.join(d, m.group(1) + ".c"))
    return None


# Matched by core code or bindings only; drivers that also list them (e.g. the
# i.MX and TI bus drivers for "simple-bus") are not wanted.
GENERIC = {"simple-bus", "simple-pm-bus", "simple-mfd", "syscon", "cache",
           "operating-points-v2", "domain-idle-state"}

symbols = set()
for compats in enabled_compatibles(dts):
    if GENERIC.intersection(compats):
        continue
    found = {s for c in compats for s in (symbol_for(f) for f in files_for(c)) if s}
    if not found:
        print("unresolved: " + " ".join(compats), file=sys.stderr)
    symbols |= found

for s in sorted(symbols):
    print(f"{s}=y")
