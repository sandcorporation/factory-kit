#!/usr/bin/env bash
# Tests of .github/factory/decompose.sh (state and wrap-up of the Decompose stage) against the fake gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../decompose.sh"
workflow="$here/../../workflows/factory-decompose.yml"
export PATH="$here/decompose-fake:$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# --- helpers -------------------------------------------------------------------------------

g() { git -c user.name=t -c user.email=t@example.invalid -c core.autocrlf=false "$@"; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output" FACTORY_ROOT="$tmp/repo"
  mkdir -p "$FAKE_GH"
  : > "$GITHUB_OUTPUT"
  # A checkout of main with one merged acceptance test (ticket #301) and a bare origin.
  g init -q --bare "$tmp/origin.git"
  g init -q -b main "$FACTORY_ROOT"
  mkdir -p "$FACTORY_ROOT/crates/app-core/tests" "$FACTORY_ROOT/crates/app-core/src"
  printf '#[test]\n#[ignore = "#301"]\nfn a() {}\n' > "$FACTORY_ROOT/crates/app-core/tests/spec_old_app.rs"
  echo '// lib' > "$FACTORY_ROOT/crates/app-core/src/lib.rs"
  (cd "$FACTORY_ROOT" && g add -A && g commit -q -m init && g remote add origin "$tmp/origin.git" \
    && g push -q origin main)
}

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}
has() { # has <what> <needle> <haystack>
  case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}

# issue <n> <labels comma-separated> [title] [body]
issue() {
  jq -n --argjson n "$1" --arg l "$2" --arg t "${3:-Ticket $1}" --arg b "${4:-}" \
    '{number: $n, state: "open", title: $t, body: $b, labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

# subs <spec> <n:state> ...
subs() {
  local s=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {number: (.[0] | tonumber), state: .[1]}' | jq -s . \
    | tr -d '\r' > "$FAKE_GH/sub-issues-$s.json"
}

# pull <number> <state> <head ref>
pull() {
  local f="$FAKE_GH/pulls.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg s "$2" --arg h "$3" '. + [{number: $n, state: $s, head: {ref: $h}}]' "$f" \
    | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }
labels_of() { jq -r '[.labels[].name] | join(",")' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }
pull_count() { [ -f "$FAKE_GH/pulls.json" ] && jq length "$FAKE_GH/pulls.json" | tr -d '\r' || echo 0; }
dispatches() { grep -c 'actions/workflows/factory-odin.yml/dispatches' "$FAKE_GH/calls.log" 2> /dev/null || true; }
remote_branch() { git -C "$tmp/origin.git" rev-parse -q --verify "refs/heads/factory/spec-$1" > /dev/null && echo yes || echo no; }

state() { bash "$script" state "$1" > "$tmp/log" 2>&1; }
finish() { bash "$script" finish "$1" "$2" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }

# --- state ---------------------------------------------------------------------------------

setup "state: a spec without sub-issues is new"
issue 249 kind:spec "공장 개선"
state 249
eq mode new "$(out mode)"

setup "state: wait:decision waits for the answer"
issue 249 kind:spec,wait:decision
subs 249 301:open
state 249
eq mode question "$(out mode)"

setup "state: an open spec PR means Odin only, even with tickets lacking tests"
issue 249 kind:spec
subs 249 301:open 302:open
pull 41 closed factory/spec-249
pull 42 open factory/spec-250
pull 43 open factory/spec-249
state 249
eq mode specpr "$(out mode)"
eq pr 43 "$(out pr)"

setup "state: closed or other specs' PRs do not count"
issue 249 kind:spec
pull 41 closed factory/spec-249
pull 42 open factory/spec-250
state 249
eq mode new "$(out mode)"

setup "state: open tickets without an ignore marker in the checkout are decomposed"
issue 249 kind:spec
subs 249 301:open 302:open 303:closed 304:open
printf '#[test]\n#[ignore = "#304"]\nfn b() {}\n' > "$FACTORY_ROOT/crates/app-core/tests/spec_new_x.rs"
state 249
eq mode decomposed "$(out mode)"
eq tickets 302 "$(out tickets)"

setup "state: a marker of a longer number does not count (#30 vs #301)"
issue 249 kind:spec
subs 249 30:open
state 249
eq mode decomposed "$(out mode)"
eq tickets 30 "$(out tickets)"

setup "state: every open ticket has its tests: done"
issue 249 kind:spec
subs 249 301:open 302:closed
state 249
eq mode done "$(out mode)"

setup "state: a deferred spec is left alone even with a question or a spec PR (#437)"
issue 249 kind:spec,state:deferred,wait:decision
subs 249 301:open
pull 43 open factory/spec-249
state 249
eq mode deferred "$(out mode)"

# --- finish --------------------------------------------------------------------------------

setup "finish: a deferred spec leaves no PR, branch, dispatch or question (#437)"
issue 249 kind:spec,state:deferred
subs 249 301:open
issue 301 state:ready
finish 249 decomposed
eq code 0 "$(cat "$tmp/code")"
eq result deferred "$(out result)"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"
eq branch no "$(remote_branch 249)"
eq "#301 labels" state:ready "$(labels_of 301)"

setup "finish: a question (new spec) leaves no PR, branch, dispatch or state:ready"
issue 249 kind:spec,wait:decision
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_x_app.rs"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result question "$(out result)"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"
eq branch no "$(remote_branch 249)"

setup "finish: a ticket that changes workflow files becomes state:human + kind:local"
issue 249 kind:spec,wait:decision
issue 301 "" ".github/workflows/ 에 단계를 더한다"
issue 302 ""
subs 249 301:open 302:open
finish 249 decomposed
eq "#301 labels" "kind:local,state:human" "$(labels_of 301)"
eq "#302 labels" "" "$(labels_of 302)"

setup "finish: a question (decomposed spec) also takes state:ready off the open tickets"
issue 249 kind:spec,wait:decision
issue 301 state:ready
issue 302 state:ready
issue 303 state:ready
subs 249 301:open 302:open 303:closed
finish 249 decomposed
eq result question "$(out result)"
eq "#301 labels" "" "$(labels_of 301)"
eq "#302 labels" "" "$(labels_of 302)"
eq "closed #303 labels" state:ready "$(labels_of 303)"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"

setup "finish: a new spec gets the spec PR with only its acceptance tests, then Odin"
issue 249 kind:spec "비용 장부"
issue 301 ""
issue 302 model:strong
subs 249 301:open 302:open
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_ledger_app.rs"
echo '// stray' >> "$FACTORY_ROOT/crates/app-core/src/lib.rs"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result pr "$(out result)"
eq pr 500 "$(out pr)"
eq title "스펙: 비용 장부 인수 시험 (#249)" "$(jq -r '.[0].title' "$FAKE_GH/pulls.json" | tr -d '\r')"
eq head factory/spec-249 "$(jq -r '.[0].head.ref' "$FAKE_GH/pulls.json" | tr -d '\r')"
eq base main "$(jq -r '.[0].base.ref' "$FAKE_GH/pulls.json" | tr -d '\r')"
body=$(jq -r '.[0].body' "$FAKE_GH/pulls.json" | tr -d '\r')
has "body" "Refs #249" "$body"
has "body" "- #301" "$body"
has "body" "- #302" "$body"
eq "PR labels" "" "$(labels_of 500)"
eq "#301 labels" "" "$(labels_of 301)"
eq dispatches 1 "$(dispatches)"
has "dispatch input" "inputs[spec]=249" "$(grep dispatches "$FAKE_GH/calls.log")"
eq branch yes "$(remote_branch 249)"
eq "committed files" crates/app-core/tests/spec_ledger_app.rs \
  "$(git -C "$tmp/origin.git" diff --name-only main factory/spec-249 | tr -d '\r')"
has "stray warning" "outside the acceptance tests" "$(cat "$tmp/log")"

setup "finish: a decomposed spec takes state:ready off and opens the spec PR"
issue 249 kind:spec
issue 301 state:ready
issue 302 state:ready,model:strong
subs 249 301:open 302:open
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_ledger_more.rs"
finish 249 decomposed
eq result pr "$(out result)"
eq "#301 labels" "" "$(labels_of 301)"
eq "#302 labels" model:strong "$(labels_of 302)"
eq dispatches 1 "$(dispatches)"

setup "finish: a new spec keeps existing state:ready off its hands (only decomposed removes)"
issue 249 kind:spec
issue 301 ""
subs 249 301:open
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_a_b.rs"
finish 249 new
eq "#301 labels" "" "$(labels_of 301)"
eq "no label added" 0 "$(grep -c 'issues/301/labels' "$FAKE_GH/calls.log" || true)"

setup "finish: a failed Odin dispatch only warns"
issue 249 kind:spec
issue 301 ""
subs 249 301:open
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_a_b.rs"
touch "$FAKE_GH/fail-dispatch"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result pr "$(out result)"
has "warning" "could not dispatch factory-odin.yml" "$(cat "$tmp/log")"

setup "finish: no open tickets after a new decompose is an error, without a PR"
issue 249 kind:spec
finish 249 new
eq code 1 "$(cat "$tmp/code")"
eq "pull requests" 0 "$(pull_count)"
eq dispatches 0 "$(dispatches)"

setup "dispatch-odin: dispatches factory-odin.yml with the spec"
issue 249 kind:spec
bash "$script" dispatch-odin 249 > "$tmp/log" 2>&1
eq code 0 "$?"
eq dispatches 1 "$(dispatches)"

# --- budget --------------------------------------------------------------------------------

body_of() { jq -r '.body' "$FAKE_GH/issue-$1.json" | tr -d '\r'; }
budget() { bash "$script" budget "$1" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }
edits() { grep -c "PATCH repos/owner/repo/issues/$1 --input" "$FAKE_GH/calls.log" 2> /dev/null || true; }
# tickets <spec> <first number> <opus count> <sonnet count>: open sub-issues with those model labels
tickets() {
  local s=$1 n=$2 i list=()
  for ((i = 0; i < $3; i++)); do issue "$n" model:strong; list+=("$n:open"); n=$((n + 1)); done
  for ((i = 0; i < $4; i++)); do issue "$n" ""; list+=("$n:open"); n=$((n + 1)); done
  subs "$s" "${list[@]}"
}

setup "budget: 2 opus + 9 sonnet tickets append one line above the \$60 default"
issue 249 kind:spec "압축 파일" "## 할 것

- 하나"
tickets 249 301 2 9
budget 249
eq code 0 "$(cat "$tmp/code")"
# 30 + 2 x 10 + 9 x 3 = 77
eq body "## 할 것

- 하나

예산: \$77" "$(body_of 249)"
eq "budget lines" 1 "$(body_of 249 | grep -c '^예산:')"
v=$(body_of 249 | sed -n 's/^예산: \$//p')
eq "over the default" yes "$([ "${v:-0}" -gt 60 ] && echo yes || echo no)"

setup "budget: unlabeled tickets count as sonnet, closed tickets count too"
issue 249 kind:spec "" "본문
"
issue 301 ""
issue 302 ""
issue 303 model:strong
subs 249 301:open 302:open 303:closed
budget 249
# 30 + 1 x 10 + 2 x 3 = 46; a body ending in a newline gets one blank line, not two
eq body "본문

예산: \$46" "$(body_of 249)"

setup "budget: prices come from the environment and round up to whole dollars"
issue 249 kind:spec
tickets 249 301 1 2
FACTORY_BUDGET_SPEC_USD=20.5 FACTORY_BUDGET_OPUS_USD=8.2 FACTORY_BUDGET_SONNET_USD=1.5 budget 249
# 20.5 + 8.2 + 2 x 1.5 = 31.7 -> 32; an empty body becomes the line alone
eq body "예산: \$32" "$(body_of 249)"

setup "budget: a line a person wrote is left alone"
issue 249 kind:spec "" "## 할 것

예산: \$80

- 하나"
tickets 249 301 2 9
before=$(cat "$FAKE_GH/issue-249.json")
budget 249
eq code 0 "$(cat "$tmp/code")"
eq "issue unchanged" "$before" "$(cat "$FAKE_GH/issue-249.json")"
eq "body edits" 0 "$(edits 249)"
has log "already has a budget line" "$(cat "$tmp/log")"

setup "budget: running it twice writes one line"
issue 249 kind:spec "" "본문"
tickets 249 301 1 1
budget 249
budget 249
eq body "본문

예산: \$43" "$(body_of 249)"
eq "body edits" 1 "$(edits 249)"

setup "budget: no tickets, no line"
issue 249 kind:spec "" "본문"
budget 249
eq body "본문" "$(body_of 249)"
eq "body edits" 0 "$(edits 249)"

setup "finish: a new spec gets its budget line before the spec PR"
issue 249 kind:spec "비용 장부" "본문"
issue 301 ""
issue 302 model:strong
subs 249 301:open 302:open
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_ledger_app.rs"
finish 249 new
eq result pr "$(out result)"
eq body "본문

예산: \$43" "$(body_of 249)"

setup "finish: a question writes no budget line"
issue 249 kind:spec,wait:decision "" "본문"
issue 301 ""
subs 249 301:open
finish 249 new
eq result question "$(out result)"
eq body "본문" "$(body_of 249)"

setup "finish: a failed budget edit only warns and the spec PR still opens"
issue 249 kind:spec "" "본문"
issue 301 ""
subs 249 301:open
echo '// test' > "$FACTORY_ROOT/crates/app-core/tests/spec_a_b.rs"
touch "$FAKE_GH/fail-body-edit"
finish 249 new
eq code 0 "$(cat "$tmp/code")"
eq result pr "$(out result)"
eq body "본문" "$(body_of 249)"
has warning "could not write the budget line" "$(cat "$tmp/log")"

# --- workflow wiring -----------------------------------------------------------------------

# The kit does not ship factory-decompose.yml yet (the reusable workflows are the next step), so these two
# checks run only where the file exists and say they were skipped otherwise.
if [ -f "$workflow" ]; then
  current="workflow: the agent runs only in new and decomposed mode"
  cond=$(awk '/- name: Decompose$/ { f = 1 } f && /if:/ { print; exit }' "$workflow")
  has "agent condition" "steps.state.outputs.mode == 'new' || steps.state.outputs.mode == 'decomposed'" "$cond"
  current="workflow: the old approve-and-start step is gone"
  eq "approve step" 0 "$(grep -c 'Approve tickets and start the chain' "$workflow" || true)"
else
  echo "  SKIP workflow wiring: no $(basename "$workflow") in the kit yet (reusable workflow step)"
fi

echo "decompose.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
