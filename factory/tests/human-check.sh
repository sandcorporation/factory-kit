#!/usr/bin/env bash
# Tests of factory/human-check.sh against the fake gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
hc="$here/../human-check.sh"
export PATH="$here/fake:$PATH" REPO=owner/repo
fails=0 passes=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
export FAKE_GH="$root/gh"
mkdir -p "$FAKE_GH"
jq -n '{number: 50, state: "open", body: "", labels: [{name: "kind:spec"}]}' > "$FAKE_GH/issue-50.json"
labels() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH/issue-50.json" | tr -d '\r'; }
marks() { jq '[.[] | select(.body | contains("factory-human-check SPEC"))] | length' "$FAKE_GH/comments-50.json" 2>/dev/null | tr -d '\r'; }

FACTORY_HUMAN_CHECK_ENABLED=false bash "$hc" 50 >/dev/null 2>&1; eq "disabled: may close" 0 $?
eq "disabled: no label" kind:spec "$(labels)"
env -u FACTORY_HUMAN_CHECK_ENABLED bash "$hc" 50 >/dev/null 2>&1; eq "default is disabled" 0 $?

export FACTORY_HUMAN_CHECK_ENABLED=true
bash "$hc" 50 >/dev/null 2>&1; eq "first call keeps it open" 1 $?
eq "label put on" kind:spec,wait:check "$(labels)"
eq "marker comment" 1 "$(marks)"
bash "$hc" 50 >/dev/null 2>&1; eq "label on: still open" 1 $?
eq "no second comment" 1 "$(marks)"
jq '.labels |= map(select(.name != "wait:check"))' "$FAKE_GH/issue-50.json" > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-50.json"
bash "$hc" 50 >/dev/null 2>&1; eq "label removed: may close" 0 $?
touch "$FAKE_GH/fail-comments"
jq -n '{number: 51, state: "open", body: "", labels: []}' > "$FAKE_GH/issue-51.json"
bash "$hc" 51 >/dev/null 2>&1; eq "comment fails: 2" 2 $?

echo "human-check: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
