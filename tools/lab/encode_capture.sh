#!/bin/bash
# Encode an audio capture for listening review: an MP3 at 320 kbps next to
# the capture, to send over chat (the Discord thread where the work is
# discussed). (Release assets, then a served folder on the cloud box, were
# the earlier homes; both are gone, #368.)
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
#   encode_capture.sh <file.raw|file.wav|file.flac> <label>
#
# .raw is assumed S16_LE 48 kHz stereo (the arecord format the test
# tools use). Encodes to MP3 at 320 kbps (libmp3lame): audio for a human's
# review is lossy by rule and plays on any phone; lossless WAV/FLAC stays
# for production and analysis (AGENTS.md). Writes <label>-<stamp>.mp3 in
# the capture's folder (OUT_DIR overrides) and prints the path.
set -e
IN="$1"; LABEL="$2"
[ -z "$IN" ] || [ -z "$LABEL" ] && { echo "usage: $0 <file> <label>"; exit 1; }
OUT_DIR="${OUT_DIR:-$(dirname "$IN")}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${OUT_DIR}/${LABEL}-${STAMP}.mp3"
ENCODE=(-codec:a libmp3lame -b:a 320k -ar 48000 -id3v2_version 3)

case "$IN" in
  *.raw) ffmpeg -loglevel error -f s16le -ar 48000 -ac 2 -i "$IN" "${ENCODE[@]}" "$OUT" ;;
  *)     ffmpeg -loglevel error -i "$IN" "${ENCODE[@]}" "$OUT" ;;
esac
echo "$OUT"
