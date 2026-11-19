#!/usr/bin/env bash
# human-check.sh <spec>: may the finished spec be closed, or must a person check it first?
#
# human_check.enabled (FACTORY_HUMAN_CHECK_ENABLED, default false, docs/config.md). When false, the spec
# may close (exit 0). When true, the first call puts the `wait:check` label on the spec and posts the
# `<!-- factory-human-check SPEC -->` comment (the bridge mails it like wait:check) and keeps it open
# (exit 1). The spec stays open while the label is on; once a person removes it (after the marker
# comment), the spec may close (exit 0). dispatch-next.sh calls this before it closes a spec whose
# tickets are all done (docs/config.md, "human check").
#
# Exit codes: 0 may close, 1 keep open (waiting for a person), 2 usage or a GitHub call failed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/labels.sh"
[ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]] || { echo "usage: human-check.sh <spec>" >&2; exit 2; }
s=$1
REPO=${REPO:-${FACTORY_REPO:-${GITHUB_REPOSITORY:-}}}
[ -n "$REPO" ] || { echo "human-check.sh: no repository" >&2; exit 2; }
enabled=${FACTORY_HUMAN_CHECK_ENABLED:-$(bash "$here/config.sh" --default human_check.enabled)}
[ "$enabled" = true ] || exit 0
marker='<!-- factory-human-check SPEC -->'

labels=$(gh issue view "$s" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")') || exit 2
labels=$(printf '%s' "$labels" | tr -d '\r')
case ",$labels," in *",$L_CHECK,"*)
  echo "::notice::spec #$s is waiting for a person to check it ($L_CHECK)"; exit 1 ;;
esac
comments=$(gh api "repos/$REPO/issues/$s/comments?per_page=100" --paginate) || exit 2
asked=$(printf '%s' "$comments" | jq -s --arg m "$marker" '[.[][] | select(.body | contains($m))] | length' | tr -d '\r') || exit 2
if [ "${asked:-0}" -gt 0 ]; then
  echo "spec #$s was checked by a person"; exit 0
fi
gh issue edit "$s" --repo "$REPO" --add-label "$L_CHECK" >/dev/null || exit 2
gh api -X POST "repos/$REPO/issues/$s/comments" -f body="$marker
All tickets of this spec are done. A person checks the result before the spec is closed:

- [ ] checked

Remove the \`$L_CHECK\` label when done; the factory then closes this spec." >/dev/null || exit 2
echo "::notice::spec #$s: asked a person to check it ($L_CHECK)"
exit 1
