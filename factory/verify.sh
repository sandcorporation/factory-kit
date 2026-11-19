#!/usr/bin/env bash
# The scripted half of the factory Verify run (factory-verify.yml, spec #249 "Verify").
#
#   verify.sh mech <N> <base>            machine checks of ticket #N's branch (the checkout's HEAD)
#                                        against <base> (origin/main). Prints every problem and
#                                        exits 1 when there is one:
#                                        1. no `#[ignore = "#N"]` is left in any tracked *.rs file;
#                                        2. the branch's change to the acceptance tests
#                                           (crates/*/tests/spec_*.rs, `git diff <base>...HEAD`)
#                                           only deletes `#[ignore = "#N"]` lines. Any other added,
#                                           deleted or changed line (an assertion, a removed test,
#                                           another ticket's ignore) is "the acceptance test changed";
#                                        3. no `todo!("#N")` stub (Odin's placeholder for a name of
#                                           ticket #N's contract) is left in any tracked *.rs file.
#   verify.sh sendback <N> <PR> <file> [kind]
#                                        send ticket #N back with the reason (<file>), drop
#                                        `state:running`. <kind> is `acceptance` (default: machine
#                                        checks, acceptance review, merge) or `conflict` (the branch
#                                        does not go onto today's main: conflict, rebase-ci, push;
#                                        #307). The comment starts with the marker
#                                        `<!-- factory-sendback kind=<kind> pr=<PR> -->`.
#                                        acceptance: close the PR, delete its branch and its job-less
#                                        bot ci.yml runs (prune-runs.sh); the Implementer starts over.
#                                        conflict: keep the PR and its branch; the Implementer only
#                                        merges main into it and resolves (verify.sh conflict-pr).
#                                        Each kind has its own limit (ACCEPTANCE_LIMIT 2,
#                                        CONFLICT_LIMIT 3; an old marker without kind= counts as
#                                        acceptance): on reaching it hand the ticket to a human
#                                        (`state:human`, `<!-- factory-human conflict|acceptance-unpassable -->` naming the limit)
#                                        and move the chain on (dispatch-next.sh); otherwise label it
#                                        `state:ready` again and run dispatch-next.sh --first <N>
#                                        (the ticket first, into an empty Implementer track, #286).
#   verify.sh conflict-pr <N>            the PR the Implementer resolves instead of implementing
#                                        again: printed when ticket #N's last send-back is kind=conflict
#                                        and its PR is still open; nothing otherwise (#307).
#   verify.sh next-verify [PR]           when no other Verify run is going, dispatch Verify for the
#                                        oldest open PR still waiting for one (not [PR]); the guard
#                                        against a lost pending run (#286). Asks ledger.sh guard
#                                        for each ticket first: skips one it stops, starts nothing
#                                        on the daily budget (#501).
#   verify.sh pass <N> <PR> [report]     squash-merge the PR (retrying while GitHub computes
#                                        mergeability), delete its branch and its job-less bot
#                                        ci.yml runs (prune-runs.sh), comment the report on the
#                                        PR, close the ticket, dispatch ci.yml and release.yml on main
#                                        and then the next ticket (dispatch-next.sh). Exits 1 when the
#                                        PR could not be merged (nothing else is done then).
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN; RUN_URL (link in comments, optional);
# FACTORY_DISPATCH_NEXT (command run instead of dispatch-next.sh, tests); FACTORY_GUARD (command run
# with the ticket instead of `ledger.sh guard` in next-verify, tests); FACTORY_PRUNE_RUNS (command
# run with the branch instead of prune-runs.sh, tests); FACTORY_MERGE_WAIT
# (seconds between merge attempts, default 15). Needs bash, git, gh and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
# Every send-back comment starts with this; `kind=` follows since #307 (none: acceptance).
SENDBACK='<!-- factory-sendback'
# Send-backs of one kind that hand the ticket to a human (decision 2026-11-18, #307): a failed
# acceptance twice, a conflict with main three times. Conflicts are mostly the other track's luck,
# not the ticket's fault, and resolving one does not implement the ticket again.
ACCEPTANCE_LIMIT=2
CONFLICT_LIMIT=3

j() { jq "$@" | tr -d '\r'; }

usage() {
  echo "usage: verify.sh mech <N> <base> | sendback <N> <PR> <reason file> [acceptance|conflict] | conflict-pr <N> | pass <N> <PR> [report file] | next-verify [skip PR]" >&2
  exit 2
}

# --- mech ----------------------------------------------------------------------------------------

mech() {
  local n=$1 base=$2 attr stub problems=0 left line file
  attr="#[ignore = \"#$n\"]"
  stub="todo!(\"#$n\")"

  left=$(git grep -n -F "$attr" HEAD -- '*.rs' | sed 's/^HEAD://')
  if [ -n "$left" ]; then
    echo "- \`$attr\`이 남아 있다(이 티켓의 인수 시험을 모두 켜야 한다):"
    printf '%s\n' "$left" | sed 's/^/  - /'
    problems=1
  fi

  # Odin stubs the contract names the acceptance tests use with todo!("#N") (odin.md); the ticket
  # replaces every one of them with the real thing.
  left=$(git grep -n -F "$stub" HEAD -- '*.rs' | sed 's/^HEAD://')
  if [ -n "$left" ]; then
    echo "- \`$stub\` 스텁이 남아 있다(계약의 이름을 실제로 구현해야 한다):"
    printf '%s\n' "$left" | sed 's/^/  - /'
    problems=1
  fi

  # Only deletions of this ticket's ignore lines may touch the acceptance tests.
  file=
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in
      'diff --git '*) file=${line##* b/} ;;
      '+++ '* | '--- '*) ;;
      +*)
        echo "- 인수 시험을 고쳤다(줄을 더함) $file: \`${line#+}\`"
        problems=1 ;;
      -*)
        local body=${line#-}
        local trimmed
        trimmed=$(printf '%s' "$body" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [ "$trimmed" = "$attr" ]; then
          :
        elif printf '%s' "$trimmed" | grep -Eq '^#\[ignore = "#[0-9]+"\]$'; then
          echo "- 다른 티켓의 인수 시험을 켰다 $file: \`$trimmed\`"
          problems=1
        else
          echo "- 인수 시험을 고쳤다(줄을 지움) $file: \`$body\`"
          problems=1
        fi ;;
    esac
  done < <(git diff --unified=0 --no-color --no-ext-diff --no-renames "$base"...HEAD -- 'crates/*/tests/spec_*.rs')

  if [ "$problems" -ne 0 ]; then return 1; fi
  echo "기계 검사 통과: \`$attr\`·\`$stub\` 없음, 인수 시험의 변경은 이 티켓의 ignore 줄 지우기뿐"
}

# --- GitHub helpers ------------------------------------------------------------------------------

comment() { gh api "repos/$REPO/issues/$1/comments" -f "body=$2" >/dev/null; }
add_label() { gh api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" >/dev/null; }
remove_label() { gh api -X DELETE "repos/$REPO/issues/$1/labels/$2" >/dev/null 2>&1 || true; }
dispatch() { # dispatch <workflow file> [<input>=<value> ...]
  local wf=$1; shift
  local args=() kv
  for kv in "$@"; do args+=(-f "inputs[${kv%%=*}]=${kv#*=}"); done
  gh api -X POST "repos/$REPO/actions/workflows/$wf/dispatches" -f ref=main "${args[@]}" >/dev/null
}
# Delete the job-less ci.yml pull_request runs GitHub left on a factory PR branch (prune-runs.sh, #270).
prune_runs() {
  [ -n "$1" ] || return 0
  if [ -n "${FACTORY_PRUNE_RUNS:-}" ]; then $FACTORY_PRUNE_RUNS "$1"; else bash "$here/prune-runs.sh" "$1"; fi
}
next_ticket() {
  if [ -n "${FACTORY_DISPATCH_NEXT:-}" ]; then
    $FACTORY_DISPATCH_NEXT "$@"
  else
    bash "$here/dispatch-next.sh" "$@"
  fi
}
pr_branch() { gh api "repos/$REPO/pulls/$1" | j -r '.head.ref // empty'; }
delete_branch() {
  [ -n "$1" ] || return 0
  gh api -X DELETE "repos/$REPO/git/refs/heads/$1" >/dev/null 2>&1 || echo "::warning::could not delete branch $1"
}
# sendbacks <N>: the ticket's send-back comments, oldest first, as JSON lines {kind, pr}
# (a marker without kind= is an acceptance send-back from before #307). Only those after the last
# `<!-- factory-reset -->` comment count: a person resets the counts by leaving one (hand-to-human.sh).
sendbacks() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate \
    | j -c -s --arg m "$SENDBACK" '[.[][] | .body] | (map(startswith("<!-- factory-reset -->")) | rindex(true)) as $r
        | .[(if $r == null then 0 else $r + 1 end):][] | select(startswith($m)) | split("\n")[0]
        | {kind: ((capture("kind=(?<k>[a-z]+)").k) // "acceptance"),
           pr: ((capture("pr=(?<p>[0-9]+)").p) // null)}'
}
sendback_count() { # sendback_count <N> <kind>
  sendbacks "$1" | j -s --arg k "$2" '[.[] | select(.kind == $k)] | length'
}
run_link() { [ -n "${RUN_URL:-}" ] && printf ' (%s)' "$RUN_URL"; }

# --- sendback ------------------------------------------------------------------------------------

sendback() {
  local n=$1 pr=$2 file=$3 kind=${4:-acceptance} reason branch count limit what next code
  case "$kind" in acceptance | conflict) ;; *) usage ;; esac
  reason=$(cat "$file" 2>/dev/null)
  [ -n "$reason" ] || reason="(사유가 남지 않았다)"

  if [ "$kind" = conflict ]; then
    limit=$CONFLICT_LIMIT what="main과의 충돌" code=conflict
    next="PR #$pr과 그 브랜치는 그대로 둔다. Implementer가 다시 구현하지 않고 그 브랜치에 main을 merge해 충돌만 푼다."
  else
    limit=$ACCEPTANCE_LIMIT what="인수 실패" code=acceptance-unpassable
    next="PR #$pr을 닫았다. Implementer가 오늘의 main에서 다시 구현한다."
  fi
  comment "$n" "$SENDBACK kind=$kind pr=$pr -->
Verify가 PR #$pr을 되돌렸다($what)$(run_link). $next

$reason"
  if [ "$kind" = acceptance ]; then
    branch=$(pr_branch "$pr")
    gh api -X PATCH "repos/$REPO/pulls/$pr" -f state=closed >/dev/null || echo "::warning::could not close PR #$pr"
    delete_branch "$branch"
    prune_runs "$branch"
  else
    unmark_checked "$pr"
  fi
  remove_label "$n" state:running

  count=$(sendback_count "$n" "$kind")
  if [ "${count:-0}" -ge "$limit" ]; then
    bash "$here/hand-to-human.sh" "$n" "$code" "Verify가 이 티켓을 ${what}로 ${count}번 되돌렸다(사람 넘김 한도: ${what} ${limit}번). 공장은 더 돌리지 않는다: 사람이 위 되돌림 사유를 보고 티켓이나 인수 시험을 고치거나 충돌을 푼 뒤 \`state:human\`을 떼고 \`state:ready\`를 붙인다." || echo "::warning::could not hand #$n to a human"
    echo "#$n: $kind send-back $count of $limit, handed to a human"
    next_ticket
  else
    add_label "$n" state:ready
    next_ticket --first "$n"
    echo "#$n: $kind send-back $count of $limit, back to state:ready (dispatch-next.sh tries it first)"
  fi
}

# unmark_checked <PR>: the PR stays open on a conflict send-back, but no Verify may take it before
# the Implementer resolved it (next-verify picks open PRs with `<!-- factory-checked `): turn its
# checked markers into `<!-- factory-stale-checked `. The Implementer appends a new one (#307).
unmark_checked() {
  local f
  f=$(mktemp)
  if gh api "repos/$REPO/pulls/$1" | j -r '.body // ""' \
      | sed 's/<!-- factory-checked /<!-- factory-stale-checked /g' > "$f"; then
    gh api -X PATCH "repos/$REPO/pulls/$1" -F "body=@$f" >/dev/null \
      || echo "::warning::could not unmark PR #$1 as checked"
  else
    echo "::warning::could not read PR #$1"
  fi
  rm -f "$f"
}

# --- conflict-pr ---------------------------------------------------------------------------------

# The Implementer's guard asks this (#307): when the ticket's last send-back was a conflict and its
# PR is still open, print that PR; the run then merges main into the PR's branch and resolves
# instead of implementing the ticket again.
conflict_pr() {
  local n=$1 last pr state
  last=$(sendbacks "$n" | tail -n 1)
  [ -n "$last" ] || return 0
  [ "$(printf '%s' "$last" | j -r .kind)" = conflict ] || return 0
  pr=$(printf '%s' "$last" | j -r '.pr // empty')
  [ -n "$pr" ] || return 0
  state=$(gh api "repos/$REPO/pulls/$pr" 2>/dev/null | j -r '.state // empty')
  if [ "$state" = open ]; then echo "$pr"; fi
  return 0
}

# --- pass ----------------------------------------------------------------------------------------

pass() {
  local n=$1 pr=$2 report=${3:-} branch attempt merged=false
  branch=$(pr_branch "$pr")
  for attempt in 1 2 3 4; do
    if gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=squash >/dev/null; then
      merged=true; break
    fi
    echo "::notice::merge attempt $attempt of PR #$pr failed; GitHub may still be computing mergeability"
    sleep "${FACTORY_MERGE_WAIT:-15}"
  done
  if ! $merged; then
    echo "::error::could not merge PR #$pr"
    return 1
  fi
  delete_branch "$branch"
  prune_runs "$branch"
  if [ -n "$report" ] && [ -s "$report" ]; then
    gh api "repos/$REPO/issues/$pr/comments" -f "body=Verify$(run_link): 통과

$(cat "$report")" >/dev/null || true
  fi
  # A GITHUB_TOKEN merge does not reliably close the ticket via `Closes #N`, and fires no
  # `issues: closed` or push event: close it, build main and move the chain on here.
  comment "$n" "Merged in PR #$pr$(run_link)" || true
  gh api -X PATCH "repos/$REPO/issues/$n" -f state=closed -f state_reason=completed >/dev/null \
    || echo "::warning::could not close #$n"
  remove_label "$n" state:running
  dispatch ci.yml || echo "::warning::could not dispatch ci.yml"
  dispatch release.yml || echo "::warning::could not dispatch release.yml"
  next_ticket
}

# --- next-verify ---------------------------------------------------------------------------------

# Verify is serial (one concurrency group), and a group keeps one pending run: a newer pending run
# cancels the older one without a trace. Two Implementer tracks that hand over while Verify runs
# lose one hand-over that way (#286). Each Verify run therefore ends here: when no other Verify run
# is going, start one for the oldest PR still waiting (open, `Closes #N` and the Implementer's
# `<!-- factory-checked ` marker in its body, ticket #N open and `state:running`, no Verify run going
# for #N), other than <skip> (the PR this run was about, e.g. one it was cancelled on).
# verify_guard <N>: "<go> <reason>" from ledger.sh guard for ticket <N> (its outputs go to a file of
# their own, not to this step's GITHUB_OUTPUT). FACTORY_GUARD runs instead of ledger.sh (tests).
verify_guard() {
  local out go reason
  out=$(mktemp)
  if [ -n "${FACTORY_GUARD:-}" ]; then
    GITHUB_OUTPUT=$out $FACTORY_GUARD "$1" < /dev/null >&2
  else
    GITHUB_OUTPUT=$out bash "$here/ledger.sh" guard "$1" < /dev/null >&2
  fi
  go=$(sed -n 's/^go=//p' "$out" | tr -d '\r' | tail -n 1)
  reason=$(sed -n 's/^reason=//p' "$out" | tr -d '\r' | tail -n 1)
  rm -f "$out"
  echo "${go:-false} ${reason:-error}"
}

next_verify() {
  local skip=${1:-0} others waiting p n go reason
  others=$(gh run list --repo "$REPO" --workflow factory-verify.yml --limit 50 \
    --json databaseId,status,displayTitle \
    --jq "[.[] | select(.status != \"completed\" and .databaseId != ${GITHUB_RUN_ID:-0})] | length" | tr -d '\r') \
    || { echo "::warning::could not list the Verify runs"; return 0; }
  if [ "${others:-0}" -gt 0 ]; then
    echo "::notice::$others other Verify run(s) going; they start the next one"
    return 0
  fi
  waiting=$(gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
    | j -r --argjson skip "$skip" '[.[] | select(.number != $skip)
        | (.body // "") as $b | select($b | contains("<!-- factory-checked "))
        | ($b | capture("Closes #(?<n>[0-9]+)").n // empty) as $n | "\(.number) \($n)"] | sort_by(split(" ")[0] | tonumber) | .[]') \
    || { echo "::warning::could not list the open PRs"; return 0; }
  while read -r p n; do
    [ -n "${n:-}" ] || continue
    read -r state progress < <(gh api "repos/$REPO/issues/$n" \
      | j -r '[.state, (any(.labels[]; .name == "state:running") | tostring)] | @tsv')
    [ "${state:-}" = open ] && [ "${progress:-}" = true ] || continue
    # The Verify run started here would stop at its budget guard and, on its way out, start this
    # step again for the other waiting PR: two guarded PRs woke each other forever (#501). Ask the
    # guard first: skip a ticket it stops, and start nothing at all on the daily budget.
    read -r go reason < <(verify_guard "$n")
    if [ "${reason:-}" = daily ]; then
      echo "::notice::the daily budget is spent; no Verify starts until KST midnight"
      return 0
    fi
    if [ "${go:-}" != true ]; then
      echo "::notice::the guard stops #$n (${reason:-unknown}); PR #$p keeps waiting"
      continue
    fi
    echo "PR #$p of #$n waits for Verify"
    gh workflow run factory-verify.yml --repo "$REPO" -f issue="$n" -f pr="$p" \
      || echo "::warning::could not dispatch Verify for PR #$p"
    return 0
  done <<< "$waiting"
  echo "no PR waits for Verify"
}

case "${1:-}" in
  mech) [ $# -eq 3 ] || usage; mech "$2" "$3" ;;
  sendback) [ $# -eq 4 ] || [ $# -eq 5 ] || usage; : "${REPO:?REPO is not set}"; sendback "$2" "$3" "$4" "${5:-acceptance}" ;;
  conflict-pr) [ $# -eq 2 ] || usage; : "${REPO:?REPO is not set}"; conflict_pr "$2" ;;
  pass) [ $# -ge 3 ] || usage; : "${REPO:?REPO is not set}"; pass "$2" "$3" "${4:-}" ;;
  next-verify) [ $# -le 2 ] || usage; : "${REPO:?REPO is not set}"; next_verify "${2:-0}" ;;
  *) usage ;;
esac
