#!/bin/bash
# Nightly full-chain soak (Thor: 3 AM on the Linux box). Runs the
# serial long-soak bench (sim-prog-full) against the tree as
# currently checked out; on failure, files a GitHub issue so a
# regression can't pass silently. Installed via crontab:
#   0 3 * * * <repo>/scripts/nightly_soak.sh >> $HOME/noaidi_soak.log 2>&1
export PATH=/opt/oss-cad-suite/bin:$PATH
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo/rtl" || exit 1

echo "=== nightly soak $(date -Is) @ $(git log --oneline -1) ==="
out=$(make sim-prog-full 2>&1)
echo "$out" | tail -25

if echo "$out" | grep -q "ALL PASS"; then
    echo "SOAK PASS"
else
    echo "SOAK FAIL"
    gh issue create -R Thorwegian/noaidi-fpga-synth \
        --title "Nightly soak FAILED $(date -I)" \
        --label tooling \
        --body "sim-prog-full failed on $(git log --oneline -1) at $(date -Is).

Tail of output:
\`\`\`
$(echo "$out" | tail -30)
\`\`\`
Full log: ~/noaidi_soak.log on the dev machine." || true
fi
