#!/usr/bin/env bash
# Gate and alert of the hourly benchmark workflow (.github/workflows/bench.yml, #366).
#
#   bench-gate.sh check <sha>
#       Prints `run=true` when <sha> differs from the head_sha of the last successful run of the
#       benchmark workflow on main (or there is none), else `run=false`, plus `last=<that sha>` (empty
#       when there is none). The workflow appends this to $GITHUB_OUTPUT. A skipped run also succeeds
#       with the same sha, so it keeps the answer; a failed benchmark run does not, so the next hour
#       runs the same sha again (and does not alert twice, below).
#
#   bench-gate.sh alert <sha> <run url> <log file>
#       The benchmark failed at <sha>. Comments once per sha on the open issue labelled `bench-alert`
#       (opened when there is none) with the marker `<!-- factory-bench-regression <sha> -->`, the
#       commit range from the last successful run, the run link and the failing lines of <log file>
#       (the limit lines; the end of the log when none matches). bridge.sh mails the marker to the
#       coordinator. A comment with that marker by github-actions[bot] already there means "alerted".
#
# Environment: FACTORY_REPO owner/name (default sandcorporation/facet), BENCH_WORKFLOW the workflow file
# (default bench.yml). gh must be logged in. Needs bash, gh and jq.
set -u -o pipefail
REPO=${FACTORY_REPO:-sandcorporation/facet}
WORKFLOW=${BENCH_WORKFLOW:-bench.yml}
LABEL=bench-alert

# last_success: head_sha of the newest successful run of the workflow on main, or nothing.
last_success() {
  gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?branch=main&status=success&per_page=1" \
    --jq '.workflow_runs[0].head_sha // ""' | tr -d '\r'
}

case "${1:-}" in
  check)
    sha=${2:?usage: bench-gate.sh check <sha>}
    last=$(last_success) || { echo "bench-gate: could not read the runs of $WORKFLOW" >&2; exit 1; }
    if [ -n "$last" ] && [ "$last" = "$sha" ]; then
      echo "bench-gate: $sha was benchmarked already; skipping" >&2
      echo "run=false"
    else
      echo "bench-gate: last success ${last:-none}, now $sha; running" >&2
      echo "run=true"
    fi
    echo "last=$last"
    ;;
  alert)
    [ $# -eq 4 ] || { echo "usage: bench-gate.sh alert <sha> <run url> <log file>" >&2; exit 2; }
    sha=$2 url=$3 log=$4
    marker="<!-- factory-bench-regression $sha -->"
    last=$(last_success) || last=

    n=$(gh api "repos/$REPO/issues?labels=$LABEL&state=open&per_page=100" \
      --jq '[.[] | select(.pull_request | not)] | sort_by(.number) | .[0].number // ""' | tr -d '\r') \
      || { echo "bench-gate: could not list the $LABEL issues" >&2; exit 1; }
    if [ -z "$n" ]; then
      n=$(gh api "repos/$REPO/issues" -f "title=벤치 한도 알림" -f "labels[]=$LABEL" \
        -f "body=전체 벤치(\`.github/workflows/bench.yml\`)가 한도를 넘으면 이 이슈에 표지 댓글이 달리고 알림 다리가 조율자에게 보낸다." \
        --jq '.number' | tr -d '\r') || { echo "bench-gate: could not open the $LABEL issue" >&2; exit 1; }
      echo "bench-gate: opened #$n"
    fi

    already=$(gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
      --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | contains(\"$marker\"))) | .id" \
      | tr -d '\r') || { echo "bench-gate: could not read the comments of #$n" >&2; exit 1; }
    if [ -n "$already" ]; then
      echo "bench-gate: $sha was alerted already on #$n"
      exit 0
    fi

    if [ -n "$last" ]; then
      range="\`$last..$sha\` (https://github.com/$REPO/compare/$last...$sha)"
    else
      range="\`$sha\` (성공한 벤치 run이 아직 없음)"
    fi
    lines=
    if [ -f "$log" ]; then
      lines=$(grep -E '상한 초과|하한 미달|단계 실패|단계를 실행하지 못함|panicked' "$log" | head -n 40)
      [ -n "$lines" ] || lines=$(tail -n 20 "$log")
    fi
    [ -n "$lines" ] || lines="(벤치 출력이 없음: run 로그를 본다)"
    body="$marker
전체 벤치가 실패했다.

- 커밋 구간: $range
- run: $url

\`\`\`
$lines
\`\`\`"
    gh api "repos/$REPO/issues/$n/comments" -f "body=$body" > /dev/null \
      || { echo "bench-gate: could not comment on #$n" >&2; exit 1; }
    echo "bench-gate: alerted $sha on #$n"
    ;;
  *)
    echo "usage: bench-gate.sh check <sha> | alert <sha> <run url> <log file>" >&2
    exit 2
    ;;
esac
