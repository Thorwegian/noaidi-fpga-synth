#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""What `make sim` covers, checked rather than assumed (issue #376).

Reads the commands `make -n -B` prints for the bench targets on stdin (the
verilator lines, one per bench, with their source lists) and checks three
invariants against the tree, from rtl/:

  1. every RTL source outside tb/ is handed to Verilator by some bench;
  2. every file under tb/ is built by some bench;
  3. every output port of a module a bench instantiates is read by at least
     one bench (a pin left empty, `.pin()`, in every bench that instantiates
     the module is an output nobody checks).

The third runs Verilator's `--json-only` on each bench's own source list and
reads the elaborated tree: each cell's module and which of its pins carry
an expression, each module's ports and their direction. Only cells placed
in a bench file count as a bench reading a pin; the RTL's own instances are
the RTL reading itself.

Prints one line per gap, `FAIL: ...`, and `ALL PASS` when there is none;
the exit status says the same. Run by `make sim-coverage` (rtl/Makefile).
"""
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


def bench_commands(text):
    """The verilator commands in make's dry run: {top: [source paths]}."""
    benches = {}
    for line in text.replace("\\\n", " ").splitlines():
        if "verilator" not in line:
            continue
        for part in line.split("&&"):
            try:
                words = shlex.split(part.strip())
            except ValueError:
                words = part.split()
            if not words or Path(words[0]).name != "verilator":
                continue
            top = words[words.index("--top-module") + 1]
            benches[top] = [w for w in words[1:] if w.endswith(".sv")]
    return benches


def elaborate(top, sources, work):
    """Verilator's tree for one bench: (module name by address, cells, files)."""
    out = Path(work) / top
    cmd = ["verilator", "--json-only", "--timing", "-I.", "-Wno-lint", "-Wno-style", "-Wno-fatal",
           "--top-module", top, "--Mdir", str(out)] + sources
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode != 0:
        return None, done.stderr
    tree = json.load(open(out / f"V{top}.tree.json"))
    meta = json.load(open(out / f"V{top}.tree.meta.json"))
    files = {key: value["filename"] for key, value in meta["files"].items()}
    modules, cells = {}, []

    def walk(node, module):
        if isinstance(node, dict):
            kind = node.get("type")
            if kind in ("FUNC", "TASK"):
                return                      # a function's return value is an OUTPUT var, not a port
            if kind == "MODULE":
                module = node
                # a parameterised module elaborates under a suffixed name; the port list is the original's
                modules[node["addr"]] = {"name": node.get("origName", node["name"]), "outputs": set()}
            elif kind == "VAR" and module is not None and node.get("direction") == "OUTPUT":
                modules[module["addr"]]["outputs"].add(node["name"])
            elif kind == "CELL":
                cells.append({
                    "file": files.get(node["loc"].split(",")[0], "?"),
                    "modp": node["modp"],
                    "connected": {pin["name"] for pin in node.get("pinsp", []) if pin.get("exprp")},
                })
            for value in node.values():
                if isinstance(value, (dict, list)):
                    walk(value, module)
        elif isinstance(node, list):
            for item in node:
                walk(item, module)

    walk(tree, None)
    return (modules, cells), None


def main():
    benches = bench_commands(sys.stdin.read())
    if not benches:
        print("FAIL: no verilator command on stdin (run from rtl/Makefile: make -n -B <benches>)")
        return 1
    failures = []
    covered = {Path(source) for sources in benches.values() for source in sources}

    rtl = sorted(path for path in Path(".").rglob("*.sv") if path.parts[0] != "tb")
    for source in rtl:
        if source not in covered:
            failures.append(f"FAIL: {source} is handed to Verilator by no bench")

    tb = sorted(Path("tb").rglob("*.sv"))
    for source in tb:
        if source not in covered:
            failures.append(f"FAIL: {source} is built by no sim target")

    outputs_by_module = {}      # module -> set of output ports
    read_by_module = {}         # module -> set of outputs some bench connects
    with tempfile.TemporaryDirectory(prefix="bench_coverage.") as work:
        for top, sources in sorted(benches.items()):
            result, error = elaborate(top, sources, work)
            if result is None:
                failures.append(f"FAIL: {top} does not elaborate for the port audit: {error.strip().splitlines()[-1]}")
                continue
            modules, cells = result
            for cell in cells:
                if not cell["file"].startswith("tb/"):
                    continue
                module = modules[cell["modp"]]
                outputs_by_module.setdefault(module["name"], set()).update(module["outputs"])
                read_by_module.setdefault(module["name"], set()).update(cell["connected"] & module["outputs"])
    for module in sorted(outputs_by_module):
        for port in sorted(outputs_by_module[module] - read_by_module.get(module, set())):
            failures.append(f"FAIL: {module}.{port} is read by no bench")

    print(f"{len(benches)} benches, {len(rtl)} RTL sources, {len(tb)} files under tb/, "
          f"{len(outputs_by_module)} modules instantiated by a bench, "
          f"{sum(len(ports) for ports in outputs_by_module.values())} output ports")
    for line in failures:
        print(line)
    print("ALL PASS" if not failures else f"{len(failures)} FAILURE(S)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
