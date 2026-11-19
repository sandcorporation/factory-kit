#!/usr/bin/env bash
# Tests of factory/app-git.sh: app.enabled decides whether a missing App token is an error.
set -u
here=$(cd "$(dirname "$0")" && pwd)
app="$here/../app-git.sh"
fails=0 passes=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
git init -q "$root/r"
cd "$root/r" || exit 1
header() { git config --local --get 'http.https://github.com/.extraheader' 2>/dev/null || true; }

out=$(env -u FACTORY_APP_TOKEN -u FACTORY_APP_ENABLED bash "$app" 2>&1); rc=$?
eq "enabled by default, no token: rc" 1 "$rc"
case "$out" in *"::error::"*) ok ;; *) bad "no error: $out" ;; esac

out=$(env -u FACTORY_APP_TOKEN FACTORY_APP_ENABLED=false bash "$app" 2>&1); rc=$?
eq "disabled, no token: rc" 0 "$rc"
case "$out" in *"::warning::"*) ok ;; *) bad "no warning: $out" ;; esac
eq "disabled leaves the header alone" "" "$(header)"

out=$(FACTORY_APP_TOKEN=t0k FACTORY_APP_ENABLED=true bash "$app" 2>&1); rc=$?
eq "enabled with token: rc" 0 "$rc"
case "$(header)" in "AUTHORIZATION: basic "*) ok ;; *) bad "header not set: $(header)" ;; esac

echo "app-git: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
