#!/bin/bash
# Publish an audio capture for listening review: an MP3 in the repo's
# public_html/ on the cloud box, which nginx serves at
# https://thj.no/synth-claude-uploads/ — one tap from the GitHub comment that
# links it. (Release assets were the earlier home; Thor moved the review
# audio here, 2026-10-23.)
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
#   publish_capture.sh <file.raw|file.wav|file.flac> <label>
#
# .raw is assumed S16_LE 48 kHz stereo (the arecord format the test
# tools use). Encodes to MP3 at 320 kbps (libmp3lame): audio for a human's
# review is lossy by rule and plays on any phone; lossless WAV/FLAC stays
# for production and analysis (AGENTS.md). Prints the URL. Run on the cloud
# box (thj.no), where public_html/ is served; a take recorded on the lab box
# is copied over first. PUBLIC_HTML overrides the folder, URL_BASE the URL.
set -e
IN="$1"; LABEL="$2"
[ -z "$IN" ] || [ -z "$LABEL" ] && { echo "usage: $0 <file> <label>"; exit 1; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"          # tools/lab -> the repo
PUBLIC_HTML="${PUBLIC_HTML:-$REPO/public_html}"
URL_BASE="${URL_BASE:-https://thj.no/synth-claude-uploads}"
STAMP=$(date +%Y%m%d-%H%M%S)
NAME="${LABEL}-${STAMP}.mp3"
mkdir -p "$PUBLIC_HTML"
OUT="${PUBLIC_HTML}/${NAME}"
ENCODE=(-codec:a libmp3lame -b:a 320k -ar 48000 -id3v2_version 3)

case "$IN" in
  *.raw) ffmpeg -loglevel error -f s16le -ar 48000 -ac 2 -i "$IN" "${ENCODE[@]}" "$OUT" ;;
  *)     ffmpeg -loglevel error -i "$IN" "${ENCODE[@]}" "$OUT" ;;
esac
chmod a+r "$OUT"
echo "published: ${URL_BASE}/${NAME}"
