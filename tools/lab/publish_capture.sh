#!/bin/bash
# Publish an audio capture to the rolling GitHub release for listening
# review on a phone: the repo is public, so release assets are one tap
# from the GitHub notification.
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
# 
#   publish_capture.sh <file.raw|file.wav|file.flac> <label>
#
# .raw is assumed S16_LE 48 kHz stereo (the arecord format the test
# tools use). Encodes to MP3 at 320 kbps (libmp3lame): audio for a human's
# review is lossy by rule and plays on any phone; lossless WAV/FLAC stays
# for production and analysis (AGENTS.md). Prints the asset URL. Run on the
# dev host.
set -e
IN="$1"; LABEL="$2"
[ -z "$IN" ] || [ -z "$LABEL" ] && { echo "usage: $0 <file> <label>"; exit 1; }
TAG="audio-captures"
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="${TMPDIR:-$HOME/.local/tmp/claude}"   # scratch, never /tmp
mkdir -p "$WORK"
OUT="${WORK}/${LABEL}-${STAMP}.mp3"
ENCODE=(-codec:a libmp3lame -b:a 320k -ar 48000 -id3v2_version 3)

case "$IN" in
  *.raw) ffmpeg -loglevel error -f s16le -ar 48000 -ac 2 -i "$IN" "${ENCODE[@]}" "$OUT" ;;
  *)     ffmpeg -loglevel error -i "$IN" "${ENCODE[@]}" "$OUT" ;;
esac

cd "$(dirname "$0")/../.."   # tools/lab -> the repo
gh release view "$TAG" > /dev/null 2>&1 || \
    gh release create "$TAG" --title "Audio captures (test pipeline)" \
        --notes "Rolling release holding audio captures from the automated test pipeline, for listening review. MP3 at 320 kbps, 48 kHz. Newest assets at the top of the asset list."
gh release upload "$TAG" "$OUT"
echo "published: https://github.com/Thorwegian/noaidi-fpga-synth/releases/tag/$TAG"
echo "asset: $(basename "$OUT")"
