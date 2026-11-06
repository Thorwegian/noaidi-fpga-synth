#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# The project's nextpnr: the fork pinned by tools/nextpnr.version, built from
# source into .tools/nextpnr (bin/nextpnr-himbaechel, Gowin arch, GW2A-18C
# only). rtl/Makefile prefers it to the OSS CAD Suite's nextpnr. The chip
# database is generated with the pack suite's Apicula (tools.sh install pack
# first), so the placement and the bitstream generator describe the same chip.
#
#   nextpnr.sh install   clone the pinned commit and build (a no-op when the
#                        installed build is that commit)
#   nextpnr.sh check     say whether the fork's main has moved past the pin
#   nextpnr.sh path      print the directory holding bin/
#
# Needs: git, cmake, a C++17 compiler, Boost (program_options, filesystem,
# thread, iostreams), Eigen3. Debian/Ubuntu: cmake g++ libboost-all-dev
# libeigen3-dev. The Python integration is left out (no python3-dev needed);
# the build only runs Python for the chip database.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version_file=$root/tools/nextpnr.version
source_dir=$root/.tools/nextpnr-src
install_dir=$root/.tools/nextpnr
pack_suite=$($root/scripts/tools.sh path pack)

# shellcheck source=/dev/null
. "$version_file"

installed() {
    [ -x "$install_dir/bin/nextpnr-himbaechel" ] && [ -r "$install_dir/COMMIT" ] &&
        [ "$(cat "$install_dir/COMMIT")" = "$commit" ]
}

case ${1:-install} in
    path)
        echo "$install_dir"
        ;;
    install)
        if installed; then
            echo "nextpnr $commit is in place ($install_dir)"
            exit 0
        fi
        for tool in git cmake c++; do
            command -v $tool > /dev/null || { echo "nextpnr.sh: $tool is needed (see the header)" >&2; exit 1; }
        done
        [ -x "$pack_suite/bin/tabbypy3" ] || { echo "nextpnr.sh: the pack suite is missing: make tools" >&2; exit 1; }
        if [ ! -d "$source_dir/.git" ]; then
            git clone -q --no-checkout "https://github.com/$repository.git" "$source_dir"
        fi
        git -C "$source_dir" fetch -q origin "$commit"
        git -C "$source_dir" checkout -q --detach "$commit"
        git -C "$source_dir" submodule update -q --init --recursive
        # FindApycula wants a prefix whose bin/python has apycula: the pack suite's Python, under that name
        python_prefix=$root/.tools/nextpnr-python
        mkdir -p "$python_prefix/bin"
        ln -sf "$pack_suite/bin/tabbypy3" "$python_prefix/bin/python"
        build_dir=$source_dir/build
        cmake -S "$source_dir" -B "$build_dir" \
            -DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin -DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C \
            -DBUILD_PYTHON=OFF -DBUILD_GUI=OFF -DCMAKE_BUILD_TYPE=Release \
            -DAPYCULA_INSTALL_PREFIX="$python_prefix" \
            -DCMAKE_INSTALL_PREFIX="$install_dir"
        cmake --build "$build_dir" -j "$(nproc)"
        rm -rf "$install_dir"
        cmake --install "$build_dir" > /dev/null
        echo "$commit" > "$install_dir/COMMIT"
        echo "nextpnr $commit ($repository) installed in $install_dir"
        ;;
    check)
        newest=$(git ls-remote "https://github.com/$repository.git" refs/heads/main | cut -c1-${#commit})
        if [ "$newest" = "$commit" ]; then
            echo "nextpnr $commit is the fork's main"
        else
            echo "pinned $commit, the fork's main is $newest: edit tools/nextpnr.version, then make tools"
        fi
        ;;
    *)
        echo "usage: nextpnr.sh install|check|path" >&2
        exit 1
        ;;
esac
