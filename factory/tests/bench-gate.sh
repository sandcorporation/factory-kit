#!/usr/bin/env bash
# Tests of .github/factory/bench-gate.sh (#366: hourly benchmark gate and alert) against the fake gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../bench-gate.sh"
export PATH="$here/fake:$PATH"

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" FACTORY_REPO=owner/repo
  unset BENCH_WORKFLOW FAKE_GH_LOGIN
  mkdir -p "$FAKE_GH"
  echo '[]' > "$FAKE_GH/runs.json"
  printf '%s\n' "필터 벤치" "  중앙값 200ms" "필터 상한 초과: 중앙값 200ms > 상한 160ms (최악 210ms)" \
    "" "xtask ci: 필터 벤치마크 단계 실패 (exit code: 1)" > "$tmp/bench.log"
}

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}
has() { # has <what> <needle> <haystack>
  case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}

# runs <json>: runs.json of the benchmark workflow, newest first
runs() { printf '%s' "$1" > "$FAKE_GH/runs.json"; }
# issue <n> <labels comma-separated>
issue() {
  jq -n --argjson n "$1" --arg l "$2" \
    '{number: $n, state: "open", title: "t", labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}
check() { bash "$script" check "$1" 2> "$tmp/err"; }
alert() { bash "$script" alert "$1" "https://github.com/owner/repo/actions/runs/77" "${2:-$tmp/bench.log}" > "$tmp/log" 2>&1; echo $?; }
comments() { jq -r '.[].body' "$FAKE_GH/comments-$1.json" | tr -d '\r'; }
ncomments() { [ -f "$FAKE_GH/comments-$1.json" ] && jq 'length' "$FAKE_GH/comments-$1.json" | tr -d '\r' || echo 0; }

# --- check -----------------------------------------------------------------------------------

setup "the same sha as the last successful run is skipped"
runs '[{"id": 3, "head_branch": "main", "head_sha": "bbb", "status": "completed", "conclusion": "failure"},
       {"id": 2, "head_branch": "main", "head_sha": "aaa", "status": "completed", "conclusion": "success"},
       {"id": 1, "head_branch": "main", "head_sha": "zzz", "status": "completed", "conclusion": "success"}]'
out=$(check aaa)
eq code 0 "$?"
eq out "run=false
last=aaa" "$out"
has "asks for successful main runs" "workflows/bench.yml/runs?branch=main&status=success" "$(cat "$FAKE_GH/calls.log")"

setup "a new sha runs (a failed run of it does not count)"
runs '[{"id": 3, "head_branch": "main", "head_sha": "bbb", "status": "completed", "conclusion": "failure"},
       {"id": 2, "head_branch": "main", "head_sha": "aaa", "status": "completed", "conclusion": "success"}]'
eq out "run=true
last=aaa" "$(check bbb)"

setup "a successful run on another branch does not count"
runs '[{"id": 2, "head_branch": "work", "head_sha": "bbb", "status": "completed", "conclusion": "success"}]'
eq out "run=true
last=" "$(check bbb)"

setup "no successful run yet runs"
eq out "run=true
last=" "$(check abc)"

setup "BENCH_WORKFLOW names the workflow"
export BENCH_WORKFLOW=other.yml
check abc > /dev/null
has "workflow" "workflows/other.yml/runs" "$(cat "$FAKE_GH/calls.log")"

setup "usage"
bash "$script" > /dev/null 2>&1
eq "no command" 2 "$?"
bash "$script" alert abc > /dev/null 2>&1
eq "alert without arguments" 2 "$?"

# --- alert -----------------------------------------------------------------------------------

setup "the bench-alert issue is opened when there is none and gets the marker"
runs '[{"id": 2, "head_branch": "main", "head_sha": "aaa", "status": "completed", "conclusion": "success"}]'
issue 5 bug
eq code 0 "$(alert bbb)"
n=$(jq -r 'select(any(.labels[]; .name == "bench-alert")) | .number' "$FAKE_GH"/issue-*.json | tr -d '\r')
eq "opened one" 1 "$(printf '%s\n' "$n" | grep -c .)"
eq "title" "벤치 한도 알림" "$(jq -r .title "$FAKE_GH/issue-$n.json" | tr -d '\r')"
body=$(comments "$n")
has marker "<!-- factory-bench-regression bbb -->" "$body"
has range '`aaa..bbb`' "$body"
has compare "https://github.com/owner/repo/compare/aaa...bbb" "$body"
has "run link" "https://github.com/owner/repo/actions/runs/77" "$body"
has "limit line" "필터 상한 초과: 중앙값 200ms > 상한 160ms" "$body"
has "step line" "단계 실패" "$body"
case "$body" in *"  중앙값 200ms"*) bad "a passing line is in the comment" ;; *) ok ;; esac
eq "nothing on #5" 0 "$(ncomments 5)"

setup "an open bench-alert issue is reused"
issue 40 bench-alert
alert bbb > /dev/null
eq "comments on #40" 1 "$(ncomments 40)"
eq "no new issue" 1 "$(ls "$FAKE_GH"/issue-*.json | wc -l | tr -d ' ')"
has "no last success" "성공한 벤치 run이 아직 없음" "$(comments 40)"

setup "a sha already alerted is not commented again; a new sha is"
issue 40 bench-alert
alert bbb > /dev/null
eq code 0 "$(alert bbb)"
eq "one comment" 1 "$(ncomments 40)"
has log "alerted already" "$(cat "$tmp/log")"
alert ccc > /dev/null
eq "new sha" 2 "$(ncomments 40)"

setup "a marker written by someone else does not count as alerted"
issue 40 bench-alert
FAKE_GH_LOGIN=stranger bash "$script" alert bbb url "$tmp/bench.log" > /dev/null 2>&1
alert bbb > /dev/null
eq "bot comment added" 2 "$(ncomments 40)"

setup "without a limit line the end of the log is sent; without a log a note"
issue 40 bench-alert
printf '%s\n' "a" "b" "error: linker failed" > "$tmp/other.log"
alert bbb "$tmp/other.log" > /dev/null
has "log end" "error: linker failed" "$(comments 40)"
alert ccc "$tmp/missing.log" > /dev/null
has "no log" "벤치 출력이 없음" "$(comments 40)"

setup "a failed comment fails the alert"
issue 40 bench-alert
touch "$FAKE_GH/fail-comments"
eq code 1 "$(alert bbb)"

echo "bench-gate.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
