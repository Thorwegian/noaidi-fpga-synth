#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Unused-function gate of the firmware's sources.

ESP-IDF compiles every function into a section of its own and links with
--gc-sections, so a function that no linked code references is dropped
without a word. This gate names every such function of the main component,
oldest first, each with the day its definition line last changed.

    unused_functions.py --firmware <build folder> --host-tool <executable>

`make fw` runs it as its last step, so its lines are the last on the screen.
It warns and does not fail: a function may be new and waiting for its
caller. One that has stood for weeks is the reader's to deal with.

A function is unused when the main component's archive defines it as a
strong global symbol in a text section (nm's T) and neither the linked
firmware nor the host tool has it. The host tool is a program of its own
that shares sources with the firmware, so its link counts; for that it is
linked with -g and --gc-sections (the Makefile's HOST_LINK_JUDGES). A host
test's link does not count. Two kinds of function land here:

  - one that nothing calls, a host test aside;
  - one that only its own file calls, with every call inlined: it wants
    internal linkage (static, or an anonymous namespace).

The firmware is asked by symbol name. The host tool is asked by source line:
it is compiled for another machine, where the same function's symbol differs
(size_t is unsigned int on the ESP32-S3 and unsigned long on a 64-bit host).

Not seen from here: an unused inline function, template or method defined
inside its class. The compiler emits nothing for an unused one, and a used
one whose every call is inlined leaves no symbol either, so the absence of
a weak symbol (nm's W) says nothing. Nor an unused static function: the
compiler drops it, and warns (-Wunused-function) when it compiles the file.

Exit 0 = the gate ran, with or without warnings. Exit 1 = it could not.
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys

# nm -l: "00000000 T _ZN6cc_map4dumpEv\t/path/to/cc_map.cpp:424"
DEFINITION = re.compile(r"^[0-9a-f]+ (?P<kind>\S) (?P<name>.+?)(?:\t(?P<file>.+):(?P<line>\d+))?$")
AUTHOR_TIME = re.compile(r"^author-time (\d+)$", re.MULTILINE)
REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


def definitions(nm, *arguments):
    """-> one match of DEFINITION for every symbol an nm run defines."""
    command = [nm, "--defined-only", *arguments]
    lines = subprocess.run(command, check=True, capture_output=True, text=True).stdout.splitlines()
    found = []
    for line in lines:
        if not line or line.endswith(":"):  # an archive's members are headed "name.obj:"
            continue
        definition = DEFINITION.match(line)
        if definition is None:
            sys.exit(f"unused_functions: {' '.join(command)} printed a line that is no symbol: {line!r}")
        found.append(definition)
    return found


def functions(nm, binary):
    """-> [(mangled name, readable name, source file, line)] of a binary's
    strong global functions that have a source line."""
    mangled = definitions(nm, "--extern-only", "--line-numbers", str(binary))
    readable = definitions(nm, "--extern-only", "--line-numbers", "--demangle", str(binary))
    return [(definition["name"], readable_definition["name"],
             (REPOSITORY / definition["file"]).resolve(), int(definition["line"]))
            for definition, readable_definition in zip(mangled, readable, strict=True)
            if definition["kind"] == "T" and definition["file"] is not None]


def last_change(source, line):
    """-> the day the line last changed, by git blame."""
    command = ["git", "-C", str(REPOSITORY), "blame", "--porcelain", "-L", f"{line},{line}", "--", str(source)]
    blame = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    author_time = AUTHOR_TIME.search(blame)
    if author_time is None:
        sys.exit(f"unused_functions: {' '.join(command)} gave no author-time")
    return datetime.date.fromtimestamp(int(author_time[1]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", required=True, type=pathlib.Path,
                        help="the firmware's build folder (app/build)")
    parser.add_argument("--host-tool", required=True, type=pathlib.Path,
                        help="the host tool's executable, linked with -g and --gc-sections")
    arguments = parser.parse_args()

    project = json.loads((arguments.firmware / "project_description.json").read_text())
    component = project["build_component_info"]["main"]
    sources = pathlib.Path(component["dir"]).resolve()
    firmware_nm = str(pathlib.Path(project["c_compiler"]).with_name(project["monitor_toolprefix"] + "nm"))

    ours = [function for function in functions(firmware_nm, component["file"])
            if function[2].is_relative_to(sources)]
    if not ours:
        sys.exit(f"unused_functions: {component['file']} names no function with a source line under"
                 f" {sources}: the gate needs the build's debug information")
    in_firmware = {definition["name"]
                   for definition in definitions(firmware_nm, str(arguments.firmware / project["app_elf"]))}
    in_host_tool = {(source, line) for _, _, source, line in functions("nm", arguments.host_tool)}

    today = datetime.date.today()
    unused = sorted((last_change(source, line), source, line, readable)
                    for name, readable, source, line in ours
                    if name not in in_firmware and (source, line) not in in_host_tool)
    for changed, source, line, readable in unused:
        days = (today - changed).days
        print(f"WARN {source.relative_to(REPOSITORY)}:{line}: {readable} is neither used in the firmware"
              f" nor the host tool (unchanged since {changed}, {days} day{'s' if days != 1 else ''})")
    if unused:
        print(f"WARN {len(unused)} unused function(s), oldest first: remove each, or give it internal"
              " linkage if its own file is its only caller")
    return 0


if __name__ == "__main__":
    sys.exit(main())
