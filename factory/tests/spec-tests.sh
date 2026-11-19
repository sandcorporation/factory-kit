#!/usr/bin/env bash
# Tests of factory/spec-tests.sh in a throwaway git repository.
set -u
here=$(cd "$(dirname "$0")" && pwd)
st="$here/../spec-tests.sh"
fails=0 passes=0
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
r=$(mktemp -d); trap 'rm -rf "$r"' EXIT
git -C "$r" init -q && mkdir -p "$r/crates/a/tests" "$r/web/tests"
printf '#[test]\n#[ignore = "#5"]\nfn a() {}\n' > "$r/crates/a/tests/spec_a.rs"
printf "test.skip('#5', () => {})\n" > "$r/web/tests/spec.test.ts"
git -C "$r" add . && git -C "$r" -c user.name=t -c user.email=t@t commit -qm x
export FACTORY_ROOT="$r"
unset FACTORY_ACCEPTANCE_MARKER FACTORY_ACCEPTANCE_MARKERS FACTORY_ACCEPTANCE_GLOB

eq "left default" "crates/a/tests/spec_a.rs:2:#[ignore = \"#5\"]" "$(bash "$st" left 5)"
bash "$st" left 6 >/dev/null; eq "left none" 1 $?
eq "left at rev" "crates/a/tests/spec_a.rs:2:#[ignore = \"#5\"]" "$(bash "$st" left 5 HEAD)"
bash "$st" is-marker 5 crates/a/tests/spec_a.rs '  #[ignore = "#5"] '; eq "is-marker" 0 $?
bash "$st" is-marker any x.rs '#[ignore = "#12"]'; eq "is-marker any" 0 $?
bash "$st" is-marker 5 x.rs '#[ignore = "#6"]'; eq "other ticket" 1 $?
eq "text" '#[ignore = "#5"]' "$(bash "$st" text 5)"

export FACTORY_ACCEPTANCE_MARKERS="crates/*/tests/*.rs #\[ignore = \"#{n}\"\]
web/tests/*.ts test\.skip\('#{n}'"
eq "pairs find both" 2 "$(bash "$st" left 5 | wc -l | tr -d ' ')"
bash "$st" is-marker 5 web/tests/spec.test.ts "test.skip('#5'"; eq "pair marker" 0 $?
bash "$st" is-marker 5 other/x.rs '#[ignore = "#5"]'; eq "no pair for file" 1 $?

FACTORY_ACCEPTANCE_GLOB='crates/*/tests/spec_*.rs web/tests/*.test.ts' bash "$st" globs > "$r/g"
eq "globs" 2 "$(wc -l < "$r/g" | tr -d ' ')"
eq "glob kept literal" 'crates/*/tests/spec_*.rs' "$(head -1 "$r/g" | tr -d '\r')"

echo "spec-tests: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
