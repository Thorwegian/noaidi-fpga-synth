#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# The project's copy of the OSS CAD Suite (Yosys, nextpnr, Verilator,
# openFPGALoader), pinned by tools/oss-cad-suite.version so every machine
# builds the gateware with the same tools.
#
#   tools.sh install   fetch the pinned release into .tools/ (a no-op when
#                      it is there already); the checksum is verified
#   tools.sh check     say whether a newer release exists
#   tools.sh upgrade   pin the newest release (version file and checksums);
#                      then `make tools` fetches it. Check the gateware
#                      afterwards: make sim-lockstep, and the seed in
#                      rtl/Makefile.
#   tools.sh path      print the directory holding bin/
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version_file=$root/tools/oss-cad-suite.version
install_dir=$root/.tools/oss-cad-suite
repository=YosysHQ/oss-cad-suite-build

case $(uname -m) in
    x86_64)          platform=linux-x64 ;;
    aarch64 | arm64) platform=linux-arm64 ;;
    *) echo "tools.sh: no OSS CAD Suite build for $(uname -m)" >&2; exit 1 ;;
esac
[ "$(uname -s)" = Linux ] || { echo "tools.sh: Linux only (install the suite yourself and set CAD_SUITE)" >&2; exit 1; }

# shellcheck source=/dev/null
. "$version_file"
checksum_variable=sha256_${platform//-/_}
checksum=${!checksum_variable}
stamp=${tag//-/}                       # 2026-07-30 -> 20260730

installed() {
    [ -r "$install_dir/VERSION" ] && [ "$(cat "$install_dir/VERSION")" = "$stamp" ]
}

latest_tag() {
    curl -fsS "https://api.github.com/repos/$repository/releases/latest" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}

case ${1:-install} in
    path)
        echo "$install_dir"
        ;;
    install)
        if installed; then
            echo "OSS CAD Suite $tag is in place ($install_dir)"
            exit 0
        fi
        archive=oss-cad-suite-$platform-$stamp.tgz
        scratch=$(mktemp -d "$root/.tools.XXXXXX")
        trap 'rm -rf "$scratch"' EXIT
        echo "fetching $archive"
        curl -fL $([ -t 2 ] && echo --progress-bar || echo -sS) -o "$scratch/$archive" \
            "https://github.com/$repository/releases/download/$tag/$archive"
        echo "$checksum  $scratch/$archive" | sha256sum -c -
        tar -xzf "$scratch/$archive" -C "$scratch"
        mkdir -p "$root/.tools"
        rm -rf "$install_dir"
        mv "$scratch/oss-cad-suite" "$install_dir"
        echo "OSS CAD Suite $tag installed in $install_dir"
        ;;
    check)
        newest=$(latest_tag)
        if [ "$newest" = "$tag" ]; then
            echo "OSS CAD Suite $tag is the newest release"
        else
            echo "pinned $tag, newest $newest: make tools-upgrade"
        fi
        ;;
    upgrade)
        newest=$(latest_tag)
        if [ "$newest" = "$tag" ]; then
            echo "already on the newest release ($tag)"
            exit 0
        fi
        new_stamp=${newest//-/}
        assets=$(curl -fsS "https://api.github.com/repos/$repository/releases/tags/$newest")
        digest() {
            python3 -c '
import json, sys
name = "oss-cad-suite-%s-%s.tgz" % (sys.argv[1], sys.argv[2])
for asset in json.load(sys.stdin)["assets"]:
    if asset["name"] == name:
        print(asset["digest"].split(":", 1)[1])
' "$1" "$new_stamp" <<<"$assets"
        }
        x64=$(digest linux-x64)
        arm64=$(digest linux-arm64)
        [ -n "$x64" ] && [ -n "$arm64" ] || { echo "tools.sh: release $newest lacks a Linux build" >&2; exit 1; }
        sed -i -e "s/^tag=.*/tag=$newest/" \
               -e "s/^sha256_linux_x64=.*/sha256_linux_x64=$x64/" \
               -e "s/^sha256_linux_arm64=.*/sha256_linux_arm64=$arm64/" "$version_file"
        echo "pinned $newest (was $tag). Now: make tools, make sim-lockstep, and re-check SEED/PLACER_BETA in rtl/Makefile."
        ;;
    *)
        echo "usage: tools.sh install|check|upgrade|path" >&2
        exit 1
        ;;
esac
