#!/usr/bin/env bash
# Fails when a tracked file of the kit contains a forbidden pattern (factory/tests/forbidden-patterns.txt):
# tokens, private addresses, internal host names, and names of private hosts, repositories,
# organisations and people. A user repository's own names come only from its .github/factory.yml.
# Every tracked file is read, docs/ and examples/ included; only the pattern list itself is left out.
set -u
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
list="$here/forbidden-patterns.txt"
fails=0

patterns=()
allows=()
while read -r kind value; do
  case $kind in
    re) patterns+=("$value") ;;
    b64) patterns+=("$(printf '%s' "$value" | base64 -d)") ;;
    allow) allows+=("$(printf '%s' "$value" | base64 -d | tr 'A-Z' 'a-z')") ;;
    ''|'#'*) ;;
    *) echo "  FAIL unknown line in forbidden-patterns.txt: $kind"; fails=$((fails + 1)) ;;
  esac
done < "$list"

# still_hits <ERE> <line>: the line matches the pattern even with every allowed string taken out
# (case is ignored). An allowed string is a public name a forbidden name is part of (the kit's slug).
still_hits() {
  local low a
  low=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
  for a in "${allows[@]}"; do low=${low//"$a"/}; done
  printf '%s\n' "$low" | grep -qiE -- "$1"
}

# The checker must catch what it is meant to catch.
probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
planted='host: build-1.example.ts''.net'
printf 'ok line\n%s\n' "$planted" > "$probe"
hit=0
for p in "${patterns[@]}"; do grep -qiE -- "$p" "$probe" && hit=1; done
[ "$hit" -eq 1 ] || { echo "  FAIL the patterns miss a planted internal host name"; fails=$((fails + 1)); }
# An allowed string alone passes; a forbidden name on the same line still fails.
for a in "${allows[@]}"; do
  for p in "${patterns[@]}"; do
    still_hits "$p" "uses: $a/x.yml" && { echo "  FAIL an allowed string is still reported"; fails=$((fails + 1)); }
  done
  hit=0
  for p in "${patterns[@]}"; do still_hits "$p" "uses: $a/x.yml $planted" && hit=1; done
  [ "$hit" -eq 1 ] || { echo "  FAIL an allowed string hides a forbidden one on the same line"; fails=$((fails + 1)); }
done

cd "$top"
files=$(git ls-files 2> /dev/null | grep -v -e '^factory/tests/forbidden-patterns.txt$')
[ -n "$files" ] || files=$(find . -type f -not -path './.git/*' | sed 's|^\./||' | grep -v 'forbidden-patterns.txt$')
for p in "${patterns[@]}"; do
  hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -niIE -- "$p" 2> /dev/null || true)
  if [ -n "$hits" ] && [ "${#allows[@]}" -gt 0 ]; then
    kept=""
    while IFS= read -r h; do still_hits "$p" "$h" && kept+="$h"$'\n'; done <<< "$hits"
    hits=${kept%$'\n'}
  fi
  if [ -n "$hits" ]; then
    echo "  FAIL forbidden pattern found:"
    printf '%s\n' "$hits" | cut -c1-160 | sed 's/^/    /'
    fails=$((fails + 1))
  fi
done

echo "forbidden-words: ${#patterns[@]} patterns, ${#allows[@]} allowed, $fails failed"
[ "$fails" -eq 0 ]
