#!/usr/bin/env bash
# Fails when a tracked file of the kit contains a forbidden pattern (factory/tests/forbidden-patterns.txt):
# tokens, private addresses, internal host names, and names of private hosts, repositories,
# organisations and people. A user repository's own names come only from its .github/factory.yml.
set -u
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
list="$here/forbidden-patterns.txt"
fails=0

patterns=()
while read -r kind value; do
  case $kind in
    re) patterns+=("$value") ;;
    b64) patterns+=("$(printf '%s' "$value" | base64 -d)") ;;
    ''|'#'*) ;;
    *) echo "  FAIL unknown line in forbidden-patterns.txt: $kind"; fails=$((fails + 1)) ;;
  esac
done < "$list"

# The checker must catch what it is meant to catch.
probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
printf 'ok line\nhost: build-1.example.ts.net\n' > "$probe"
hit=0
for p in "${patterns[@]}"; do grep -qiE -- "$p" "$probe" && hit=1; done
[ "$hit" -eq 1 ] || { echo "  FAIL the patterns miss a planted internal host name"; fails=$((fails + 1)); }

cd "$top"
files=$(git ls-files 2> /dev/null | grep -v -e '^factory/tests/forbidden-patterns.txt$')
[ -n "$files" ] || files=$(find . -type f -not -path './.git/*' | sed 's|^\./||' | grep -v 'forbidden-patterns.txt$')
for p in "${patterns[@]}"; do
  hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -niIE -- "$p" 2> /dev/null || true)
  if [ -n "$hits" ]; then
    echo "  FAIL forbidden pattern found:"
    printf '%s\n' "$hits" | cut -c1-160 | sed 's/^/    /'
    fails=$((fails + 1))
  fi
done

echo "forbidden-words: ${#patterns[@]} patterns, $fails failed"
[ "$fails" -eq 0 ]
