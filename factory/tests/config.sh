#!/usr/bin/env bash
# Tests factory/config.sh: defaults, overrides, quoting, blocks, env entries, refusals.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg="$here/../config.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
passes=0 fails=0
ok() { passes=$((passes + 1)); }
bad() { fails=$((fails + 1)); echo "  FAIL $*"; }
eq() { [ "$2" = "$3" ] && ok || bad "$1: want [$2] got [$3]"; }
run() { # run <yaml text or -> ; sets $code, $root/out, $root/env
  : > "$root/out"; : > "$root/env"
  if [ "$1" = - ]; then f="$root/none.yml"; else printf '%s' "$1" > "$root/f.yml"; f="$root/f.yml"; fi
  GITHUB_REPOSITORY=own/repo GITHUB_OUTPUT="$root/out" GITHUB_ENV="$root/env" bash "$cfg" "$f" 2> "$root/err"
  code=$?
}
get() { grep -m1 "^$1=" "$root/$2" | cut -d= -f2-; }

run -
eq "missing file exit" 0 "$code"
eq "default base" main "$(get base out)"
eq "default runner" ubuntu-latest "$(get runners_implement out)"
eq "default strong model" claude-opus-5-5 "$(get models_odin out)"
eq "repository from GitHub" own/repo "$(get FACTORY_REPO env)"
eq "default scan" .github/ "$(get FACTORY_LABELS_SCAN env)"
eq "default cache is off" "" "$(get FACTORY_CACHE env)"
grep -q "^FACTORY_CACHE=$" "$root/env" && ok || bad "FACTORY_CACHE not written"
eq "default acceptance glob" 'crates/*/tests/spec_*.rs' "$(get FACTORY_ACCEPTANCE_GLOB env)"
eq "default acceptance glob output" 'crates/*/tests/spec_*.rs' "$(get acceptance_glob out)"
eq "default base env" main "$(get FACTORY_BASE env)"

run $'acceptance:\n  glob: "tests/acceptance/*.py"\n'
eq "glob override exit" 0 "$code"
eq "glob override" 'tests/acceptance/*.py' "$(get FACTORY_ACCEPTANCE_GLOB env)"

# --default: one definition shared by scripts that run without the config env.
eq "--default base" main "$(bash "$cfg" --default base)"
eq "--default git.name" 'factory[bot]' "$(bash "$cfg" --default git.name)"
eq "--default follows @refs" claude-opus-5-5 "$(bash "$cfg" --default models.odin)"
eq "--default glob" 'crates/*/tests/spec_*.rs' "$(bash "$cfg" --default acceptance.glob)"
bash "$cfg" --default no.such 2> /dev/null; eq "--default unknown exit" 2 "$?"

run $'# c\nrepository: a/b\nbase: trunk   # comment\ncache: rust\nrunners:\n  default: big\nchecks:\n  full: "make check # all"\n  kill: \'x.exe\'\nmodels:\n  strong: s1\nenv:\n  FOO: 1\n'
eq "exit" 0 "$code"
eq "repository" a/b "$(get FACTORY_REPO env)"
eq "plain value drops comment" trunk "$(get base out)"
eq "runner follows default" big "$(get runners_verify out)"
eq "double quotes keep #" "make check # all" "$(get checks_full out)"
eq "check alias" "make check # all" "$(get FACTORY_CHECK env)"
eq "single quotes" x.exe "$(get checks_kill out)"
eq "decompose follows strong" s1 "$(get models_decompose out)"
eq "verify model follows default" claude-sonnet-5-5 "$(get models_verify out)"
eq "env entry" 1 "$(get FOO env)"
eq "cache" rust "$(get FACTORY_CACHE env)"

run $'setup: |\n  one\n\n    two\nbase: x\n'
eq "block exit" 0 "$code"
want=$'one\n\n  two'
got=$(awk '/^setup<</{d=substr($0,8); f=1; next} f && $0==d {exit} f' "$root/out")
eq "block value" "$want" "$got"
eq "after block" x "$(get base out)"

run $'checks:\n  ful: x\n'
eq "unknown key exit" 2 "$code"
grep -q "checks.ful" "$root/err" && ok || bad "unknown key named: $(cat "$root/err")"
run $'runners:\n  - a\n'
eq "list refused" 2 "$code"
run $'  base: x\n'
eq "indent outside section refused" 2 "$code"
run $'env:\n  9X: 1\n'
eq "bad env name refused" 2 "$code"

echo "config: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
