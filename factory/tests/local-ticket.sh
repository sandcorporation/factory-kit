#!/usr/bin/env bash
# Tests of .github/factory/local-ticket.sh and the `kind:local` rule of dispatch-next.sh (#389).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../local-ticket.sh"
dispatch="$here/../dispatch-next.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" GITHUB_OUTPUT="$tmp/output" FACTORY_TRACKS=1 FACTORY_LIST_RETRY_WAIT=0 FACTORY_DISPATCH_SEEN_WAIT=0
  mkdir -p "$FAKE_GH"; : > "$FAKE_GH/calls.log"; : > "$GITHUB_OUTPUT"
}
issue() { # issue <n> <labels csv> <title> <body>
  jq -n --argjson n "$1" --arg l "$2" --arg t "$3" --arg b "$4" \
    '{number: $n, state: "open", title: $t, body: $b, labels: ($l | split(",") | map(select(. != "") | {name: .}))}' \
    > "$FAKE_GH/issue-$1.json"
}
labels() { jq -r '[.labels[].name] | sort | join(",")' "$FAKE_GH/issue-$1.json"; }
res() { sed -n 's/^local=//p' "$GITHUB_OUTPUT" | tail -n 1; }
ncomments() { [ -f "$FAKE_GH/comments-$1.json" ] && jq length "$FAKE_GH/comments-$1.json" || echo 0; }

setup "a ticket that names .github/workflows becomes state:human + kind:local"
issue 80 state:ready,model:sonnet "CI 단계 추가" "ci.yml 대신 .github/workflows/factory-x.yml 을 고친다"
bash "$script" 80 > /dev/null 2>&1; eq "exit" 0 $?
eq "local" true "$(res)"
eq "labels" "kind:local,model:sonnet,state:human" "$(labels 80)"
eq "one comment" 1 "$(ncomments 80)"
eq "marker" "<!-- factory-human workflow-change -->|<!-- factory-local -->" "$(jq -r '.[0].body | split("
")[0:2] | join("|")' "$FAKE_GH/comments-80.json")"
bash "$script" 80 > /dev/null 2>&1
eq "again: no second comment" 1 "$(ncomments 80)"
eq "again: labels the same" "kind:local,model:sonnet,state:human" "$(labels 80)"

has_text() { case "$3" in *"$2"*) eq "$1" ok ok ;; *) eq "$1" "[$2]" "[$3]" ;; esac; }
has_text "workflow wording" "workflow 파일 — 로컬 작업자 몫" "$(jq -r '.[0].body' "$FAKE_GH/comments-80.json")"

setup "a ticket labelled local without a workflow is handed over as local-only (#437)"
issue 84 kind:local,state:ready "코드 서명 인증서" "인증서와 비밀값을 사람이 준비한다"
bash "$script" 84 > /dev/null 2>&1; eq "exit" 0 $?
eq "local" true "$(res)"
eq "labels" "kind:local,state:human" "$(labels 84)"
eq "marker" "<!-- factory-human local-only -->|<!-- factory-local -->" "$(jq -r '.[0].body | split("
")[0:2] | join("|")' "$FAKE_GH/comments-84.json")"
has_text "person wording" "사람 몫 — 사람의 결정·비밀값·사람 기계가 필요한 티켓" "$(jq -r '.[0].body' "$FAKE_GH/comments-84.json")"
case "$(jq -r '.[0].body' "$FAKE_GH/comments-84.json")" in *"workflow 파일"*) eq "no workflow wording" no yes ;; *) eq "no workflow wording" no no ;; esac

setup "a local ticket a person deferred stays out of the factory and is not handed over again (#473)"
issue 85 kind:local,state:deferred "코드 서명 인증서" "인증서와 비밀값을 사람이 준비한다"
bash "$script" 85 > /dev/null 2>&1; eq "exit" 0 $?
eq "local" true "$(res)"
eq "labels" "state:deferred,kind:local" "$(labels 85)"
eq "no comment" 0 "$(ncomments 85)"
eq "hand-to-human not called" 0 "$(grep -c 'issues/85/labels' "$FAKE_GH/calls.log")"

setup "a local ticket already handed over, whose state:human a person took off, is not handed over again"
issue 86 local "코드 서명 인증서" "인증서와 비밀값을 사람이 준비한다"
jq -n '[{id: 1, created_at: "2026-11-17T00:00:00Z", body: "<!-- factory-human local-only -->\n<!-- factory-local -->\n까닭", user: {login: "github-actions[bot]"}}]' \
  | tr -d '\r' > "$FAKE_GH/comments-86.json"
bash "$script" 86 > /dev/null 2>&1; eq "exit" 0 $?
eq "local" true "$(res)"
eq "labels" "local" "$(labels 86)"
eq "still one comment" 1 "$(ncomments 86)"

setup "an ordinary ticket is left alone"
issue 81 state:ready "백엔드" "모델을 더한다"
bash "$script" 81 > /dev/null 2>&1
eq "local" false "$(res)"
eq "labels" "state:ready" "$(labels 81)"
eq "no comment" 0 "$(ncomments 81)"

setup "the title counts too, and the local label alone is enough"
issue 82 state:ready ".github/workflows 정리" "x"
bash "$script" 82 > /dev/null 2>&1
eq "title" true "$(res)"
issue 83 kind:local,state:human "x" "y"
: > "$GITHUB_OUTPUT"
bash "$script" 83 > /dev/null 2>&1
eq "local label" true "$(res)"

setup "dispatch-next does not pick a local ticket"
jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}]}' > "$FAKE_GH/issue-50.json"
issue 61 state:ready,kind:local "x" "## Parent

#50"
issue 62 state:ready "x" "## Parent

#50"
bash "$dispatch" --tickets-only > "$tmp/log" 2>&1
eq "only the other" 62 "$(grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//')"

echo "local-ticket.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
