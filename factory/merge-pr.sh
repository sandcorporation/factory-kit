#!/usr/bin/env bash
# merge-pr.sh <PR>: waits for the PR's required checks, then squash-merges it with the App token.
#
# The required checks are the base branch's required status checks, read from its rulesets
# (`…/rules/branches/<base>`) and its branch protection (`…/branches/<base>/protection`). When
# neither can be read, every check run and commit status on the PR head counts as required. When
# both can be read and name nothing, the checks already on the head count (nothing to wait for to
# appear). A required check that is not on the head yet is waited for: checks can be registered a
# while after the push.
#
# Each poll reads the PR (merged → done; closed → 4; `mergeable` null: GitHub is still computing it,
# poll again; false → 4), then the head's check runs and statuses. A failed required check ends the
# wait (2); all required checks green → `PUT …/merge` (squash) with $FACTORY_APP_TOKEN (or GH_TOKEN),
# retried on the next poll if GitHub refuses it for now.
#
# Settings (factory.yml, docs/config.md):
#   merge.timeout   FACTORY_MERGE_TIMEOUT   minutes to wait in all (default 20)
#   merge.interval  FACTORY_MERGE_INTERVAL  seconds between polls (default 15; FACTORY_MERGE_WAIT, the
#                                           old name, wins when set)
#   FACTORY_MERGE_POLLS                     at most this many polls (tests; default: no limit, or 10
#                                           when the interval is 0)
#
# Exit codes: 0 merged (or already merged), 1 usage or a GitHub read that keeps failing,
# 2 a required check failed, 3 timed out, 4 the PR is closed or cannot be merged (conflict).
set -u
here=$(cd "$(dirname "$0")" && pwd)
[ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]] || { echo "usage: merge-pr.sh <PR>" >&2; exit 1; }
pr=$1
REPO=${REPO:-${FACTORY_REPO:-${GITHUB_REPOSITORY:-}}}
[ -n "$REPO" ] || { echo "merge-pr.sh: no repository (REPO, FACTORY_REPO or GITHUB_REPOSITORY)" >&2; exit 1; }
timeout_min=${FACTORY_MERGE_TIMEOUT:-$(bash "$here/config.sh" --default merge.timeout)}
interval=${FACTORY_MERGE_WAIT:-${FACTORY_MERGE_INTERVAL:-$(bash "$here/config.sh" --default merge.interval)}}
polls=${FACTORY_MERGE_POLLS:-}
[ -z "$polls" ] && [ "$interval" = 0 ] && polls=10
deadline=$((SECONDS + timeout_min * 60))

# getj <path> <jq filter>: `gh api <path>` through jq; fails when either fails.
getj() { local o; o=$(gh api "$1") || return 1; printf '%s' "$o" | jq -r "$2" | tr -d '\r'; }

# required <base>: the required check names, one per line; exit 1 when neither source can be read.
required() {
  local base=$1 read_any=1 out err
  if out=$(getj "repos/$REPO/rules/branches/$base" \
      '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null); then
    read_any=0; printf '%s\n' "$out"
  fi
  err=$(mktemp)
  if out=$(getj "repos/$REPO/branches/$base/protection" \
      '(.required_status_checks.contexts // [])[], (.required_status_checks.checks // [])[].context' 2>"$err"); then
    read_any=0; printf '%s\n' "$out"
  elif grep -qiE '404|not protected|not found' "$err"; then
    read_any=0
  fi
  rm -f "$err"
  return $read_any
}

# checks <sha>: "<name>\t<pending|success|failure>" for every check run and commit status of <sha>.
checks() {
  local sha=$1
  getj "repos/$REPO/commits/$sha/check-runs?per_page=100" '.check_runs[]
    | "\(.name)\t\(if .status != "completed" then "pending"
        elif (.conclusion // "") | test("^(success|neutral|skipped)$") then "success" else "failure" end)"' || return 1
  getj "repos/$REPO/commits/$sha/status" '.statuses[]
    | "\(.context)\t\(if .state == "pending" then "pending" elif .state == "success" then "success" else "failure" end)"' || return 1
}

req=
mode=
n=0 errors=0
while :; do
  n=$((n + 1))
  if view=$(getj "repos/$REPO/pulls/$pr" '"\(.state) \(.merged) \(.mergeable) \(.head.sha) \(.base.ref)"'); then
    read -r state merged mergeable sha base <<< "$view"
    if [ "$merged" = true ]; then echo "PR #$pr is merged"; exit 0; fi
    [ "$state" = open ] || { echo "::error::PR #$pr is $state, not merged"; exit 4; }
    [ "$mergeable" = false ] && { echo "::error::PR #$pr cannot be merged (conflict with $base)"; exit 4; }
    if [ -z "$mode" ]; then
      if req=$(required "$base"); then
        req=$(printf '%s\n' "$req" | sed '/^$/d' | sort -u); mode=listed
        echo "required checks on $base: $(printf '%s' "$req" | tr '\n' ' ')"
      else
        mode=all; echo "::notice::could not read the required checks of $base; waiting for every check on PR #$pr"
      fi
    fi
    if got=$(checks "$sha"); then
      errors=0
      # Latest result per name: a failure anywhere counts, then pending, then success.
      got=$(printf '%s\n' "$got" | sed '/^$/d' | awk -F'\t' '
        { r = $2; o = s[$1]; if (o == "failure" || (o == "pending" && r == "success")) r = o; s[$1] = r }
        END { for (k in s) print k "\t" s[k] }' | sort)
      if [ "$mode" = listed ] && [ -n "$req" ]; then
        want=$req
      else
        want=$(printf '%s\n' "$got" | cut -f1 | sed '/^$/d')
      fi
      red= waiting=
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        r=$(printf '%s\n' "$got" | awk -F'\t' -v c="$c" '$1 == c { print $2 }')
        case "$r" in
          success) ;;
          failure) red="$red $c" ;;
          *) waiting="$waiting $c" ;;
        esac
      done <<< "$want"
      if [ -n "$red" ]; then echo "::error::PR #$pr: required check failed:$red"; exit 2; fi
      if [ "$mergeable" = null ]; then
        echo "::notice::PR #$pr: GitHub is still computing mergeability"
      elif [ -n "$waiting" ]; then
        echo "::notice::PR #$pr: waiting for$waiting"
      elif GH_TOKEN="${FACTORY_APP_TOKEN:-${GH_TOKEN:-}}" gh api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=squash >/dev/null; then
        echo "merged PR #$pr"; exit 0
      else
        echo "::notice::merging PR #$pr failed; trying again"
      fi
    else
      errors=$((errors + 1))
    fi
  else
    errors=$((errors + 1))
  fi
  if [ "$errors" -ge 5 ]; then echo "::error::could not read PR #$pr or its checks"; exit 1; fi
  if [ -n "$polls" ] && [ "$n" -ge "$polls" ]; then break; fi
  if [ "$SECONDS" -ge "$deadline" ]; then break; fi
  sleep "$interval"
done
echo "::error::PR #$pr: not merged after waiting ${timeout_min} minutes"
exit 3
