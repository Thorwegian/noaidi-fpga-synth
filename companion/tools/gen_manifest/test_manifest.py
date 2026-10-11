#!/usr/bin/env python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
"""test_manifest.py -- check the generated parameter manifest as the app reads it.

gen_manifest checks that every value it writes loads back through the
firmware's conversions. This checks the manifest's own consistency, the
things the app relies on:

- IDs are unique and agree with their file location (table, index, key);
- a dependency names an earlier parameter, and a name dependency has one
  byValue entry per name;
- names: the default is one of the names;
- numbers: min <= max; the default lies in the range or is a special value;
  values ascend, lie in the range, end at the range ends, and number
  valueCount (less the special values).

    python3 tools/gen_manifest/test_manifest.py src/generated/parameters.json
"""
import json
import re
import sys

ID_RE = re.compile(r"^([a-z_]+)(?:\[(\d+)\])?\.([a-z_]+)$")


def check_values(where, spec, errors):
    lo, hi = spec["range"]["min"], spec["range"]["max"]
    if lo > hi:
        errors.append(f"{where}: range min {lo} > max {hi}")
    values = spec.get("values")
    if values is None:
        return
    special = len(spec.get("special", []))
    if len(values) != spec["valueCount"] - special:
        errors.append(f"{where}: {len(values)} values, valueCount {spec['valueCount']}")
    if values != sorted(values) or len(set(values)) != len(values):
        errors.append(f"{where}: values not strictly ascending")
    if values and (values[0] != lo or values[-1] != hi):
        errors.append(f"{where}: values end at {values[0]}..{values[-1]}, range {lo}..{hi}")


def main(path):
    manifest = json.load(open(path, encoding="utf-8"))
    errors = []
    if not isinstance(manifest.get("patchFileFormat"), int):
        errors.append("patchFileFormat missing")
    seen = {}
    for p in manifest["parameters"]:
        pid = p["id"]
        m = ID_RE.match(pid)
        if not m:
            errors.append(f"{pid}: malformed ID")
            continue
        table, index, key = m.group(1), m.group(2), m.group(3)
        loc = p["file"]
        if (loc["table"], loc.get("index"), loc["key"]) != \
                (table, int(index) if index is not None else None, key):
            errors.append(f"{pid}: file location {loc} disagrees with the ID")
        if pid in seen:
            errors.append(f"{pid}: duplicate ID")

        if p["kind"] == "name":
            if p["default"] not in p["names"]:
                errors.append(f"{pid}: default {p['default']!r} is not a name")
        elif p["kind"] == "number":
            check_values(pid, p, errors)
            d, special = p["default"], p.get("special", [])
            if isinstance(d, str):
                if d not in special:
                    errors.append(f"{pid}: default {d!r} is not a special value")
            elif not p["range"]["min"] <= d <= p["range"]["max"]:
                errors.append(f"{pid}: default {d} outside the range")
            if p.get("integer") and not isinstance(d, str) and d != int(d):
                errors.append(f"{pid}: integer key with default {d}")
        else:
            errors.append(f"{pid}: unknown kind {p['kind']!r}")

        dep = p.get("dependsOn")
        if dep is not None:
            if dep not in seen:
                errors.append(f"{pid}: depends on {dep}, which is not an earlier parameter")
            elif "byValue" in p:
                if sorted(p["byValue"]) != sorted(seen[dep].get("names", [])):
                    errors.append(f"{pid}: byValue keys differ from {dep}'s names")
                for name, spec in p["byValue"].items():
                    check_values(f"{pid} ({dep} = {name})", spec, errors)
                    if not p["range"]["min"] <= spec["range"]["min"] <= spec["range"]["max"] <= p["range"]["max"]:
                        errors.append(f"{pid} ({name}): range outside the union range")
        seen[pid] = p

    for e in errors:
        print(f"test_manifest: {e}", file=sys.stderr)
    print(f"test_manifest: {len(seen)} parameters, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
