#!/usr/bin/env bash
# A ticket that changes `.github/workflows/` is not for the factory (ADR-0001, "workflow 파일은 사람 몫"):
# the factory's GITHUB_TOKEN cannot push workflow files. A local worker takes it. So is a ticket a person
# labelled `kind:local` (a decision, a secret or a person's machine).
#
#   local-ticket.sh <issue>
#
# A ticket is local when it carries the `kind:local` label or its title or body mentions `.github/workflows`.
# A local ticket gets `kind:local` (adding a label creates it when missing) and, unless it is already with a
# person, is handed over by hand-to-human.sh (`state:human`, no `state:ready`, one comment
# `<!-- factory-human workflow-change|local-only -->` whose next line is `<!-- factory-local -->`).
# Writes local=true|false to $GITHUB_OUTPUT (stdout when unset); exits 0 unless it cannot read the issue.
# decompose.sh (right after Decompose), odin.sh (before approving) and factory-implementer.yml (the
# `approved` job and the claim) call it, so a ticket that slipped past Decompose is turned around there.
#
# Environment: REPO, GH_TOKEN.
set -u
: "${REPO:?REPO is not set}"
n=${1:?usage: local-ticket.sh <issue>}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/labels.sh"

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_OUTPUT"; else printf '%s\n' "$@"; fi
}

read -r mentions labels < <(gh api "repos/$REPO/issues/$n" --jq '[
  ((.title // "") + "\n" + (.body // "") | contains(".github/workflows") | tostring),
  ([.labels[].name] | join(","))] | @tsv' | tr -d '\r') \
  || { echo "::error::local-ticket: could not read #$n"; exit 1; }
labels=",${labels:-},"
case "$labels" in
  *,"${L_LOCAL}",*) is_local=true ;;
  *) is_local=$mentions ;;
esac
if [ "$is_local" != true ]; then output local=false; exit 0; fi

case "$labels" in *,"${L_LOCAL}",*) ;; *)
  gh api "repos/$REPO/issues/$n/labels" -f "labels[]=${L_LOCAL}" > /dev/null     || echo "::warning::local-ticket: could not add ${L_LOCAL} to #$n" ;;
esac
# hand-to-human.sh takes state:ready off and leaves the marker the bridge mails; once. The code says
# why (#437): a ticket that names `.github/workflows` cannot be pushed by the factory (workflow-change);
# one that is only labelled `kind:local` needs a person's decision, secret or machine (local-only, e.g. #473).
case "$labels" in *,"${L_HUMAN}",*) ;; *)
  if [ "$mentions" = true ]; then
    code=workflow-change
    why='workflow 파일 — 로컬 작업자 몫. 이 티켓은 `.github/workflows/` 를 건드리므로 공장(GITHUB_TOKEN)이 push 할 수 없다. `'"${L_LOCAL}"'` 로 공장 밖에 두고 사람(로컬 작업자)에게 넘긴다.'
  else
    code=local-only
    why='사람 몫 — 사람의 결정·비밀값·사람 기계가 필요한 티켓. `'"${L_LOCAL}"'` 로 공장 밖에 두고 사람에게 넘긴다.'
  fi
  bash "$here/hand-to-human.sh" "$n" "$code" "<!-- factory-local -->
$why" || echo "::warning::local-ticket: could not hand #$n to a human" ;;
esac
output local=true
