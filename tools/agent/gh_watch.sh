#!/usr/bin/env bash
# gh_watch.sh -- wait, silently, for something new on GitHub; exit when there is.
#
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# GitHub is the chat, so an agent waiting on a human must notice a reply. A
# poll that wakes the model every five minutes costs a model turn each time,
# news or not. This costs nothing while nothing happens: it checks every
# INTERVAL seconds, prints nothing while nothing is new, and the moment a
# comment by someone other than the agent -- or an inbox notification -- is
# newer than the watermark, it prints what it found and exits 0. A background
# run of this script exiting is what wakes the agent.
#
#     gh_watch.sh [--interval SECONDS] [--repo OWNER/NAME] [--me LOGIN]
#                 [--branch main] [--since ISO8601] [--state FILE] [--once]
#
# The watermark is kept in --state (default ~/.local/tmp/claude/gh_watch.since)
# and advances to the newest item seen, so a restart neither replays nor skips.
# Comments come from the repository-wide endpoint with ?since=, one call for
# every issue and pull request at once: there is no per-issue first page to
# fall off, which is how an earlier silent watch missed a comment (#237).
# Issues and pull requests opened or changed by others are news as well (a new
# ticket is activity no comment announces, and whether GitHub notifies the
# agent of it depends on a subscription that is not to be relied on), so the
# repository's issues updated since the watermark are read too.
# A push to the default branch is news too -- new rules or code landing on
# main, which no comment or notification announces -- so the branch's head
# is watched beside the watermark (its last SHA in --state's sibling
# .<branch>.head; the first sight only seeds it).
# --once checks a single time, for scripts: exit 0 is news, exit 1 is quiet.
# GH_CONFIG_DIR is honoured as gh honours it.
set -u

INTERVAL=300
REPO="Thorwegian/noaidi-fpga-synth"
ME="noaidi-claude"
BRANCH="main"
STATE="${HOME}/.local/tmp/claude/gh_watch.since"
SINCE=""
ONCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --repo)     REPO="$2";     shift 2 ;;
        --me)       ME="$2";       shift 2 ;;
        --branch)   BRANCH="$2";   shift 2 ;;
        --since)    SINCE="$2";    shift 2 ;;
        --state)    STATE="$2";    shift 2 ;;
        --once)     ONCE=1;        shift ;;
        *) echo "usage: gh_watch.sh [--interval S] [--repo O/N] [--me LOGIN] [--branch NAME] [--since ISO] [--state FILE] [--once]" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$STATE")"
HEADFILE="${STATE}.${BRANCH//\//_}.head"      # the default branch's last seen SHA
if [ -n "$SINCE" ]; then
    WATERMARK="$SINCE"
elif [ -s "$STATE" ]; then
    WATERMARK="$(cat "$STATE")"
else
    # No watermark known. Never start from "now": a watcher that begins at its
    # own arming time misses whatever landed in the gap before it (the 2026-10-21
    # silent monitor did exactly that). Look back six hours instead -- replaying
    # something already seen costs one wake; missing a comment costs trust.
    WATERMARK="$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
    echo "no watermark given or saved: looking back to ${WATERMARK} (seed the first run with --since <last covered time>)" >&2
fi

# One check: print every new item, newest watermark on the last line; exit 0 if any.
check() {
    local found newest
    found="$(
        gh api --paginate "repos/${REPO}/issues/comments?since=${WATERMARK}&sort=updated&direction=asc&per_page=100" \
            --jq ".[] | select(.user.login != \"${ME}\") | select(.updated_at > \"${WATERMARK}\")
                  | \"NEWS comment #\" + (.issue_url | split(\"/\") | last) + \" \" + .updated_at + \" \" + .user.login + \": \"
                    + (.body | gsub(\"\\n\"; \" \") | .[0:200]) + \"\\t\" + .updated_at" 2>/dev/null
        gh api "notifications?since=${WATERMARK}&per_page=50" \
            --jq ".[] | select(.updated_at > \"${WATERMARK}\")
                  | \"NEWS notification \" + .reason + \" \" + (.subject.url // \"\" | split(\"/\") | last) + \" \" + .updated_at + \" \" + (.subject.title | .[0:120]) + \"\\t\" + .updated_at" 2>/dev/null
        # issues and pull requests OPENED by others since the watermark: a new
        # ticket is activity no comment announces, and whether GitHub notifies
        # the agent of it depends on a subscription not to be relied on. Opened,
        # not updated: the endpoint cannot say who made a change, so an update
        # test would wake the agent on its own comments and labels on others'
        # tickets. Later changes to a ticket reach the agent as comments or
        # notifications anyway.
        gh api --paginate "repos/${REPO}/issues?state=all&since=${WATERMARK}&sort=created&direction=asc&per_page=100" \
            --jq ".[] | select(.user.login != \"${ME}\") | select(.created_at > \"${WATERMARK}\")
                  | \"NEWS \" + (if .pull_request then \"pull\" else \"issue\" end) + \" #\" + (.number | tostring) + \" \" + .created_at + \" \" + .user.login + \": \" + (.title | .[0:120]) + \"\\t\" + .created_at" 2>/dev/null
    )"
    [ -z "$found" ] && return 1
    newest="$(printf '%s\n' "$found" | awk -F'\t' '{print $NF}' | sort | tail -1)"
    printf '%s\n' "$found" | cut -f1
    echo "$newest" > "$STATE"
    echo "WATERMARK $newest"
    return 0
}

# The default branch's head: a push to it is news. The first sight only seeds
# the remembered SHA (no wake); from then on any new head is reported.
check_push() {
    local head seen
    head="$(gh api "repos/${REPO}/branches/${BRANCH}" \
        --jq '.commit.sha + " " + (.commit.commit.message | split("\n")[0] | .[0:100])' 2>/dev/null)"
    [ -z "$head" ] && return 1
    seen="$(cat "$HEADFILE" 2>/dev/null || true)"
    if [ -z "$seen" ]; then
        echo "${head%% *}" > "$HEADFILE"
        return 1
    fi
    [ "${head%% *}" = "$seen" ] && return 1
    echo "NEWS push ${BRANCH} ${head:0:9} ${head#* }"
    echo "${head%% *}" > "$HEADFILE"
    return 0
}

# Both checks run each round, so a tick with a comment and a push reports both.
round() {
    local news=1
    check && news=0
    check_push && news=0
    return $news
}

if [ "$ONCE" -eq 1 ]; then
    round && exit 0 || exit 1
fi

echo "watching ${REPO} since ${WATERMARK} and ${BRANCH}'s head, every ${INTERVAL}s (quiet until there is news)"
while true; do
    if round; then
        exit 0
    fi
    sleep "$INTERVAL"
done
