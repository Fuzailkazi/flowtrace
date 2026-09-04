#!/usr/bin/env bash
# Look at what FlowTrace actually wrote, while verifying a change by hand.
#
# The manual passes in docs/superpowers/plans/ ask questions the UI cannot
# answer — is a span still open, did a note land on this tab or the last one,
# did the launch repair fire when nothing was stale. This reads the same file
# the app does, without going through it.
set -euo pipefail

DB="${FLOWTRACE_DB:-$HOME/Library/Application Support/FlowTrace/flowtrace.sqlite}"
LOG="$(dirname "$DB")/debug.log"

die() { echo "$1" >&2; exit 1; }
[ -f "$DB" ] || die "No database at $DB — run the app once, or set FLOWTRACE_DB."

case "${1:-peek}" in

# The timeline as stored: newest first, with anything still open marked.
peek)
    sqlite3 -header -column "$DB" "
        SELECT startedAt,
               coalesce(endedAt, '** OPEN **')            AS endedAt,
               appName,
               substr(coalesce(target, ''), 1, 26)        AS target,
               substr(coalesce(note, ''), 1, 34)          AS note
        FROM activityEvent
        ORDER BY startedAt DESC
        LIMIT ${2:-10};"
    ;;

# Only what you wrote — the rows that earn a line on the timeline.
notes)
    sqlite3 -header -column "$DB" "
        SELECT startedAt,
               appName,
               substr(coalesce(target, ''), 1, 26)        AS target,
               substr(note, 1, 44)                        AS note,
               substr(coalesce(url, ''), 1, 40)           AS url
        FROM activityEvent
        WHERE note IS NOT NULL AND note != ''
        ORDER BY noteAt DESC
        LIMIT ${2:-10};"
    ;;

# Nothing should be open once the app has quit. More than one open row at a
# time is a bug on its own — only the recorder and the capture panel write them.
spans)
    open=$(sqlite3 "$DB" "SELECT count(*) FROM activityEvent WHERE endedAt IS NULL;")
    echo "open spans: $open"
    [ "$open" = "0" ] || sqlite3 -header -column "$DB" "
        SELECT id, startedAt, appName, substr(coalesce(target, ''), 1, 30) AS target
        FROM activityEvent WHERE endedAt IS NULL;"
    ;;

# The launch repair should say nothing on a clean quit-and-relaunch. A line
# here after a clean quit means the quit path did not close its span; a line
# after merely reopening the window means the repair is running when it
# should not.
repair)
    [ -f "$LOG" ] || die "No log at $LOG"
    if grep -q "closed .* span" "$LOG"; then
        grep -n "closed .* span\|closing spans left open failed" "$LOG" | tail -10
    else
        echo "no span repairs logged — which is what a clean quit should look like"
    fi
    ;;

log)
    [ -f "$LOG" ] || die "No log at $LOG"
    tail -"${2:-20}" "$LOG"
    ;;

# Take one before testing. The dev build writes to the same file as the real
# app, and several of the checks involve erase controls.
backup)
    dest="$HOME/Desktop/flowtrace-backup-$(date +%Y%m%d-%H%M%S).sqlite"
    cp "$DB" "$dest"
    echo "$dest"
    ;;

*)
    cat <<'USAGE'
usage: Scripts/verify-capture.sh <command>

  backup        copy the database to the Desktop before you start
  peek [n]      the last n rows as stored, open spans marked
  notes [n]     only the rows carrying something you wrote
  spans         how many spans are still open, and which
  repair        what the launch repair has logged, and whether it should have
  log [n]       the last n lines the app wrote about itself

Set FLOWTRACE_DB to point at a different file.
USAGE
    exit 1
    ;;
esac
