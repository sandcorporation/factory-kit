#!/usr/bin/env bash
# Tests of .github/factory/dispatch-next.sh: --candidates and the second look at an empty label search
# (#267), the spec queue and its bridge markers (#280). Which ticket goes first after Odin is pinned in
# odin.sh's tests.
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../dispatch-next.sh"
export PATH="$here/fake:$PATH"
export REPO=owner/repo

fails=0
passes=0
current=
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { # eq <what> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi
}
has() { # has <what> <needle> <haystack>
  case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac
}
lacks() { # lacks <what> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1: [$2] unexpectedly in [$3]" ;; *) ok ;; esac
}

# issue <n> <labels csv> [blocked_by]: a ticket of spec #50
issue() {
  jq -n --argjson n "$1" --arg l "$2" --argjson b "${3:-0}" \
    '{number: $n, state: "open", body: "## Parent\n\n#50\n",
      labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      issue_dependencies_summary: {blocked_by: $b}}' | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}

setup() {
  current=$1
  tmp=$(mktemp -d "$root/t.XXXXXX")
  export FAKE_GH="$tmp/gh" FACTORY_LIST_RETRY_WAIT=0 FACTORY_TRACKS=1 FACTORY_DISPATCH_SEEN_WAIT=0
  unset FACTORY_SPEC_QUEUE
  mkdir -p "$FAKE_GH"
  : > "$FAKE_GH/calls.log"
  jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}]}' | tr -d '\r' \
    > "$FAKE_GH/issue-50.json"
}

run() { bash "$script" "$@" > "$tmp/log" 2>&1; echo $? > "$tmp/code"; }
code() { cat "$tmp/code"; }
log() { cat "$tmp/log"; }
dispatched() { grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//'; }
searches() { grep -c '^issue list .*--label state:ready' "$FAKE_GH/calls.log" || true; }

# --- candidates ----------------------------------------------------------------------------

setup "a candidate starts although the label search is empty"
issue 61 state:ready 1
issue 62 state:ready
touch "$FAKE_GH/list-empty"
run --tickets-only --candidates "61 62"
eq code 0 "$(code)"
eq "the unblocked candidate" 62 "$(dispatched)"
eq "no second search with candidates" 1 "$(searches)"

setup "candidates and the search together: the lowest number goes first"
issue 62 state:ready
issue 65 state:ready
run --candidates "65" --tickets-only
eq "lowest of both" 62 "$(dispatched)"

setup "a candidate without state:ready or closed does not start"
issue 61 ""
issue 62 state:ready
jq '.state = "closed"' "$FAKE_GH/issue-62.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-62.json"
touch "$FAKE_GH/list-empty"
run --tickets-only --candidates "61 62"
eq code 0 "$(code)"
eq "nothing dispatched" "" "$(dispatched)"
has "says so" "no unblocked approved ticket may start" "$(log)"

setup "a candidate of a paused spec does not start"
jq -n '{number: 50, state: "open", body: "", labels: [{name: "spec"}, {name: "wait:budget"}]}' \
  | tr -d '\r' > "$FAKE_GH/issue-50.json"
issue 62 state:ready
touch "$FAKE_GH/list-empty"
run --tickets-only --candidates "62"
eq "guard still applies" "" "$(dispatched)"

# --- an empty search without candidates ----------------------------------------------------

setup "an empty search is asked once more"
issue 62 state:ready
touch "$FAKE_GH/list-empty-once"
run --tickets-only
eq code 0 "$(code)"
eq "found on the second search" 62 "$(dispatched)"
eq "two searches" 2 "$(searches)"
has "notice" "asking again in 0s" "$(log)"

setup "a search that finds tickets is not repeated"
issue 62 state:ready
run --tickets-only
eq "dispatched" 62 "$(dispatched)"
eq "one search" 1 "$(searches)"

setup "still empty after the second search: nothing starts"
touch "$FAKE_GH/list-empty"
run --tickets-only
eq code 0 "$(code)"
eq "nothing dispatched" "" "$(dispatched)"
eq "two searches and the idle check" 3 "$(searches)"

# --- arguments -----------------------------------------------------------------------------

setup "bad arguments"
run --candidates
eq "missing value" 2 "$(code)"
run --candidates "61 x"
eq "not a number" 2 "$(code)"
run --other
eq "unknown option" 2 "$(code)"
lacks "nothing dispatched" "workflow run" "$(cat "$FAKE_GH/calls.log")"

# --- the spec queue and the bridge markers (#280) ------------------------------------------

# spec <n> <labels csv> [state]: a spec of the queue with two tickets, one merged
spec() {
  jq -n --argjson n "$1" --arg l "$2" --arg s "${3:-open}" \
    '{number: $n, state: $s, body: "",
      labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      sub_issues_summary: {total: 2, completed: 1}}' | tr -d '\r' > "$FAKE_GH/issue-$1.json"
}
ledger() {
  jq -n '{number: 900, state: "open", body: "", labels: [{name: "kind:ledger"}]}' | tr -d '\r' \
    > "$FAKE_GH/issue-900.json"
}
# marked <prefix>: the ledger comments starting with that text
marked() {
  [ -f "$FAKE_GH/comments-900.json" ] || { echo; return; }
  jq -r '.[].body | split("\n")[0]' "$FAKE_GH/comments-900.json" | tr -d '\r' | grep -F -- "$1" | tr '\n' ' ' \
    | sed 's/ $//'
}
decomposed() { grep '^workflow run factory-decompose.yml' "$FAKE_GH/calls.log" | sed 's/.*issue=//' | tr '\n' ' ' | sed 's/ $//'; }

setup "a spec that is not the last of the queue starts without a marker"
spec 50 kind:spec; ledger; spec 60 ""; spec 61 ""
FACTORY_SPEC_QUEUE="60 61" run
eq code 0 "$(code)"
eq "decompose" 60 "$(decomposed)"
eq "labelled" true "$(jq 'any(.labels[]; .name == "kind:spec")' "$FAKE_GH/issue-60.json" | tr -d '\r')"
eq "no marker" "" "$(marked '<!-- factory-')"

setup "the last spec of the queue starts: queue-empty once"
spec 50 kind:spec; ledger; spec 60 kind:spec; spec 61 ""; spec 62 "" closed
FACTORY_SPEC_QUEUE="60 61 62" run
eq code 0 "$(code)"
eq "decompose" 61 "$(decomposed)"
eq "queue-empty" "<!-- factory-queue-empty 61 -->" "$(marked '<!-- factory-')"
has "what to do" "FACTORY_SPEC_QUEUE" "$(jq -r '.[0].body' "$FAKE_GH/comments-900.json")"
# idle on the next call, once, then a new queue is told again
FACTORY_SPEC_QUEUE="60 61 62" run
eq code 0 "$(code)"
has "notice" "the factory is idle" "$(log)"
eq "idle" "<!-- factory-idle 60-61-62 -->" "$(marked '<!-- factory-idle')"
eq "one decompose" 61 "$(decomposed)"
FACTORY_SPEC_QUEUE="60 61 62" run
eq "not again" "<!-- factory-idle 60-61-62 -->" "$(marked '<!-- factory-idle')"
FACTORY_SPEC_QUEUE=" 60  61 " run
eq "a new queue" "<!-- factory-idle 60-61-62 --> <!-- factory-idle 60-61 -->" "$(marked '<!-- factory-idle')"
eq "queue-empty not again" "<!-- factory-queue-empty 61 -->" "$(marked '<!-- factory-queue-empty')"

setup "a deferred spec in the queue is not started (#437)"
spec 50 kind:spec; ledger; spec 60 "state:deferred"; spec 61 ""
FACTORY_SPEC_QUEUE="60 61" run
eq code 0 "$(code)"
eq "decompose skips the deferred spec" 61 "$(decomposed)"
eq "#60 not labelled" false "$(jq 'any(.labels[]; .name == "kind:spec")' "$FAKE_GH/issue-60.json" | tr -d '')"

setup "a closed ticket the search still lists is not running"
spec 50 kind:spec; ledger; spec 60 kind:spec closed
jq '.state = "closed"' "$FAKE_GH/issue-50.json" | tr -d '\r' > "$FAKE_GH/i" && mv "$FAKE_GH/i" "$FAKE_GH/issue-50.json"
issue 70 state:running; jq '.state = "closed"' "$FAKE_GH/issue-70.json" | tr -d '\r' > "$FAKE_GH/i" && mv "$FAKE_GH/i" "$FAKE_GH/issue-70.json"
echo 70 > "$FAKE_GH/list-stale-state:running"
FACTORY_SPEC_QUEUE="60" run
eq code 0 "$(code)"
eq "idle although the search lags" "<!-- factory-idle 60 -->" "$(marked '<!-- factory-idle')"

setup "a --tickets-only run leaves the idle marker once per queue"
spec 50 kind:spec; ledger; spec 60 kind:spec closed
jq '.state = "closed"' "$FAKE_GH/issue-50.json" | tr -d '\r' > "$FAKE_GH/i" && mv "$FAKE_GH/i" "$FAKE_GH/issue-50.json"
FACTORY_SPEC_QUEUE="60" run --tickets-only
eq code 0 "$(code)"
eq "idle" "<!-- factory-idle 60 -->" "$(marked '<!-- factory-idle')"
FACTORY_SPEC_QUEUE="60" run --tickets-only
eq "not again" "<!-- factory-idle 60 -->" "$(marked '<!-- factory-idle')"

setup "a --tickets-only run is not idle while a spec or a ticket is open"
spec 50 kind:spec; ledger; issue 71 state:running
FACTORY_SPEC_QUEUE="60" run --tickets-only
eq code 0 "$(code)"
eq "no idle" "" "$(marked '<!-- factory-idle')"
eq "no decompose" "" "$(decomposed)"

setup "a ticket blocked by a person's issue leaves the stalled marker once a day"
spec 50 kind:spec; ledger; issue 72 state:ready 1; issue 73 state:human
echo '[73]' > "$FAKE_GH/blocked-by-72.json"
FACTORY_NOW=1795050000 run --tickets-only --candidates "72"
eq code 0 "$(code)"
eq "stalled" "<!-- factory-stalled 2026-11-19 -->" "$(marked '<!-- factory-stalled')"
has "names both" "#73(state:human)이 #72을 막는다" "$(jq -r '.[-1].body' "$FAKE_GH/comments-900.json")"
FACTORY_NOW=1795050600 run --tickets-only --candidates "72"
eq "once a day" "<!-- factory-stalled 2026-11-19 -->" "$(marked '<!-- factory-stalled')"

setup "an empty queue is idle as none"
spec 50 kind:spec; ledger
run
eq code 0 "$(code)"
eq "idle none" "<!-- factory-idle none -->" "$(marked '<!-- factory-')"

setup "a queue-empty marker already there is not left again"
spec 50 kind:spec; ledger; spec 61 ""
jq -n '[{id: 1, created_at: "2026-11-17T01:00:00Z", body: "<!-- factory-queue-empty 61 -->\n앞서 남김"}]' \
  | tr -d '\r' > "$FAKE_GH/comments-900.json"
FACTORY_SPEC_QUEUE="61" run
eq "decompose" 61 "$(decomposed)"
eq "one marker" "<!-- factory-queue-empty 61 -->" "$(marked '<!-- factory-')"

setup "a failed comment does not change the exit code"
spec 50 kind:spec; ledger; spec 61 ""
touch "$FAKE_GH/fail-comments"
FACTORY_SPEC_QUEUE="61" run
eq code 0 "$(code)"
eq "decompose" 61 "$(decomposed)"
has "warns" "could not leave <!-- factory-queue-empty 61 -->" "$(log)"
FACTORY_SPEC_QUEUE="61" run
eq "idle code" 0 "$(code)"
has "idle notice" "the factory is idle" "$(log)"
has "warns" "could not leave <!-- factory-idle 61 -->" "$(log)"
eq "no marker" "" "$(marked '<!-- factory-')"

setup "no ledger issue only warns"
spec 50 kind:spec
run
eq code 0 "$(code)"
has "warns" "no open kind:ledger issue" "$(log)"

# --- Implementer tracks (#286) -------------------------------------------------------------

# implementing <n> <track> [status]: an Implementer run for ticket <n> in <track>, not completed
implementing() {
  local f="$FAKE_GH/runs-list.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg t "$2" --arg s "${3:-in_progress}" \
    '[{databaseId: (([.[].databaseId] | max // 1000) + 1), workflow: "factory-implementer.yml", status: $s,
       event: "workflow_dispatch", displayTitle: "implement #\($n) (track \($t))"}] + .' "$f" | tr -d '\r' > "$f.new" \
    && mv "$f.new" "$f"
}
tracks_of() { grep '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log" | sed 's/.*track=\([0-9]*\).*/\1/' | tr '\n' ' ' | sed 's/ $//'; }

setup "two empty tracks fill with the two lowest tickets"
issue 61 state:ready; issue 62 state:ready; issue 63 state:ready
FACTORY_TRACKS=2 run --tickets-only
eq code 0 "$(code)"
eq "two tickets" "61 62" "$(dispatched)"
eq "one per track" "1 2" "$(tracks_of)"
has "says the tracks" "tracks: 2, empty: 1 2" "$(log)"

setup "FACTORY_TRACKS unset means two tracks"
issue 61 state:ready; issue 62 state:ready
unset FACTORY_TRACKS
run --tickets-only
eq "two tickets" "61 62" "$(dispatched)"
export FACTORY_TRACKS=1

setup "a bad FACTORY_TRACKS warns and means two"
issue 61 state:ready; issue 62 state:ready
FACTORY_TRACKS=x run
eq "two tickets" "61 62" "$(dispatched)"
has "warns" "FACTORY_TRACKS" "$(log)"

setup "the empty track only"
issue 61 state:ready; issue 62 state:ready
implementing 70 1
FACTORY_TRACKS=2 run
eq "one ticket" 61 "$(dispatched)"
eq "into track 2" 2 "$(tracks_of)"

setup "full tracks dispatch nothing"
issue 61 state:ready
implementing 70 1; implementing 71 2 queued
FACTORY_TRACKS=2 run --candidates "61"
eq code 0 "$(code)"
eq "nothing" "" "$(dispatched)"
has "says so" "every track is busy" "$(log)"
lacks "no spec opened" "factory-decompose" "$(cat "$FAKE_GH/calls.log")"

setup "completed runs and this run do not hold a track"
issue 61 state:ready; issue 62 state:ready
implementing 70 1 completed; implementing 71 2
GITHUB_RUN_ID=$(jq '.[0].databaseId' "$FAKE_GH/runs-list.json" | tr -d '\r') FACTORY_TRACKS=2 run
eq "both tracks" "61 62" "$(dispatched)"

setup "a ticket with an Implementer run going is not dispatched again"
issue 61 state:ready; issue 62 state:ready
implementing 61 1
FACTORY_TRACKS=2 run --candidates "61"
eq "the other ticket" 62 "$(dispatched)"
has "says so" "#61 already has an implement run" "$(log)"

setup "calls one after another never dispatch a ticket twice"
issue 61 state:ready; issue 62 state:ready
FACTORY_TRACKS=3 run --candidates "61"
FACTORY_TRACKS=3 run --candidates "61"
FACTORY_TRACKS=3 run --first 61
eq "each once, a track left empty" "61 62" "$(dispatched)"
eq "dispatches" 2 "$(grep -c '^workflow run factory-implementer.yml' "$FAKE_GH/calls.log")"

setup "--first goes before lower numbers"
issue 61 state:ready; issue 64 state:ready
run --first 64
eq "first" 64 "$(dispatched)"

setup "a run not listed yet only warns"
issue 61 state:ready
touch "$FAKE_GH/runs-hidden"
FACTORY_TRACKS=2 run --tickets-only
eq code 0 "$(code)"
eq "dispatched" 61 "$(dispatched)"
has "warns" "::warning::" "$(log)"

# open <n> <tickets…>: spec <n> labelled `spec` with those tickets as its open sub-issues
open_spec() {
  local n=$1; shift
  jq -n --argjson n "$n" --argjson t "$#" \
    '{number: $n, state: "open", body: "", labels: [{name: "spec"}],
      sub_issues_summary: {total: ($t + 1), completed: 1}}' | tr -d '\r' > "$FAKE_GH/issue-$n.json"
  printf '%s\n' "$@" | jq -R '{number: tonumber}' | jq -s . | tr -d '\r' > "$FAKE_GH/sub-issues-$n.json"
}

setup "a free track opens the next spec of the queue"
open_spec 50 61; issue 61 state:running; ledger; spec 60 ""; spec 61 ""
implementing 61 1
FACTORY_TRACKS=2 FACTORY_SPEC_QUEUE="60 61" run
eq code 0 "$(code)"
eq "no ticket" "" "$(dispatched)"
eq "decompose" 60 "$(decomposed)"

setup "as many specs as tracks: no next spec"
open_spec 50 61; issue 61 state:running; open_spec 55 66; issue 66 state:ready 1; ledger; spec 60 ""
implementing 61 1
FACTORY_TRACKS=2 FACTORY_SPEC_QUEUE="60" run
eq "no decompose" "" "$(decomposed)"
has "says so" "2 spec(s) running" "$(log)"

setup "FACTORY_TRACKS=1: a spec in progress blocks the next spec, as before"
open_spec 50 61; issue 61 state:running; ledger; spec 60 ""
implementing 61 1
FACTORY_TRACKS=1 FACTORY_SPEC_QUEUE="60" run
eq "no ticket" "" "$(dispatched)"
eq "no decompose" "" "$(decomposed)"

setup "a spec, an issue with sub-issues or a local ticket is not for the factory"
issue 61 state:ready,kind:spec
issue 62 state:ready
jq '.sub_issues_summary = {total: 3, completed: 0}' "$FAKE_GH/issue-62.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-62.json"
issue 63 state:ready,kind:local
issue 64 state:ready
FACTORY_TRACKS=3 run --tickets-only
eq code 0 "$(code)"
eq "only the plain ticket" 64 "$(dispatched)"
has "says why (spec)" "#61 is a spec or has sub-issues" "$(log)"
has "says why (local)" "#63 is local" "$(log)"

setup "FACTORY_TRACKS=1: one ticket per call, track 1"
issue 61 state:ready; issue 62 state:ready
FACTORY_TRACKS=1 run --tickets-only
eq "one" 61 "$(dispatched)"
eq "track 1" 1 "$(tracks_of)"

# --- deferred (#437) -------------------------------------------------------------------------

setup "a deferred blocker is not a person's blocker; said once per pair"
spec 50 kind:spec; ledger; issue 72 state:ready 1; issue 73 state:human,state:deferred
echo '[73]' > "$FAKE_GH/blocked-by-72.json"
FACTORY_NOW=1795050000 run --tickets-only --candidates "72"
eq code 0 "$(code)"
eq "no daily stalled" "" "$(marked '<!-- factory-stalled 2026')"
eq "deferred pair" "<!-- factory-stalled deferred-73-72 -->" "$(marked '<!-- factory-stalled deferred')"
has "names both" "미룬 #73(state:deferred)이 #72을 막는다" "$(jq -r '.[-1].body' "$FAKE_GH/comments-900.json")"
FACTORY_NOW=1795140000 run --tickets-only --candidates "72"
eq "not again the next day" "<!-- factory-stalled deferred-73-72 -->" "$(marked '<!-- factory-stalled')"

setup "a person's blocker and a deferred one: the daily marker names the person's only"
spec 50 kind:spec; ledger; issue 72 state:ready 2; issue 73 state:human; issue 74 state:deferred
echo '[73, 74]' > "$FAKE_GH/blocked-by-72.json"
FACTORY_NOW=1795050000 run --tickets-only --candidates "72"
eq "both markers" "<!-- factory-stalled deferred-74-72 --> <!-- factory-stalled 2026-11-19 -->" "$(marked '<!-- factory-stalled')"
daily=$(jq -r '.[] | select(.body | startswith("<!-- factory-stalled 2026")) | .body' "$FAKE_GH/comments-900.json")
has "person's" "#73(state:human)이 #72을 막는다" "$daily"
lacks "not the deferred" "#74" "$daily"

# subs <spec> <json>: the spec's sub-issues as the REST API returns them
subs() { printf '%s' "$2" > "$FAKE_GH/sub-issues-$1.json"; }
closed_comment() { grep '^issue close 50 ' "$FAKE_GH/calls.log" | sed 's/.*--comment //'; }

setup "a spec whose only open tickets are deferred closes, naming them"
ledger; spec 50 kind:spec
jq '.sub_issues_summary = {total: 4, completed: 2}' "$FAKE_GH/issue-50.json" | tr -d '\r' > "$FAKE_GH/x" && mv "$FAKE_GH/x" "$FAKE_GH/issue-50.json"
subs 50 '[{"number": 61, "state": "closed", "labels": []}, {"number": 62, "state": "open", "labels": [{"name": "state:deferred"}]},
  {"number": 63, "state": "closed", "labels": []}, {"number": 64, "state": "open", "labels": [{"name": "state:deferred"}, {"name": "state:human"}]}]'
FACTORY_SPEC_QUEUE="" run
eq code 0 "$(code)"
eq "closed" "closed" "$(jq -r .state "$FAKE_GH/issue-50.json" | tr -d '\r')"
has "names the deferred" "Deferred, left open: #62 #64." "$(closed_comment)"

setup "a spec with an open ticket that is not deferred stays open"
ledger; spec 50 kind:spec; issue 62 state:ready
subs 50 '[{"number": 61, "state": "open", "labels": [{"name": "state:deferred"}]}, {"number": 62, "state": "open", "labels": [{"name": "state:ready"}]}]'
FACTORY_SPEC_QUEUE="" run
eq code 0 "$(code)"
eq "not closed" "" "$(closed_comment)"
eq "open" "open" "$(jq -r .state "$FAKE_GH/issue-50.json" | tr -d '\r')"

echo "dispatch-next.sh: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
