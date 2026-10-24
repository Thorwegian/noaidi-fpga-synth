#!/usr/bin/env bash
# esp_idf.sh -- run a command with ESP-IDF activated, finding ESP-IDF itself.
#
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# The firmware targets (make fw, fw-flash, fw-monitor) run idf.py through this
# script, and so can anyone: nobody sources export.sh by hand, and nothing of
# the activation leaks into the caller's shell.
#
#     tools/esp_idf.sh idf.py build              any command, with ESP-IDF on the PATH
#     tools/esp_idf.sh idf.py -p /dev/ttyACM0 monitor
#     tools/esp_idf.sh --where                   which ESP-IDF, and how it was found
#     tools/esp_idf.sh --shell                   an interactive shell with it activated
#
# ESP-IDF is found in this order (README.md "External dependencies"):
#   1. idf.py already on the PATH -- the shell is activated; nothing to do
#   2. the newest activation script of an Espressif Installation Manager
#      install, under $IDF_TOOLS_PATH or ~/.espressif/tools (activate_idf_*.sh)
#   3. $IDF_PATH/export.sh
#   4. the newest classic checkout: ~/.espressif/v*/esp-idf, then ~/esp/esp-idf*
# The activation script is sourced in a subshell named bash: the scripts tell
# "sourced" from "executed" by $0 being a shell's name, and exit silently
# otherwise. With no ESP-IDF found, the script says so and exits 1.
set -u

# The last of the existing files among the arguments: a sorted glob's newest
# version (bash sorts globs, so v6.0.2 follows v5.4).
newest() {
    local file last=""
    for file in "$@"; do
        [ -f "$file" ] && last="$file"
    done
    echo "$last"
}

# The activation script to source, or nothing with idf.py already on the PATH.
find_activation() {
    local candidate
    for candidate in \
        "$(newest "${IDF_TOOLS_PATH:-/nonexistent}"/activate_idf_*.sh)" \
        "$(newest "${HOME}"/.espressif/tools/activate_idf_*.sh)" \
        "${IDF_PATH:+${IDF_PATH}/export.sh}" \
        "$(newest "${HOME}"/.espressif/v*/esp-idf/export.sh)" \
        "$(newest "${HOME}"/esp/esp-idf*/export.sh)"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

usage() {
    echo "usage: tools/esp_idf.sh <command...> | --where | --shell" >&2
    exit 2
}

[ $# -eq 0 ] && usage

if command -v idf.py >/dev/null 2>&1; then
    case "$1" in
        --where) echo "idf.py on the PATH already: $(command -v idf.py)"; exit 0 ;;
        --shell) exec "${SHELL:-bash}" ;;
        *)       exec "$@" ;;
    esac
fi

ACTIVATE="$(find_activation)" || {
    echo "esp_idf.sh: no ESP-IDF found: install it under ~/.espressif or ~/esp, set IDF_PATH, or activate a shell" >&2
    exit 1
}
export IDF_ACTIVATE="$ACTIVATE"

case "$1" in
    --where)
        echo "ESP-IDF activated by ${ACTIVATE}"
        exit 0 ;;
    --shell)
        exec bash -c '. "$IDF_ACTIVATE" >/dev/null || exit; exec "${SHELL:-bash}" -i' bash ;;
    *)
        # The command runs in the activated subshell as a command, not an
        # exec: an Installation Manager activation provides idf.py as a shell
        # function, which only a shell can call.
        exec bash -c '. "$IDF_ACTIVATE" >/dev/null || exit
                      command -v idf.py >/dev/null || { echo "esp_idf.sh: $IDF_ACTIVATE did not provide idf.py" >&2; exit 1; }
                      "$@"' bash "$@" ;;
esac
