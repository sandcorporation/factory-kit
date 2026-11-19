#!/usr/bin/env bash
# spec-tests.sh: the "not done yet" markers on acceptance tests, in one place.
#
# A ticket's acceptance tests carry a marker until the ticket makes them pass (default: rust
# `#[ignore = "#N"]`). The marker is an extended regex with `{n}` standing for the ticket number:
#   acceptance.marker   FACTORY_ACCEPTANCE_MARKER   the marker for every file (default `#\[ignore = "#{n}"\]`)
#   acceptance.markers  FACTORY_ACCEPTANCE_MARKERS  optional pairs, one per line: `<glob> <regex>`; a file
#                                                   matching <glob> uses that regex instead. When pairs are
#                                                   set, only files matching one of their globs are searched.
#   acceptance.glob     FACTORY_ACCEPTANCE_GLOB     where the acceptance tests live (space-separated globs)
#
# Commands:
#   spec-tests.sh left <N> [<rev>]   print `file:line:text` of every marker of ticket N still there, in
#                                    <rev> (git grep of that commit) or the work tree (tracked and untracked
#                                    files) when <rev> is left out. Exit 0 when one was found, 1 when none.
#   spec-tests.sh is-marker <N|any> <file> <line>
#                                    exit 0 when <line> (trimmed) is a marker of ticket N (any: of any ticket)
#                                    for <file>, 1 otherwise.
#   spec-tests.sh text <N>           the marker of ticket N as plain text (regex escapes removed), for messages.
#   spec-tests.sh globs              the acceptance globs, one per line.
# Run inside the repository (FACTORY_ROOT, when set, is used instead of the current directory).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
marker=${FACTORY_ACCEPTANCE_MARKER:-$(bash "$here/config.sh" --default acceptance.marker)}
pairs=${FACTORY_ACCEPTANCE_MARKERS-}
globs=${FACTORY_ACCEPTANCE_GLOB:-$(bash "$here/config.sh" --default acceptance.glob)}
root=${FACTORY_ROOT:-.}

# regex <template> <N|any>
regex() { local t=$1 n=$2; [ "$n" = any ] && n='[0-9]+'; printf '%s' "${t//\{n\}/$n}"; }

# pair lines: "<glob>\t<regex>"
pair_lines() { printf '%s\n' "$pairs" | tr -d '\r' | sed -n 's/^[[:space:]]*\([^[:space:]]\{1,\}\)[[:space:]]\{1,\}\(.*[^[:space:]]\)[[:space:]]*$/\1\t\2/p'; }

# marker_for <file>: the regex template for that file ("" when pairs are set and none matches).
marker_for() {
  local f=$1 g r
  [ -n "$(pair_lines)" ] || { printf '%s' "$marker"; return; }
  while IFS=$'\t' read -r g r; do
    # shellcheck disable=SC2053 # the glob is a pattern on purpose
    [[ $f == $g ]] && { printf '%s' "$r"; return; }
  done < <(pair_lines)
}

case ${1:-} in
  left)
    n=${2:?ticket number}; rev=${3:-}
    found=1
    run_grep() { # run_grep <regex> <pathspec...>
      local re=$1; shift
      if [ -n "$rev" ]; then
        git -C "$root" grep -n -E -e "$re" "$rev" -- "$@" | sed "s/^$rev://"
      else
        git -C "$root" grep -n -E --untracked -e "$re" -- "$@"
      fi
    }
    if [ -z "$(pair_lines)" ]; then
      out=$(run_grep "$(regex "$marker" "$n")" . || true)
    else
      out=$(while IFS=$'\t' read -r g r; do run_grep "$(regex "$r" "$n")" ":(glob)$g" || true; done < <(pair_lines))
    fi
    out=$(printf '%s\n' "$out" | sed '/^$/d' | sort -u)
    [ -n "$out" ] && { printf '%s\n' "$out"; found=0; }
    exit $found ;;
  is-marker)
    n=${2:?ticket number or any}; f=${3:?file}; line=${4-}
    t=$(marker_for "$f")
    [ -n "$t" ] || exit 1
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s\n' "$trimmed" | grep -Eq "^($(regex "$t" "$n"))\$" ;;
  text)
    n=${2:?ticket number}
    printf '%s\n' "$(regex "$marker" "$n")" | sed 's/\\\(.\)/\1/g' ;;
  globs)
    set -f
    # shellcheck disable=SC2086 # split on spaces, no expansion
    printf '%s\n' $globs ;;
  *) echo "usage: spec-tests.sh left <N> [<rev>] | is-marker <N|any> <file> <line> | text <N> | globs" >&2; exit 2 ;;
esac
