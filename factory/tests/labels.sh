#!/usr/bin/env bash
# Tests of the label definition (factory/labels.json), the generated factory/lib/labels.sh, the
# label sync script (factory/labels-sync.sh) against the fake gh, and that no script, prompt or
# workflow still names a label by an old name.
set -u
here=$(cd "$(dirname "$0")" && pwd)
factory=$(cd "$here/.." && pwd)
defs="$factory/labels.json"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
j() { jq "$@" | tr -d '\r'; }

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }

# --- the definition is consistent
current=definition
eq "names unique" "" "$(j -r '[.labels[].name] | group_by(.) | map(select(length > 1) | .[0]) | join(",")' "$defs")"
eq "vars unique" "" "$(j -r '[.labels[].var] | group_by(.) | map(select(length > 1) | .[0]) | join(",")' "$defs")"
eq "vars are L_ names" "" "$(j -r '[.labels[].var | select(test("^L_[A-Z_]+$") | not)] | join(",")' "$defs")"
eq "groups exist" "" "$(j -r '.groups as $g | [.labels[] | select($g[.group] == null) | .name] | join(",")' "$defs")"
eq "old names are not new names" "" \
  "$(j -r '[.labels[].name] as $n | [.labels[].old[], .removed[].name | select(. as $o | $n | index($o))] | join(",")' "$defs")"
eq "group prefix matches name" "" \
  "$(j -r '[.labels[] | select((.name | contains(":")) and ((.name | split(":")[0]) != .group)) | .name] | join(",")' "$defs")"

# --- lib/labels.sh is what --gen writes
current=generated
mkdir -p "$root/gen/lib"
cp "$factory/labels-sync.sh" "$defs" "$root/gen/"
bash "$root/gen/labels-sync.sh" --gen > /dev/null
if diff -u "$factory/lib/labels.sh" "$root/gen/lib/labels.sh" > "$root/gen.diff"; then ok
else bad "lib/labels.sh differs from labels.json (run labels-sync.sh --gen):"; cat "$root/gen.diff"; fi
(
  . "$factory/lib/labels.sh"
  [ "$L_READY" = "$(j -r '.labels[] | select(.var == "L_READY") | .name' "$defs")" ] || exit 1
  [ "$L_EXCLUSIVE_GROUPS" = "state kind model" ] || exit 1
) && ok || bad "sourcing lib/labels.sh gives the names and exclusive groups"

# --- no old label name in scripts, prompts or workflows; scripts name labels only through L_*
current=old-names
# Old names with a dash or colon are unusual enough to look for anywhere; plain words (spec, local,
# deferred) only where a label is named: --label/--add-label/--remove-label X, labels=X and
# name == "X".
olds=$(j -r '.labels[].old[], .removed[].name' "$defs" | grep -E '[-:]' | paste -sd'|')
words=$(j -r '.labels[].old[], .removed[].name' "$defs" | grep -vE '[-:]' | paste -sd'|')
files=$(cd "$factory/.." && ls factory/*.sh factory/*.md workflows/*.yml .github/workflows/*.yml 2> /dev/null \
  | grep -v -e 'factory/labels-sync.sh' -e 'factory/bridge-migrate-state.sh')
found=$(cd "$factory/.." && {
  grep -nE "(^|[^A-Za-z0-9_:./-])($olds)([^A-Za-z0-9_.-]|$)" $files /dev/null
  grep -nE -- "(-label[ =]+[\"']?|labels=[\"']?|name == \\\\?\")($words)([\"' ,)]|$)" $files /dev/null
} || true)
eq "old label names left" "" "$found"
news=$(j -r '.labels[].name' "$defs" | paste -sd'|')
raw=$(cd "$factory" && grep -nE "(^|[^A-Za-z0-9_:./{-])($news)([^A-Za-z0-9_-]|$)" $(ls *.sh | grep -v labels-sync.sh) /dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
eq "label names written out in scripts (use the L_* variables)" "" "$raw"

# --- the fake gh refuses two labels of one exclusive group
current=exclusive
mkdir -p "$root/ex"
export FAKE_GH="$root/ex"
: > "$FAKE_GH/calls.log"
jq -n '{number: 5, state: "open", body: "", labels: [{name: "state:running"}]}' > "$FAKE_GH/issue-5.json"
if gh issue edit 5 --add-label state:ready 2> /dev/null; then bad "add state:ready to a running issue"; else ok; fi
eq "issue unchanged" "state:running" "$(j -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-5.json")"
gh issue edit 5 --remove-label state:running && gh issue edit 5 --add-label state:ready && ok || bad "swap"
gh issue edit 5 --add-label wait:decision && gh issue edit 5 --add-label wait:check && ok || bad "two wait labels"
eq "after swap" "state:ready,wait:decision,wait:check" "$(j -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-5.json")"

# --- sync: dry run changes nothing, --apply renames in place, creates and reports removed ones
current=sync
mkdir -p "$root/sync"
export FAKE_GH="$root/sync" LABELS_SNAPSHOT_DIR="$root/sync/snap" FACTORY_REPO_DIR="$root/sync"
: > "$FAKE_GH/calls.log"
jq -n '[{name: "ready-for-agent", color: "0E8A16", description: "old"},
        {name: "spec-pr", color: "ffffff", description: ""},
        {name: "state:human", color: "d93f0b", description: "공장이 사람에게 넘긴 이슈(까닭은 표지 댓글)"},
        {name: "needs-triage", color: "ededed", description: ""}]' > "$FAKE_GH/repo-labels.json"
cp "$FAKE_GH/repo-labels.json" "$root/sync/start.json"
out=$(bash "$factory/labels-sync.sh" 2>&1); code=$?
eq "dry run exit" 0 "$code"
eq "dry run leaves labels" "$(cat "$root/sync/start.json")" "$(cat "$FAKE_GH/repo-labels.json")"
case "$out" in *"rename  ready-for-agent -> state:ready"*) ok ;; *) bad "dry run plan: $out" ;; esac
case "$out" in *"remove  spec-pr"*) ok ;; *) bad "dry run reports spec-pr: $out" ;; esac
case "$out" in *"state:human"*) bad "state:human is already right: $out" ;; *) ok ;; esac
out=$(bash "$factory/labels-sync.sh" --apply 2>&1); code=$?
eq "apply exit" 0 "$code"
have=$(j -r '[.[].name] | sort | join(",")' "$FAKE_GH/repo-labels.json")
want=$(j -r '[.labels[].name] + ["spec-pr", "needs-triage"] | sort | join(",")' "$defs")
eq "labels after apply" "$want" "$have"
eq "renamed in place, not created" 1 "$(grep -c '^label edit ready-for-agent .*--name state:ready' "$FAKE_GH/calls.log")"
eq "nothing deleted" 0 "$(grep -c '^label delete' "$FAKE_GH/calls.log")"
case "$out" in *"--- label list diff"*"> state:ready"*) ok ;; *) bad "apply prints the before/after diff: $out" ;; esac
[ -f "$root/sync/snap/before.json" ] && [ -f "$root/sync/snap/after.json" ] && ok || bad "snapshots kept"
out=$(bash "$factory/labels-sync.sh" --apply 2>&1)
case "$out" in *"rename"*|*"create"*|*"fix "*) bad "second apply still has work: $out" ;; *) ok ;; esac

# --- sync: labels labels.json does not know are left exactly as they were
current=foreign
: > "$FAKE_GH/calls.log"
jq -n '[{name: "ready-for-agent", color: "0E8A16", description: "old"},
        {name: "needs-triage", color: "ededed", description: "theirs"},
        {name: "team: web", color: "123456", description: "a label of the repository"},
        {name: "bug", color: "d73a4a", description: "Something is not working"}]' > "$FAKE_GH/repo-labels.json"
foreign() { j -S '[.[] | select(.name == "needs-triage" or .name == "team: web" or .name == "bug")
  | {name, color: (.color | ascii_downcase), description}] | sort_by(.name)' "$1"; }
foreign "$FAKE_GH/repo-labels.json" > "$root/sync/foreign-before.json"
bash "$factory/labels-sync.sh" --apply > /dev/null 2>&1
eq "apply exit (foreign)" 0 "$?"
eq "foreign labels unchanged" "$(cat "$root/sync/foreign-before.json")" "$(foreign "$FAKE_GH/repo-labels.json")"
eq "foreign labels in the after snapshot" "$(cat "$root/sync/foreign-before.json")" "$(foreign "$root/sync/snap/after.json")"
eq "no call names a foreign label" 0 "$(grep -cE 'needs-triage|team: web|"bug"|bug' "$FAKE_GH/calls.log")"

# --- sync: old names in the repository's files are reported from the configured paths only
current=scan
mkdir -p "$root/repo/.github/workflows" "$root/repo/other"
echo "  if: github.event.label.name == 'ready-for-agent'" > "$root/repo/.github/workflows/x.yml"
echo "label: ready-for-agent" > "$root/repo/other/y.txt"
jq -n '[{name: "ready-for-agent", color: "0E8A16", description: "old"}]' > "$FAKE_GH/repo-labels.json"
out=$(FACTORY_REPO_DIR="$root/repo" bash "$factory/labels-sync.sh" 2>&1)
case "$out" in *"old label name in .github/workflows/x.yml:1:"*) ok ;; *) bad "default scope .github/: $out" ;; esac
case "$out" in *"other/y.txt"*) bad "outside the default scope: $out" ;; *) ok ;; esac
out=$(FACTORY_REPO_DIR="$root/repo" FACTORY_LABELS_SCAN="other/" bash "$factory/labels-sync.sh" 2>&1)
case "$out" in *"other/y.txt:1:"*) ok ;; *) bad "configured scope: $out" ;; esac
case "$out" in *"x.yml"*) bad "configured scope replaces the default: $out" ;; *) ok ;; esac

echo "labels: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
