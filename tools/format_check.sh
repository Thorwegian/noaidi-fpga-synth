#!/bin/sh
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# The format check, as one implementation. `make format-check` runs it, and so
# does the ESP-IDF build ahead of the main component's compilation
# (app/main/CMakeLists.txt), because `make fw`'s prerequisite is only one of
# the doors into a firmware build: `tools/esp_idf.sh idf.py build` has no
# Makefile in it (#613). `--write` reformats instead of failing, which is what
# `make format` does.
#
# .clang-format is written for clang-format 18, the clang-format-18 system
# package (README.md, External dependencies); another major version formats
# some constructs differently, so the check names the version it requires.
set -eu

clang_format=${CLANG_FORMAT:-clang-format-18}
version=18
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Our own C and C++ sources; the libraries in app/lib keep their style.
sources() {
    git ls-files '*.c' '*.h' '*.cpp' '*.hpp' | grep -v '^app/lib/'
}

if [ "${1:-}" = "--write" ]; then
    sources | xargs "$clang_format" -i
    exit 0
fi

command -v "$clang_format" >/dev/null 2>&1 || {
    echo "FAIL $clang_format not found: apt install clang-format-$version" >&2
    exit 1
}
"$clang_format" --version | grep -q " version $version\." || {
    echo "FAIL $clang_format is not clang-format $version" >&2
    exit 1
}

# One invocation, since the check runs on every build; a violation reads
# "path:line:col: error: code should be clang-formatted".
# shellcheck disable=SC2046
if ! report=$("$clang_format" --dry-run --Werror $(sources) 2>&1); then
    echo "FAIL not formatted (make format):" >&2
    echo "$report" | sed -n 's/^\([^:]*\):[0-9].*/  \1/p' | sort -u >&2
    exit 1
fi
