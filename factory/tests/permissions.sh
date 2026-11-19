#!/usr/bin/env bash
# Static check of how the reusable workflows use the GitHub App token (docs/permissions.md):
# the token step asks only for contents and pull-requests write, the action is pinned to a commit, and
# the token never reaches gh issue / gh label / gh workflow run / dispatches (those use GITHUB_TOKEN).
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0; n=0
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }
for f in .github/workflows/factory-*.yml; do
  n=$((n + 1))
  while IFS= read -r line; do
    case $line in
      *permission-contents:\ write*|*permission-pull-requests:\ write*) ;;
      *) bad "$f: App token asks for more than contents/pull-requests write: $line" ;;
    esac
  done < <(grep -E '^\s*permission-[a-z-]+:' "$f")
  grep -E 'create-github-app-token@' "$f" | grep -vqE '@[0-9a-f]{40} ' && bad "$f: create-github-app-token is not pinned to a commit"
  grep -nE 'steps\.app\.outputs\.token' "$f" | grep -E 'gh (issue|label|workflow run)|/dispatches|gh api[^|]*-X (POST|PATCH|DELETE)[^|]*/(issues|labels)' \
    && bad "$f: App token used for an issue, label or dispatch call"
done
for f in factory/*.sh; do
  grep -nE 'FACTORY_APP_TOKEN' "$f" | grep -E 'gh (issue|label|workflow run)|dispatches' && bad "$f: App token used for an issue, label or dispatch call"
done
# The checks above must catch a bad workflow.
probe=$(mktemp); printf '          permission-issues: write\n' > "$probe"
grep -E '^\s*permission-[a-z-]+:' "$probe" | grep -vqE 'permission-(contents|pull-requests): write' || bad "self-check: extra permission not caught"
printf '        run: GH_TOKEN=${{ steps.app.outputs.token }} gh issue edit 1\n' > "$probe"
grep -E 'steps\.app\.outputs\.token' "$probe" | grep -qE 'gh (issue|label|workflow run)' || bad "self-check: App token on gh issue not caught"
rm -f "$probe"
echo "permissions: $n workflows, $fail failed"
[ "$fail" -eq 0 ]
