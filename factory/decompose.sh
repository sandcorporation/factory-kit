#!/usr/bin/env bash
# State and wrap-up of the Decompose stage (factory-decompose.yml, spec #249 "Decompose").
#
#   decompose.sh state <S>          decide what the Decompose run of spec #S has to do. Writes to
#                                   $GITHUB_OUTPUT (stdout when unset):
#                                     mode=question    the spec has `wait:decision`: wait for the answer
#                                     mode=deferred    the spec has `state:deferred`: a person put it off;
#                                                      nothing runs (finish also stops: result=deferred)
#                                     mode=specpr      an open spec PR (head factory/spec-<S>) exists: no agent,
#                                                      only dispatch Odin
#                                     mode=new         the spec has no sub-issues: create tickets and their tests
#                                     mode=decomposed  some open ticket has no acceptance test in the checkout
#                                                      (no acceptance marker left, spec-tests.sh left): write only those
#                                     mode=done        every open ticket already has its tests: nothing to do
#                                   and tickets=<open tickets without tests, space-separated> (decomposed),
#                                   pr=<spec PR number> (specpr).
#   decompose.sh finish <S> <mode>  after the agent. In decomposed mode first removes `state:ready` from the
#                                   spec's open tickets (Odin labels them again). Then, when the spec has
#                                   `wait:decision`, stops: result=question, no commit, no PR, no dispatch.
#                                   Otherwise commits the acceptance tests (the `acceptance.glob` setting only) on
#                                   factory/spec-<S>, pushes it, opens the spec PR (title "스펙: <title> 인수 시험
#                                   (#S)", body `Refs #S` and the ticket list) and dispatches Odin:
#                                   result=pr, pr=<number>.
#   decompose.sh budget <S>         when the spec body has no `예산:` line, appends `예산: $N` (whole dollars, rounded
#                                   up): the spec's fixed share plus a price per sub-issue by its model label
#                                   (`model:strong`, else the default-model price). A line already there (written by a
#                                   person or an earlier run) is left alone, so running it again changes nothing.
#                                   `finish` calls it before opening the spec PR; a failure only warns.
#   decompose.sh dispatch-odin <S>  dispatch factory-odin.yml with input spec=<S>. A failed dispatch (the workflow
#                                   does not exist yet, or is disabled) only warns.
#
# Environment: REPO (or GITHUB_REPOSITORY), GH_TOKEN, BASE (base branch, default main), FACTORY_ROOT (the
# checkout to search and commit in, default the repository this script is in), and the budget prices in dollars
# (decimals allowed):
#   FACTORY_BUDGET_SPEC_USD    fixed share of a spec, default 30: spec #28 (S13) spent $28.36 before its tickets
#                              (Decompose $10.80, two Odin runs $17.56)
#   FACTORY_BUDGET_OPUS_USD    per `model:strong` ticket, default 10: Implement+Verify of a finished opus ticket
#                              cost $8~$9.5 on spec #28
#   FACTORY_BUDGET_SONNET_USD  per other ticket (no model label: the default model), default 3: a finished sonnet ticket
#                              cost $1.5~$3 on spec #28
# A spec that never went through Decompose has no line and keeps ledger.sh's floor ($60).
# Needs bash, git, gh, jq and awk.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/labels.sh"
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
BASE=${BASE:-${FACTORY_BASE:-$(bash "$here/config.sh" --default base)}}
GLOB=${FACTORY_ACCEPTANCE_GLOB:-$(bash "$here/config.sh" --default acceptance.glob)}
GIT_NAME=${FACTORY_GIT_NAME:-$(bash "$here/config.sh" --default git.name)}
GIT_EMAIL=${FACTORY_GIT_EMAIL:-$(bash "$here/config.sh" --default git.email)}
ROOT=${FACTORY_ROOT:-$(cd "$here/../.." && pwd)}

# jq on Windows prints CRLF; strip the CR everywhere.
j() { jq "$@" | tr -d '\r'; }

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; else echo "$1"; fi
}

branch_of() { echo "factory/spec-$1"; }

has_label() { # has_label <issue> <label>
  [ "$(gh api "repos/$REPO/issues/$1" | j -r --arg l "$2" 'any(.labels[]; .name == $l)')" = true ]
}

# Open sub-issues of a spec, ascending, one per line.
open_tickets() {
  gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate \
    | j -s -r 'add // [] | map(select(.state == "open") | .number) | sort | .[]'
}

sub_issue_count() {
  gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate | j -s 'add // [] | length'
}

# Number of the open spec PR of a spec, empty when there is none.
spec_pr() {
  gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate \
    | j -s -r --arg b "$(branch_of "$1")" \
      'add // [] | map(select(.state == "open" and .head.ref == $b)) | sort_by(.number) | .[0].number // empty'
}

# Whether the checkout has an acceptance test of ticket #N.
has_tests() { # the ticket's markers (spec-tests.sh: acceptance.marker / acceptance.markers)
  FACTORY_ROOT="$ROOT" bash "$here/spec-tests.sh" left "$1" > /dev/null 2>&1
}

state() {
  local s=$1 pr n missing=
  # A spec a person put off (`state:deferred`, #437) waits for nobody: no agent, no Odin, no question.
  if has_label "$s" "${L_DEFERRED}"; then output mode=deferred; return; fi
  if has_label "$s" "${L_DECISION}"; then output mode=question; return; fi
  pr=$(spec_pr "$s")
  if [ -n "$pr" ]; then output mode=specpr; output "pr=$pr"; return; fi
  if [ "$(sub_issue_count "$s")" -eq 0 ]; then output mode=new; return; fi
  for n in $(open_tickets "$s"); do
    has_tests "$n" || missing="$missing $n"
  done
  missing=${missing# }
  if [ -n "$missing" ]; then
    output mode=decomposed
    output "tickets=$missing"
  else
    output mode=done
  fi
}

BUDGET_SPEC=${FACTORY_BUDGET_SPEC_USD:-30}
BUDGET_OPUS=${FACTORY_BUDGET_OPUS_USD:-10}
BUDGET_SONNET=${FACTORY_BUDGET_SONNET_USD:-3}

# All sub-issues of a spec (open or closed), ascending, one per line.
all_tickets() {
  gh api "repos/$REPO/issues/$1/sub_issues?per_page=100" --paginate \
    | j -s -r 'add // [] | map(.number) | sort | .[]'
}

budget() {
  local s=$1 issue n opus=0 sonnet=0 usd tmp
  issue=$(gh api "repos/$REPO/issues/$s") || { echo "::warning::could not read #$s for its budget"; return 1; }
  # The same line ledger.sh reads ("예산:" at the start of a line); any such line counts as written.
  if [ "$(printf '%s' "$issue" | j -r '(.body // "") | test("(^|\n)[ \t]*예산:")')" = true ]; then
    echo "#$s already has a budget line"
    return 0
  fi
  for n in $(all_tickets "$s"); do
    if has_label "$n" "${L_STRONG}"; then opus=$((opus + 1)); else sonnet=$((sonnet + 1)); fi
  done
  if [ $((opus + sonnet)) -eq 0 ]; then
    echo "::warning::#$s has no tickets; no budget line"
    return 0
  fi
  usd=$(awk -v f="$BUDGET_SPEC" -v o="$BUDGET_OPUS" -v s="$BUDGET_SONNET" -v no="$opus" -v ns="$sonnet" \
    'BEGIN { t = f + no * o + ns * s; c = int(t); if (c < t) c++; print c }')
  tmp=$(mktemp) || return 1
  # Built in jq so the rest of the body keeps its bytes (CRLF included).
  printf '%s' "$issue" | jq --arg l "예산: \$$usd" \
    '{body: ((.body // "") | if . == "" then $l elif endswith("\n") then . + "\n" + $l else . + "\n\n" + $l end)}' \
    > "$tmp" || { rm -f "$tmp"; return 1; }
  if gh api -X PATCH "repos/$REPO/issues/$s" --input "$tmp" > /dev/null; then
    echo "#$s budget: \$$usd (fixed \$$BUDGET_SPEC + opus $opus x \$$BUDGET_OPUS + sonnet $sonnet x \$$BUDGET_SONNET)"
  else
    echo "::warning::could not write the budget line of #$s"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

dispatch_odin() {
  if has_label "$1" "${L_DEFERRED}"; then
    echo "::notice::#$1 is deferred (${L_DEFERRED}); Odin is not dispatched"
    return 0
  fi
  if gh api -X POST "repos/$REPO/actions/workflows/${FACTORY_ODIN_WORKFLOW:-factory-odin.yml}/dispatches" \
    -f "ref=$BASE" -f "inputs[spec]=$1" > /dev/null; then
    echo "dispatched ${FACTORY_ODIN_WORKFLOW:-factory-odin.yml} for #$1"
  else
    echo "::warning::could not dispatch ${FACTORY_ODIN_WORKFLOW:-factory-odin.yml} for #$1 (missing or disabled?)"
  fi
}

finish() {
  local s=$1 mode=$2 n tickets branch title list body pr
  if has_label "$s" "${L_DEFERRED}"; then
    echo "::notice::#$s is deferred (${L_DEFERRED}); no spec PR, no question, no dispatch"
    output result=deferred
    return 0
  fi
  tickets=$(open_tickets "$s")
  # A ticket that changes `.github/workflows/` stays out of the factory (local-ticket.sh, #389).
  for n in $tickets; do
    env -u GITHUB_OUTPUT bash "$here/local-ticket.sh" "$n" > /dev/null || echo "::warning::could not check #$n for workflow files"
  done
  if [ "$mode" = decomposed ]; then
    for n in $tickets; do
      if has_label "$n" "${L_READY}"; then
        gh api -X DELETE "repos/$REPO/issues/$n/labels/${L_READY}" > /dev/null \
          || echo "::warning::could not remove ${L_READY} from #$n"
      fi
    done
  fi
  if has_label "$s" "${L_DECISION}"; then
    echo "::notice::#$s asks a question (${L_DECISION}); no spec PR"
    output result=question
    return 0
  fi
  if [ -z "$tickets" ]; then
    echo "::error::#$s has no open tickets after Decompose"
    return 1
  fi

  budget "$s" || echo "::warning::#$s keeps its budget unchanged"

  title=$(gh api "repos/$REPO/issues/$s" | j -r '.title')
  list=$(for n in $tickets; do echo "- #$n"; done)
  branch=$(branch_of "$s")
  (
    cd "$ROOT" || exit 1
    git checkout -q -B "$branch" || exit 1
    # acceptance.glob may hold several globs (space-separated); add what each one matches.
    globs=() excl=()
    while IFS= read -r g; do globs+=("$g"); excl+=(":(exclude)$g"); done       < <(FACTORY_ACCEPTANCE_GLOB="$GLOB" bash "$here/spec-tests.sh" globs)
    for g in "${globs[@]}"; do
      [ -n "$(git ls-files -mo --exclude-standard -- "$g")" ] || continue
      git add -- "$g" || exit 1
    done
    other=$(git status --porcelain --untracked-files=all -- . "${excl[@]}")
    if [ -n "$other" ]; then
      echo "::warning::Decompose changed files outside the acceptance tests; not committed:"
      echo "$other"
    fi
    if git diff --cached --quiet; then
      echo "::warning::Decompose wrote no acceptance tests for #$s; the spec PR has only an empty commit"
    fi
    git -c user.name="$GIT_NAME" \
      -c user.email="$GIT_EMAIL" \
      commit -q --allow-empty -m "스펙: $title 인수 시험 (#$s)" -m "$list" || exit 1
    bash "$here/app-git.sh" && git push -q origin "HEAD:refs/heads/$branch"
  ) || { echo "::error::could not commit or push $branch"; return 1; }

  body="Refs #$s

Decompose가 쓴 티켓별 인수 시험(\`#[ignore = \"#<티켓>\"]\`)이다. Odin이 검토·고침 뒤 병합한다.

## 티켓

$list"
  pr=$(GH_TOKEN="${FACTORY_APP_TOKEN:-${GH_TOKEN:-}}" gh api "repos/$REPO/pulls" -f "title=스펙: $title 인수 시험 (#$s)" -f "head=$branch" -f "base=$BASE" \
    -f "body=$body" | j -r '.number // empty')
  if [ -z "$pr" ]; then echo "::error::could not open the spec PR of #$s"; return 1; fi
  echo "opened spec PR #$pr"
  output result=pr
  output "pr=$pr"
  dispatch_odin "$s"
}

usage() {
  echo "usage: decompose.sh state <S> | finish <S> <mode> | budget <S> | dispatch-odin <S>" >&2
  exit 2
}

: "${REPO:?REPO is not set}"
case "${1:-}" in
  state) [ $# -eq 2 ] || usage; state "$2" ;;
  finish) [ $# -eq 3 ] || usage; finish "$2" "$3" ;;
  budget) [ $# -eq 2 ] || usage; budget "$2" ;;
  dispatch-odin) [ $# -eq 2 ] || usage; dispatch_odin "$2" ;;
  *) usage ;;
esac
