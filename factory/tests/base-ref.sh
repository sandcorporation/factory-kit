#!/usr/bin/env bash
# Static check: workflows and factory scripts take the base branch from the `base` setting
# (FACTORY_BASE, or `config.sh --default base`), never a hard-coded `origin/main` or `refs/heads/main`.
# Comment lines are not checked. factory/tests/ is not checked (fixtures name a branch on purpose).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
fails=0
check() { # check <file>
  local hits
  hits=$(grep -nE 'origin/main([^A-Za-z0-9_-]|$)|refs/heads/main([^A-Za-z0-9_-]|$)|fetch( -q)? origin main([^A-Za-z0-9_-]|$)' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*#') || return 0
  while IFS= read -r h; do echo "  FAIL ${1#"$root"/}:$h"; done <<< "$hits"
  fails=$((fails + 1))
}
for f in "$root"/.github/workflows/*.yml "$root"/factory/*.sh "$root"/factory/lib/*.sh; do
  [ -f "$f" ] && check "$f"
done

# The check itself catches a hard-coded ref and lets comments through.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '# git merge origin/main\n  git rebase origin/main\n' > "$tmp/x.sh"
before=$fails
check "$tmp/x.sh" > "$tmp/out"
if [ "$fails" -eq $((before + 1)) ] && grep -q ':2:' "$tmp/out" && ! grep -q ':1:' "$tmp/out"; then
  fails=$before
else
  echo "  FAIL self-check did not flag line 2 only: $(cat "$tmp/out")"
  fails=$((before + 1))
fi

echo "base-ref: $fails failed"
[ "$fails" -eq 0 ]
