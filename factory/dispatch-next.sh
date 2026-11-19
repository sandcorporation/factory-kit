#!/usr/bin/env bash
# Keeps the factory going (factory-implementer.yml: the end of an implement run, the frontier and
# approval jobs and the daily schedule after KST midnight; verify.sh after a merge or a send-back;
# odin.sh after approving a spec's tickets; resume.sh).
#
#   dispatch-next.sh [--tickets-only] [--candidates "N M …"] [--first N]
#
# Tracks (#286): the Implementer runs up to FACTORY_TRACKS tickets at once (the repository variable of
# the same name; empty or not a positive number: 2), one per track. Track T is the concurrency group
# `factory-impl-T` of factory-implementer.yml, and a group holds one running and one pending run and
# silently cancels any other pending run, so this script dispatches only into empty tracks. A track is
# busy while a factory-implementer workflow_dispatch run that is not completed holds it (other than
# the run calling this script, GITHUB_RUN_ID): its title is `implement #N (track T)`; a run without
# that title (dispatched before tracks existed) holds track 1. Runs, not `state:running` tickets, count:
# a ticket stays `state:running` while it waits for Verify, which is serial and separate, and an
# `state:running` label left by a broken run would hold a track for ever.
#
# 1. Fills every empty track, lowest track first, with the lowest-numbered open `state:ready`
#    ticket (not a spec: no `kind:spec` label and no sub-issues; not `kind:local`) with no open blocker, no
#    running implement run, and a budget guard (ledger.sh guard) that
#    says go (--first N is tried before the others: the ticket Verify just sent back). A ticket whose
#    spec is paused or needs a decision is passed over; when the daily budget is spent nothing starts
#    (the schedule resumes after KST midnight). The tickets are those of the label search plus
#    --candidates: the label search (`gh issue list`, a search index) can miss a label added a moment
#    ago, so a caller that has just labelled tickets names them. Each ticket's state, label and
#    blockers are read from the issue API, which is up to date. Without --candidates an empty search
#    is asked once more after FACTORY_LIST_RETRY_WAIT seconds (default 10).
#    No double dispatch: after each dispatch this script waits (up to FACTORY_DISPATCH_SEEN_WAIT
#    seconds, default 60) until the new run is listed, so the next call sees the ticket and its track
#    busy. Two calls at the same moment can still both pick a ticket; the implement job's per-ticket
#    concurrency group (`factory-ticket-N`) then holds the second run until the first claimed the
#    ticket, and its guard finds the ticket no longer `state:ready` and stops.
# 2. With an empty track left (and, with one track, without --tickets-only): closes finished specs
#    (every ticket closed, or the only open ones labelled `state:deferred`, named in the closing comment, #437),
#    resumes a spec whose decompose stopped (no sub-issues and no decompose run going), and when
#    fewer specs are running than there are tracks, labels the next spec of FACTORY_SPEC_QUEUE and
#    dispatches its decompose (decision 2026-11-15, roadmap order), one spec per call. A spec is
#    running while it has no tickets yet or an open ticket labelled `state:running` or
#    `state:ready`; such a ticket outside every open spec counts as a spec of its own. With one
#    track this is the earlier rule: nothing in progress or waiting. An empty queue never moves on to
#    another spec (spec #249: the trial runs one labelled spec only).
# 3. Tells the mail bridge (bridge.sh) through a marker comment on the ledger issue, once per marker
#    (a comment starting with the same marker line is not left again; failing to comment only warns):
#      <!-- factory-queue-empty S -->  the spec S just labelled was the last open unlabelled spec of
#                                      the queue (a warning ahead: S is still running)
#      <!-- factory-idle Q -->         every spec of the queue is labelled; Q is the queue with its
#                                      numbers joined by `-` (`none` when empty), so a new queue
#                                      is told again
#
# Environment: REPO, GH_TOKEN, FACTORY_TRACKS, FACTORY_SPEC_QUEUE (spec numbers in order; the
# repository variable of the same name), FACTORY_LIST_RETRY_WAIT, FACTORY_DISPATCH_SEEN_WAIT,
# GITHUB_RUN_ID, and the budget variables of ledger.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/labels.sh"
: "${REPO:?REPO is not set}"
usage() { echo 'usage: dispatch-next.sh [--tickets-only] [--candidates "N M …"] [--first N]' >&2; exit 2; }
tickets_only=false
candidates=
first=
while [ $# -gt 0 ]; do
  case "$1" in
    --tickets-only) tickets_only=true; shift ;;
    --candidates) [ $# -ge 2 ] || usage; candidates=$2; shift 2 ;;
    --first) [ $# -ge 2 ] || usage; first=$2; shift 2 ;;
    *) usage ;;
  esac
done
for n in $candidates $first; do
  case "$n" in *[!0-9]*) usage ;; esac
done

tracks=${FACTORY_TRACKS:-}
case "$tracks" in
  '' ) tracks=2 ;;
  *[!0-9]* | 0 | 00*) echo "::warning::FACTORY_TRACKS=$tracks is not a positive number; using 2"; tracks=2 ;;
esac
# With one track, --tickets-only keeps its earlier meaning; with more, every call fills every track.
[ "$tracks" -gt 1 ] && tickets_only=false

# go <issue>: run the budget guard; prints its reason and succeeds when it may start.
go() {
  local out; out=$(mktemp)
  GITHUB_OUTPUT=$out bash "$here/ledger.sh" guard "$1" > /dev/null
  local g r
  g=$(sed -n 's/^go=//p' "$out" | tail -n 1)
  r=$(sed -n 's/^reason=//p' "$out" | tail -n 1)
  rm -f "$out"
  echo "$r"
  [ "$g" = true ]
}

# notify <marker line> <text>: leaves "<marker>\n<text>" on the ledger issue (the open issue labelled
# `kind:ledger`, as ledger.sh finds it) unless a comment there already starts with that marker line.
# bridge.sh mails it. Never fails: a missing ledger or a failed call only warns.
notify() {
  local marker=$1 text=$2 ledger firsts
  ledger=$(gh api "repos/$REPO/issues?labels=${L_LEDGER}&state=open&per_page=100" \
    --jq '[.[] | select(.pull_request | not)] | sort_by(.number) | .[0].number // empty') \
    || { echo "::warning::dispatch-next: could not find the ledger issue for $marker"; return 0; }
  ledger=$(printf '%s' "$ledger" | tr -d '\r')
  if [ -z "$ledger" ]; then
    echo "::warning::dispatch-next: no open ${L_LEDGER} issue; $marker not left"
    return 0
  fi
  firsts=$(gh api "repos/$REPO/issues/$ledger/comments?per_page=100" --paginate \
    --jq '.[].body | split("\n")[0]') \
    || { echo "::warning::dispatch-next: could not read the ledger #$ledger; $marker not left"; return 0; }
  if printf '%s\n' "$firsts" | tr -d '\r' | grep -qxF -- "$marker"; then
    return 0
  fi
  gh api "repos/$REPO/issues/$ledger/comments" -f "body=$marker
$text" > /dev/null \
    || echo "::warning::dispatch-next: could not leave $marker on the ledger #$ledger"
  return 0
}

# implement_runs: "<ticket> <track> <run id>" per factory-implementer workflow_dispatch run that is not
# completed, other than this run. Ticket 0 and track 1 for a run without the track title.
implement_runs() {
  gh run list --repo "$REPO" --workflow ${FACTORY_IMPLEMENTER_WORKFLOW:-factory-implementer.yml} --limit 100 \
    --json databaseId,status,event,displayTitle \
    --jq '.[] | select(.status != "completed" and .event == "workflow_dispatch"
      and .databaseId != '"${GITHUB_RUN_ID:-0}"')
      | .databaseId as $id
      | ((.displayTitle | capture("^implement #(?<n>[0-9]+) \\(track (?<t>[0-9]+)\\)")) // {n: "0", t: "1"})
      | "\(.n) \(.t) \($id)"' | tr -d '\r'
}

runs=$(implement_runs) || { echo "::error::could not list the factory-implementer runs"; exit 1; }
busy_tickets=" $(printf '%s\n' "$runs" | awk 'NF { print $1 }' | tr '\n' ' ')"
busy_tracks=" $(printf '%s\n' "$runs" | awk 'NF { print $2 }' | tr '\n' ' ')"
free=
for t in $(seq 1 "$tracks"); do
  case "$busy_tracks" in *" $t "*) ;; *) free="$free $t" ;; esac
done
set -- $free
echo "tracks: $tracks, empty:${free:- none}"
if [ $# -eq 0 ]; then
  echo "::notice::every track is busy; nothing to dispatch"
  exit 0
fi

# seen <ticket> <track> <after run id>: a run of that title newer than <after> is listed.
seen() {
  gh run list --repo "$REPO" --workflow ${FACTORY_IMPLEMENTER_WORKFLOW:-factory-implementer.yml} --limit 20 --json databaseId,displayTitle \
    --jq "any(.[]; .databaseId > $3 and .displayTitle == \"implement #$1 (track $2)\")" | tr -d '\r' \
    | grep -qx true
}

# dispatch <ticket> <track>: dispatch the Implementer and wait until the run is listed.
dispatch() {
  local n=$1 t=$2 last waited=0 limit=${FACTORY_DISPATCH_SEEN_WAIT:-60}
  last=$(gh run list --repo "$REPO" --workflow ${FACTORY_IMPLEMENTER_WORKFLOW:-factory-implementer.yml} --limit 1 --json databaseId \
    --jq '.[0].databaseId // 0' | tr -d '\r')
  echo "dispatch #$n on track $t"
  gh workflow run ${FACTORY_IMPLEMENTER_WORKFLOW:-factory-implementer.yml} --repo "$REPO" -f track="$t" -f issue="$n" || {
    echo "::error::could not dispatch #$n"; return 1; }
  until seen "$n" "$t" "${last:-0}"; do
    if [ "$waited" -ge "$limit" ]; then
      echo "::warning::the run of #$n on track $t is not listed after ${limit}s"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
}

# listed: open `state:ready` issues by the label search, ascending.
listed() {
  gh issue list --repo "$REPO" --state open --label "${L_READY}" --limit 200 --json number \
    --jq 'sort_by(.number) | .[].number'
}
found=$(listed)
if [ -z "$found" ] && [ -z "$candidates" ] && [ -z "$first" ]; then
  wait=${FACTORY_LIST_RETRY_WAIT:-10}
  echo "::notice::the ${L_READY} search is empty; asking again in ${wait}s (the search index may lag)"
  sleep "$wait"
  found=$(listed)
fi

blocked=
for n in $first $(printf '%s\n' $found $candidates | sort -n -u | grep -vx "${first:-x}"); do
  [ $# -gt 0 ] || break
  case "$busy_tickets" in *" $n "*) echo "::notice::#$n already has an implement run"; continue ;; esac
  read -r state ready open isspec islocal subs < <(gh api "repos/$REPO/issues/$n" --jq '[.state,
    (any(.labels[]; .name == "'"${L_READY}"'") | tostring),
    (.issue_dependencies_summary.blocked_by // 0 | tostring),
    (any(.labels[]; .name == "'"${L_SPEC}"'") | tostring),
    (any(.labels[]; .name == "'"${L_LOCAL}"'") | tostring),
    (.sub_issues_summary.total // 0 | tostring)] | @tsv' | tr -d '\r')
  [ "${state:-}" = open ] && [ "${ready:-}" = true ] || continue
  # A spec (label `spec`) or an issue with sub-issues is a parent, not a ticket.
  # A `kind:local` ticket (workflow files) is for a local worker, never the factory.
  if [ "${islocal:-false}" = true ]; then echo "::notice::#$n is local; not for the factory"; continue; fi
  if [ "${isspec:-false}" = true ] || [ "${subs:-0}" -gt 0 ]; then
    echo "::notice::#$n is a spec or has sub-issues; not a ticket"
    continue
  fi
  [ "${open:-1}" -eq 0 ] || { blocked="$blocked $n"; continue; }
  if reason=$(go "$n"); then
    dispatch "$n" "$1" || exit 1
    busy_tickets="$busy_tickets$n "
    shift
    continue
  fi
  if [ "$reason" = daily ]; then
    echo "::notice::the daily budget is spent; the schedule resumes after KST midnight"
    exit 0
  fi
  echo "::notice::#$n does not start ($reason); trying the next ticket"
done
if [ $# -eq 0 ]; then
  echo "every track is busy now"
  exit 0
fi
echo "::notice::no unblocked approved ticket may start for track(s) $*"

# Stalled (#410): a waiting ticket blocked by an issue handed to a person waits for that person, not
# for the factory. Leave one `<!-- factory-stalled <KST date> -->` a day naming them; bridge.sh mails it.
# A blocker a person deferred (label `state:deferred`, #437) waits for nobody, so it is not in that daily
# marker, even when `state:human` was left on it. The ticket it blocks still never starts, which the
# person may not have meant: say so once per pair, `<!-- factory-stalled deferred-<b>-<t> -->` (the same
# bridge kind, never repeated).
stalled=
for t in $blocked; do
  while IFS=$'\t' read -r b kind; do
    [ -n "$b" ] || continue
    if [ "$kind" = deferred ]; then
      notify "<!-- factory-stalled deferred-$b-$t -->" "공장 막힘(미룸): 미룬 #$b(${L_DEFERRED})이 #$t을 막는다. #$t은 #$b이 닫히거나 막음이 풀릴 때까지 시작하지 않는다.
#$t도 미룰 것이면 \`deferred\`를 붙이고, 아니면 #$b의 막음을 푼다."
    else
      stalled="$stalled- #$b(${L_HUMAN})이 #$t을 막는다
"
    fi
  done < <(gh api "repos/$REPO/issues/$t/dependencies/blocked_by" \
    --jq '.[] | select(.state == "open")
      | (if any(.labels[]; .name == "'"${L_DEFERRED}"'") then "deferred"
         elif any(.labels[]; .name == "'"${L_HUMAN}"'") then "human" else empty end) as $k
      | "\(.number)\t\($k)"' 2> /dev/null | tr -d '\r')
done
if [ -n "$stalled" ]; then
  day=$(date -u -d "@$(( ${FACTORY_NOW:-$(date -u +%s)} + 32400 ))" +%F)
  notify "<!-- factory-stalled $day -->" "공장 막힘: 기다리는 티켓이 사람 몫 이슈에 막혀 있다.
${stalled}사람 몫 이슈를 풀고 \`${L_HUMAN}\`을 뗀다."
fi

# Specs and tickets for the idle check and the spec queue below.
specs=$(gh issue list --repo "$REPO" --state open --label "${L_SPEC}" --json number --jq '.[].number' | tr -d '\r')
# The label search may lag (a ticket closed a moment ago still shows up), so each number is read
# again and counted only when it is open with the label (#410).
listed_active=$( { gh issue list --repo "$REPO" --state open --label "${L_RUNNING}" --json number --jq '.[].number'
  gh issue list --repo "$REPO" --state open --label "${L_READY}" --json number --jq '.[].number'; } \
  | tr -d '\r' | sort -n -u)
active=
for n in $listed_active; do
  ok=$(gh api "repos/$REPO/issues/$n" \
    --jq '.state == "open" and any(.labels[]; .name == "'"${L_RUNNING}"'" or .name == "'"${L_READY}"'")' \
    | tr -d '\r') || ok=false
  [ "$ok" = true ] && active="$active $n"
done
# The queue's open specs without the `kind:spec` label, in queue order.
pending=
for s in ${FACTORY_SPEC_QUEUE:-}; do
  read -r state labels < <(gh issue view "$s" --repo "$REPO" --json state,labels --jq '[.state, ([.labels[].name] | join(","))] | @tsv')
  [ "$state" = OPEN ] || continue
  case ",$labels," in *,"${L_SPEC}",*) continue;; esac
  # A spec a person put off (`state:deferred`, #437) is not started from the queue.
  case ",$labels," in *,"${L_DEFERRED}",*) continue;; esac
  pending="$pending $s"
done
idle() {
  echo "::notice::every spec in the queue is labelled; the factory is idle"
  q=$(printf '%s' "${FACTORY_SPEC_QUEUE:-}" | tr -s ' \t\r\n,' '-' | sed 's/^-//; s/-$//')
  notify "<!-- factory-idle ${q:-none} -->" "공장 idle: FACTORY_SPEC_QUEUE(${FACTORY_SPEC_QUEUE:-비어 있음})의 spec이 모두 라벨을 받아 띄울 spec이 없다. FACTORY_SPEC_QUEUE에 spec을 넣고 dispatch-next를 다시 돌린다."
}
# A --tickets-only run (after a ticket ends) is often the last run before the factory goes quiet, so
# it too leaves the idle marker when nothing is open: no spec, no running ticket, no queued spec.
if $tickets_only; then
  [ -z "$specs$active$pending" ] && idle
  exit 0
fi

# Specs. Count the running ones (see 2. above); close finished ones; resume a stopped decompose.
running=0
covered=" "
for s in $specs; do
  read -r total done < <(gh api "repos/$REPO/issues/$s" --jq '"\(.sub_issues_summary.total // 0) \(.sub_issues_summary.completed // 0)"')
  if [ "$total" -eq 0 ]; then
    running=$((running + 1))
    going=$(gh run list --repo "$REPO" --workflow ${FACTORY_DECOMPOSE_WORKFLOW:-factory-decompose.yml} --limit 20 --json status --jq '[.[] | select(.status != "completed")] | length')
    if [ "$going" -gt 0 ]; then
      echo "::notice::spec #$s is still being decomposed"
      continue
    fi
    # Its decompose stopped (budget, decision) or failed: start it again if the guard allows.
    if reason=$(go "$s"); then
      echo "decompose #$s again"
      gh workflow run ${FACTORY_DECOMPOSE_WORKFLOW:-factory-decompose.yml} --repo "$REPO" -f issue="$s"
    else
      echo "::notice::spec #$s has no tickets and may not be decomposed now ($reason)"
    fi
    continue
  fi
  if [ "$total" -eq "$done" ]; then
    gh issue close "$s" --repo "$REPO" --reason completed --comment "All $total tickets merged."
    continue
  fi
  # "<number> open|closed|deferred" per sub-issue (`state:deferred`: open, put off by a person, #437).
  subs_state=$(gh api "repos/$REPO/issues/$s/sub_issues?per_page=100" --paginate --jq '.[]
    | "\(.number) \(if .state == "closed" then "closed"
      elif any(.labels[]?; .name == "'"${L_DEFERRED}"'") then "deferred" else "open" end)"' | tr -d '\r')
  # A spec whose only open tickets are deferred is finished: close it, naming what was left open.
  if [ -n "$subs_state" ] && ! printf '%s\n' "$subs_state" | grep -q ' open$'; then
    left=$(printf '%s\n' "$subs_state" | awk '$2 == "deferred" { printf "%s#%s", (n++ ? " " : ""), $1 }')
    gh issue close "$s" --repo "$REPO" --reason completed \
      --comment "All $total tickets merged or deferred. Deferred, left open: $left."
    continue
  fi
  subs=" $(printf '%s\n' "$subs_state" | cut -d' ' -f1 | tr '\n' ' ')"
  covered="$covered${subs# }"
  for n in $active; do
    case "$subs" in *" $n "*) running=$((running + 1)); break ;; esac
  done
done
for n in $active; do
  case "$covered" in *" $n "*) ;; *) running=$((running + 1)) ;; esac
done
if [ "$running" -ge "$tracks" ]; then
  echo "::notice::$running spec(s) running on $tracks track(s); not moving to the next spec yet"
  exit 0
fi
set -- $pending
if [ $# -gt 0 ]; then
  s=$1
  if ! reason=$(go "$s"); then
    echo "::notice::next spec #$s may not start ($reason)"
    exit 0
  fi
  echo "next spec: #$s"
  gh issue edit "$s" --repo "$REPO" --add-label "${L_SPEC}"
  gh workflow run ${FACTORY_DECOMPOSE_WORKFLOW:-factory-decompose.yml} --repo "$REPO" -f issue="$s"
  if [ $# -eq 1 ]; then
    notify "<!-- factory-queue-empty $s -->" "spec 큐 바닥남: #$s가 FACTORY_SPEC_QUEUE에 남은 마지막 spec이다. 공장은 #$s를 돌리는 중이고, 이것이 끝나면 할 일이 없다. 다음 spec을 FACTORY_SPEC_QUEUE에 넣는다."
  fi
  exit 0
fi
[ "$running" -gt 0 ] && exit 0
idle
exit 0
