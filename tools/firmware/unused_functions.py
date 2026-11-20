#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Unused-function gate of the firmware's link.

ESP-IDF compiles every function into a section of its own and links with
--gc-sections, so a function that no linked code references is dropped
without a word. This gate names every such function of our own sources
and fails the build.

    unused_functions.py --nm <nm> --elf <firmware.elf> --sources <dir> <object>...

The firmware's build runs it after every link (app/CMakeLists.txt).

A function is unused when an object defines it as a strong global symbol
in a text section (nm's T), its source is under --sources, and the linked
firmware has no symbol of that name. Two kinds of function land there:

  - one that nothing calls, a host test or a host tool aside: the
    firmware's link does not see those, so the function is not the
    firmware's;
  - one that only its own file calls, with every call inlined: it wants
    internal linkage (static, or an anonymous namespace).

Not seen from here: an unused inline function, template or method defined
inside its class. The compiler emits nothing for an unused one, and a used
one whose every call is inlined leaves no symbol either, so the absence of
a weak symbol (nm's W) says nothing.

Exit 0 = every function is linked. Exit 1 = at least one is not.
"""
import argparse
import pathlib
import re
import subprocess
import sys

# nm -l: "00000000 T _ZN6cc_map4dumpEv\t/path/to/cc_map.cpp:424"
DEFINITION = re.compile(r"^[0-9a-f]+ (?P<kind>\S) (?P<name>.+?)(?:\t(?P<file>.+):(?P<line>\d+))?$")
REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


def definitions(tool, *arguments):
    """-> one match of DEFINITION for every symbol an nm run defines."""
    command = [tool, "--defined-only", *arguments]
    lines = subprocess.run(command, check=True, capture_output=True, text=True).stdout.splitlines()
    found = []
    for line in lines:
        definition = DEFINITION.match(line)
        if definition is None:
            sys.exit(f"unused_functions: {' '.join(command)} printed a line that is no symbol: {line!r}")
        found.append(definition)
    return found


def functions(tool, object_file):
    """-> [(mangled name, readable name, source file, line)] of an object's strong global functions."""
    mangled = definitions(tool, "--extern-only", "--line-numbers", object_file)
    readable = definitions(tool, "--extern-only", "--line-numbers", "--demangle", object_file)
    found = []
    for definition, readable_definition in zip(mangled, readable, strict=True):
        if definition["kind"] != "T":
            continue
        if definition["file"] is None:
            sys.exit(f"unused_functions: {object_file} has no source line for {definition['name']}:"
                     " the gate needs the build's debug information")
        found.append((definition["name"], readable_definition["name"],
                      pathlib.Path(definition["file"]).resolve(), int(definition["line"])))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nm", required=True, help="the toolchain's nm")
    parser.add_argument("--elf", required=True, help="the linked firmware")
    parser.add_argument("--sources", required=True, type=pathlib.Path,
                        help="the folder of our own sources; functions from elsewhere are passed over")
    parser.add_argument("objects", nargs="+", help="the object files the firmware links")
    arguments = parser.parse_args()

    sources = arguments.sources.resolve()
    linked = {definition["name"] for definition in definitions(arguments.nm, arguments.elf)}
    unused = sorted((source, line, readable)
                    for object_file in arguments.objects
                    for name, readable, source, line in functions(arguments.nm, object_file)
                    if source.is_relative_to(sources) and name not in linked)

    for source, line, readable in unused:
        print(f"FAIL {source.relative_to(REPOSITORY)}:{line}: {readable} is not in the firmware")
    if unused:
        print(f"FAIL {len(unused)} unused function(s): remove each, or give it internal linkage"
              " if its own file is its only caller")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
