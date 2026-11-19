#!/usr/bin/env bash
# Tests of factory/bridge-migrate-state.sh: a bridge state file written under the old label names,
# moved to the new names, makes the next bridge run (fake gh and switchboard) send no mail at all.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../bridge-migrate-state.sh"
bridge="$here/../bridge.sh"
export PATH="$here/fake:$PATH"

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" FAKE_MAIL="$tmp/mail" XDG_STATE_HOME="$tmp/state"
  export BRIDGE_SINCE=2026-11-01T00:00:00Z
  unset BRIDGE_STATE_DIR BRIDGE_TO BRIDGE_CC SWITCHBOARD_PROFILE FACTORY_SPEC_QUEUE BRIDGE_TRUSTED_BOTS BRIDGE_HUMAN_CHECK_TO
  export FACTORY_REPO=owner/my-repo
  export BRIDGE_TO_BOSS=test/boss BRIDGE_TO_COORD=test/coord
  mkdir -p "$FAKE_GH" "$FAKE_MAIL"
  echo '[]' > "$FAKE_GH/repo-comments.json"
  sent="$XDG_STATE_HOME/my-repo-factory-bridge/sent"
}

issue() { # issue <n> <labels> <title> [body]
  jq -n --argjson n "$1" --arg l "$2" --arg t "$3" --arg b "${4:-}" \
    '{number: $n, state: "open", title: $t, body: $b, html_url: "https://github.com/owner/repo/issues/\($n)",
      labels: ($l | split(",") | map(select(. != "") | {name: .}))}' | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}
labeled() { # labeled <n> <label> <time> [actor]
  local f="$FAKE_GH/timeline-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --arg l "$2" --arg t "$3" --arg a "${4:-github-actions[bot]}" \
    '. + [{event: "labeled", created_at: $t, label: {name: $l}, actor: {login: $a}}]' "$f" \
    | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}
comment() { # comment <id> <issue> <body>
  local f="$FAKE_GH/repo-comments.json"
  jq --argjson id "$1" --arg n "$2" --arg b "$3" \
    '. + [{id: $id, body: $b, user: {login: "github-actions[bot]"}, created_at: "2026-11-17T03:00:00Z",
           issue_url: "https://api.github.com/repos/owner/repo/issues/\($n)",
           html_url: "https://github.com/owner/repo/issues/\($n)#issuecomment-\($id)"}]' "$f" \
    | tr -d '\r' > "$f.new" && mv "$f.new" "$f"
}
sent_count() { [ -f "$FAKE_MAIL/sent.jsonl" ] && wc -l < "$FAKE_MAIL/sent.jsonl" | tr -d ' ' || echo 0; }
run_bridge() { bash "$bridge" > "$tmp/bridge.log" 2>&1; echo $? > "$tmp/code"; }

# A factory with one issue per waiting label and the human-check marker, as the bridge sees it after
# the label rename. The first bridge run writes the state; it is then turned back into what the bridge
# wrote before the rename (old label names), as on a machine that ran the old kit.
waiting_factory() {
  issue 301 state:human "넘긴 티켓"
  labeled 301 state:human 2026-11-18T01:00:00Z
  issue 302 state:human "사람이 붙인 넘김"
  labeled 302 state:human 2026-11-18T01:10:00Z someone
  issue 303 kind:spec,wait:decision "질문 남은 spec"
  labeled 303 wait:decision 2026-11-18T01:20:00Z
  issue 304 kind:spec,wait:budget "예산 넘은 spec"
  labeled 304 wait:budget 2026-11-18T01:30:00Z
  issue 305 wait:check "확인 남음" "- [ ] 한글 확인"
  labeled 305 wait:check 2026-11-18T01:40:00Z
  issue 900 kind:ledger "장부"
  comment 61 900 "<!-- factory-human-check 250 -->
확인 이슈 #305"
  run_bridge
  first=$(sent_count)
  : > "$FAKE_MAIL/sent.jsonl"
  sed -i -e 's/ state:human / ready-for-human /' -e 's/ wait:decision / needs-decision /' \
    -e 's/ wait:budget / factory-paused /' -e 's/ wait:check / human-check /' "$sent"
}

setup "the old state file would mail everything again without the move"
waiting_factory
has "the first run mailed the waiting issues" 5 "$first"
run_bridge
eq code 0 "$(cat "$tmp/code")"
eq "old names: mailed again" 4 "$(sent_count)"

setup "moved to the new names, the next bridge run sends no mail"
waiting_factory
before=$(cat "$sent")
out=$(bash "$script" 2>&1)
eq "exit" 0 "$?"
has "table: ready-for-human" "ready-for-human → state:human  2" "$out"
has "table: needs-decision" "needs-decision → wait:decision  1" "$out"
has "table: factory-paused" "factory-paused → wait:budget  1" "$out"
has "table: human-check" "human-check → wait:check  1" "$out"
eq "backup is the file before" "$before" "$(cat "$sent.before-label-rename")"
eq "no old name left" 0 "$(grep -cE ' (ready-for-human|needs-decision|factory-paused|human-check) ' "$sent")"
has "the human-check marker comment id is kept" "61 " "$(cat "$sent")"
has "a person's own label stays 'human'" "label 302 state:human 2026-11-18T01:10:00Z human" "$(cat "$sent")"
run_bridge
eq code 0 "$(cat "$tmp/code")"
eq "no mail after the move" 0 "$(sent_count)"

setup "a second run changes nothing and keeps the first backup"
waiting_factory
bash "$script" > /dev/null 2>&1
moved=$(cat "$sent")
backup=$(cat "$sent.before-label-rename")
out=$(bash "$script" 2>&1)
eq "exit" 0 "$?"
has "says so" "already uses the new label names" "$out"
eq "file unchanged" "$moved" "$(cat "$sent")"
eq "backup unchanged" "$backup" "$(cat "$sent.before-label-rename")"

setup "--dry-run prints the table and writes nothing"
waiting_factory
before=$(cat "$sent")
out=$(bash "$script" --dry-run 2>&1)
has "table" "needs-decision → wait:decision  1" "$out"
eq "file unchanged" "$before" "$(cat "$sent")"
eq "no backup" no "$([ -e "$sent.before-label-rename" ] && echo yes || echo no)"

setup "an explicit file and BRIDGE_STATE_DIR are used as given"
mkdir -p "$tmp/elsewhere"
printf '%s\n' 17 "17 test/coord" "label 9 model:opus 2026-11-18T01:00:00Z test/coord" "idle 60-61 test/coord" \
  > "$tmp/elsewhere/sent"
export BRIDGE_STATE_DIR="$tmp/elsewhere"
bash "$script" > /dev/null 2>&1
eq "renamed" "label 9 model:strong 2026-11-18T01:00:00Z test/coord" "$(sed -n 3p "$tmp/elsewhere/sent")"
eq "other lines kept" "17|17 test/coord|idle 60-61 test/coord" "$(sed -n '1p;2p;4p' "$tmp/elsewhere/sent" | paste -sd'|')"
unset BRIDGE_STATE_DIR
cp "$tmp/elsewhere/sent.before-label-rename" "$tmp/given"
bash "$script" "$tmp/given" > /dev/null 2>&1
eq "file argument" "label 9 model:strong 2026-11-18T01:00:00Z test/coord" "$(sed -n 3p "$tmp/given")"

setup "no state file yet is not an error"
out=$(bash "$script" 2>&1)
eq "exit" 0 "$?"
has "says so" "nothing to move" "$out"

echo "bridge-migrate-state.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
