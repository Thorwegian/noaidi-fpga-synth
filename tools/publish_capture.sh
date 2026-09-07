#!/bin/bash
# Publish an audio capture to the rolling GitHub release so Thor can
# review it on his phone (public repo -> release assets are one tap
# from the GitHub notification).
#
#   publish_capture.sh <file.raw|file.wav|file.flac> <label>
#
# .raw is assumed S16_LE 48 kHz stereo (the arecord format the test
# tools use). Encodes to FLAC (lossless -- the point is reviewing
# synth character). Prints the asset URL. Run on the dev host.
set -e
IN="$1"; LABEL="$2"
[ -z "$IN" ] || [ -z "$LABEL" ] && { echo "usage: $0 <file> <label>"; exit 1; }
TAG="audio-captures"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="/tmp/${LABEL}-${STAMP}.flac"

case "$IN" in
  *.raw) ffmpeg -loglevel error -f s16le -ar 48000 -ac 2 -i "$IN" "$OUT" ;;
  *)     ffmpeg -loglevel error -i "$IN" "$OUT" ;;
esac

cd "$(dirname "$0")/.."
gh release view "$TAG" > /dev/null 2>&1 || \
    gh release create "$TAG" --title "Audio captures (test pipeline)" \
        --notes "Rolling release holding audio captures from the automated test pipeline, for listening review. Lossless FLAC, 48 kHz. Newest assets at the top of the asset list."
gh release upload "$TAG" "$OUT"
echo "published: https://github.com/Thorwegian/noaidi-fpga-synth/releases/tag/$TAG"
echo "asset: $(basename "$OUT")"
