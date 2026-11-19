#!/usr/bin/env bash
# contract.sh [<kit root>]: the kit's promises between code and docs.
#   1. the keys of config.sh's defaults table and the key table of docs/config.md are the same
#   2. the shared nodes exist: app-git.sh refuses app.enabled without a token, merge-pr.sh,
#      spec-tests.sh, human-check.sh
#   3. odin.sh and verify.sh merge through merge-pr.sh and never call `PUT …/merge` themselves
# With no argument it checks this kit and counts as a test (factory/test.sh). The self-test runs it on
# broken copies (FACTORY_CONTRACT_SELFTEST=0 skips that part).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}
problems=0
no() { echo "  contract: $*"; problems=$((problems + 1)); }

code_keys=$(sed -n "/^defaults='/,/'\$/p" "$root/factory/config.sh" | sed "s/^defaults='//; s/'\$//" \
  | cut -d'|' -f1 | sed '/^$/d' | sort -u)
doc_keys=$(sed -n '/^## 키/,/^## /p' "$root/docs/config.md" | sed -n 's/^| `\([a-z_.]*\)` |.*/\1/p' | sort -u)
[ -n "$code_keys" ] || no "no keys in factory/config.sh"
for k in $(comm -23 <(printf '%s\n' "$code_keys") <(printf '%s\n' "$doc_keys")); do no "key $k is not in docs/config.md"; done
for k in $(comm -13 <(printf '%s\n' "$code_keys") <(printf '%s\n' "$doc_keys")); do no "docs/config.md lists $k, config.sh does not"; done

for f in merge-pr.sh spec-tests.sh human-check.sh app-git.sh; do
  [ -f "$root/factory/$f" ] || no "factory/$f is missing"
done
grep -q 'app.enabled is true but FACTORY_APP_TOKEN is not set' "$root/factory/app-git.sh" 2>/dev/null \
  || no "app-git.sh does not refuse app.enabled without a token"

for f in odin.sh verify.sh; do
  grep -q 'merge-pr\.sh' "$root/factory/$f" 2>/dev/null || no "$f does not call merge-pr.sh"
  grep -nE 'PUT[^#]*/merge' "$root/factory/$f" >/dev/null 2>&1 && no "$f calls PUT …/merge itself"
done

if [ -z "${1:-}" ] && [ "${FACTORY_CONTRACT_SELFTEST:-1}" != 0 ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  copy() { rm -rf "$tmp/k"; mkdir -p "$tmp/k"; cp -r "$root/factory" "$root/docs" "$tmp/k/"; }
  broken() { # broken <what>: the copy must fail
    if FACTORY_CONTRACT_SELFTEST=0 bash "$here/contract.sh" "$tmp/k" >/dev/null 2>&1; then no "self-test: $1 was not caught"; fi
  }
  copy; FACTORY_CONTRACT_SELFTEST=0 bash "$here/contract.sh" "$tmp/k" >/dev/null 2>&1 || no "self-test: a clean copy fails"
  copy; sed -i 's/^merge.timeout|20$/merge.timeout|20\nnew.key|x/' "$tmp/k/factory/config.sh"; broken "a key missing from the docs"
  copy; sed -i '/^| `merge.interval` |/d' "$tmp/k/docs/config.md"; broken "a docs row removed"
  copy; rm "$tmp/k/factory/human-check.sh"; broken "a missing node"
  copy; sed -i 's/merge-pr\.sh/merge-x.sh/g' "$tmp/k/factory/odin.sh"; broken "odin not calling merge-pr"
  copy; echo 'gh api -X PUT "repos/$REPO/pulls/1/merge"' >> "$tmp/k/factory/verify.sh"; broken "a direct PUT merge"
fi

if [ "$problems" -eq 0 ]; then echo "contract: 1 passed, 0 failed"; else echo "contract: 0 passed, $problems failed"; fi
[ "$problems" -eq 0 ]
