#!/usr/bin/env bash
# Moves the bridge's state file (bridge.sh, `$STATE_DIR/sent`) from the old label names to the new ones
# in labels.json, so the first bridge run after the label rename mails nothing it already mailed.
#
# The bridge remembers a label it mailed as `label <n> <label> <time> <recipient|human>`. After the
# labels are renamed (labels-sync.sh) the same issue carries the new name, and a line with the old name
# no longer matches it: the bridge would mail every waiting issue again. This script rewrites the label
# field of those lines through the "old" names of labels.json (ready-for-human → state:human,
# needs-decision → wait:decision, factory-paused → wait:budget, human-check → wait:check, ...).
# Every other line (comment ids, `idle` lines) is kept as it is: marker comments such as
# `<!-- factory-human-check SPEC -->` keep their text and their comment id, so they are not mailed again.
#
# usage: bridge-migrate-state.sh [--dry-run] [state file]
#   The state file defaults to the bridge's: $BRIDGE_STATE_DIR/sent, else
#   ${XDG_STATE_HOME:-$HOME/.local/state}/<name>-factory-bridge/sent where <name> is the name part of
#   FACTORY_REPO (owner/name), the same rule as bridge.sh. Run it with the same environment as the
#   bridge's cron line.
#
# It prints one `<old> → <new>  <count>` line per renamed label and keeps the file before the change as
# `sent.before-label-rename` (only the first time: a second run finds nothing to change and writes
# nothing). A missing state file is not an error (the bridge has not run yet).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
labels_json=${FACTORY_LABELS_JSON:-$here/labels.json}

dry=
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
[ $# -le 1 ] || { echo "usage: bridge-migrate-state.sh [--dry-run] [state file]" >&2; exit 2; }

if [ $# -eq 1 ]; then
  file=$1
else
  if [ -n "${BRIDGE_STATE_DIR:-}" ]; then
    dir=$BRIDGE_STATE_DIR
  else
    repo=${FACTORY_REPO:-}
    [ -n "$repo" ] || { echo "bridge-migrate-state: set FACTORY_REPO=owner/name or BRIDGE_STATE_DIR" >&2; exit 2; }
    dir=${XDG_STATE_HOME:-$HOME/.local/state}/${repo##*/}-factory-bridge
  fi
  file=$dir/sent
fi

if [ ! -f "$file" ]; then
  echo "bridge-migrate-state: no state file at $file; nothing to move"
  exit 0
fi

# old<TAB>new, one line per old name
map=$(jq -r '.labels[] | .name as $n | (.old // [])[] | "\(.)\t\($n)"' "$labels_json" | tr -d '\r')
[ -n "$map" ] || { echo "bridge-migrate-state: no old names in $labels_json" >&2; exit 1; }

new=$(mktemp)
counts=$(mktemp)
trap 'rm -f "$new" "$counts"' EXIT
printf '%s\n' "$map" | awk -F'\t' -v counts="$counts" '
  NR == FNR { to[$1] = $2; next }
  {
    sub(/\r$/, "")
    if ($0 ~ /^label /) {
      n = split($0, f, " ")
      if (n >= 5 && (f[3] in to)) {
        seen[f[3]]++
        f[3] = to[f[3]]
        line = f[1]
        for (i = 2; i <= n; i++) line = line " " f[i]
        print line
        next
      }
    }
    print
  }
  END { for (o in seen) printf "%s\t%s\t%d\n", o, to[o], seen[o] > counts }
' - FS=' ' "$file" > "$new"

if [ ! -s "$counts" ]; then
  echo "bridge-migrate-state: $file already uses the new label names"
  exit 0
fi
sort "$counts" | while IFS=$'\t' read -r o n c; do printf '%s → %s  %s\n' "$o" "$n" "$c"; done
if [ -n "$dry" ]; then
  echo "bridge-migrate-state: --dry-run, $file not changed"
  exit 0
fi
[ -e "$file.before-label-rename" ] || cp -p "$file" "$file.before-label-rename"
cat "$new" > "$file"
echo "bridge-migrate-state: $file moved (before: $file.before-label-rename)"
