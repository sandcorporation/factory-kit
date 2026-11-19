#!/usr/bin/env bash
# Tests of factory/merge-pr.sh (wait for the required checks, then squash-merge) against the fake gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
merge="$here/../merge-pr.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo FACTORY_MERGE_WAIT=0

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }

fresh() { # fresh <name>: a new fake GitHub with open PR #7 on main
  current=$1
  export FAKE_GH="$root/$1"
  mkdir -p "$FAKE_GH"
  jq -n '{number: 7, state: "open", merged: false, head: {ref: "b", sha: "abc"}, base: {ref: "main"}}' \
    > "$FAKE_GH/pull-7.json"
}
runs() { # runs <name=status/conclusion>...
  local a
  for a in "$@"; do
    printf '%s\n' "$a"
  done | jq -R 'split("=") as [$n, $r] | ($r | split("/")) as [$s, $c] | {name: $n, status: $s, conclusion: $c}' \
    | jq -s '{check_runs: .}' > "$FAKE_GH/check-runs.json"
}
merged() { jq -r .merged "$FAKE_GH/pull-7.json" | tr -d '\r'; }
puts() { grep -c 'PUT repos/owner/repo/pulls/7/merge\|-X PUT' "$FAKE_GH/calls.log" 2>/dev/null || true; }

fresh green-merges
runs "build=completed/success" "lint=completed/skipped"
out=$(bash "$merge" 7 2>&1); rc=$?
eq "rc" 0 "$rc"
eq "merged" true "$(merged)"
grep -q 'merge_method=squash' "$FAKE_GH/calls.log" && ok || bad "no squash merge: $out"

fresh red-is-2
jq -n '[{type: "required_status_checks", parameters: {required_status_checks: [{context: "test"}]}}]' \
  > "$FAKE_GH/rules.json"
runs "test=completed/failure" "other=completed/success"
out=$(bash "$merge" 7 2>&1); rc=$?
eq "rc" 2 "$rc"
eq "merged" false "$(merged)"
eq "no merge call" 0 "$(puts)"

fresh unrequired-red-ignored
jq -n '{required_status_checks: {contexts: ["test"]}}' > "$FAKE_GH/protection.json"
runs "test=completed/success" "flaky=completed/failure"
bash "$merge" 7 >/dev/null 2>&1; rc=$?
eq "rc" 0 "$rc"
eq "merged" true "$(merged)"

fresh timeout-is-3
runs "build=in_progress/"
FACTORY_MERGE_POLLS=3 bash "$merge" 7 >/dev/null 2>&1; rc=$?
eq "rc" 3 "$rc"
eq "merged" false "$(merged)"

fresh late-checks
jq -n '{required_status_checks: {checks: [{context: "build"}]}}' > "$FAKE_GH/protection.json"
runs "build=completed/success"
echo 3 > "$FAKE_GH/check-runs-from"
out=$(FACTORY_MERGE_POLLS=5 bash "$merge" 7 2>&1); rc=$?
eq "rc" 0 "$rc"
eq "check-runs reads" 3 "$(tr -d '\r' < "$FAKE_GH/check-runs-calls")"
case "$out" in *"waiting for build"*) ok ;; *) bad "did not wait for build: $out" ;; esac

fresh no-rules-waits-for-all
touch "$FAKE_GH/fail-protection" "$FAKE_GH/fail-rules"
jq '.mergeable = null' "$FAKE_GH/pull-7.json" > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/pull-7.json"
runs "a=completed/success"
jq -n '{statuses: [{context: "ext", state: "pending"}]}' > "$FAKE_GH/status.json"
out=$(FACTORY_MERGE_POLLS=2 bash "$merge" 7 2>&1); rc=$?
eq "rc (pending status, mergeable null)" 3 "$rc"
case "$out" in *"every check"*) ok ;; *) bad "no fallback notice: $out" ;; esac

fresh conflict-is-4
jq '.mergeable = false' "$FAKE_GH/pull-7.json" > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/pull-7.json"
bash "$merge" 7 >/dev/null 2>&1; rc=$?
eq "rc" 4 "$rc"

fresh already-merged
jq '.merged = true | .state = "closed"' "$FAKE_GH/pull-7.json" > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/pull-7.json"
bash "$merge" 7 >/dev/null 2>&1; rc=$?
eq "rc" 0 "$rc"

echo "merge-pr: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
