#!/usr/bin/env bash
# Reads the repository's factory settings (.github/factory.yml, docs/config.md) and hands them to the
# workflow steps.
#
#   config.sh [file]   read <file> (default: .github/factory.yml; a missing file means all defaults),
#                      fill in the defaults and write every setting
#                        - to $GITHUB_OUTPUT as <path with . -> _>=<value>   (checks.full -> checks_full)
#                        - to $GITHUB_ENV as FACTORY_<PATH, upper case>=<value> (checks.full -> FACTORY_CHECKS_FULL)
#                        - every `env:` entry to $GITHUB_ENV under its own name
#                      When either variable is unset the lines go to stdout. Exit 2 on an unknown key or a
#                      line this reader does not understand, naming the line.
#
# The file is a small subset of YAML, read without yq: top-level sections of `key: value` pairs two
# spaces in, scalar values (plain, 'single' or "double" quoted, a ` #` comment after a plain value is
# dropped) and `|` blocks (the more indented lines below, indentation removed). Nothing else (lists,
# anchors, flow style, deeper nesting).
set -euo pipefail
file=${1:-.github/factory.yml}

# path|default. A default of @other.path takes that setting's value.
defaults='repository|
base|main
runners.default|ubuntu-latest
runners.implement|@runners.default
runners.verify|@runners.default
setup|
checks.full|
checks.kill|
checks.quick|
git.name|factory[bot]
git.email|41898282+github-actions[bot]@users.noreply.github.com
models.default|claude-sonnet-5-5
models.strong|claude-opus-5-5
models.decompose|@models.strong
models.odin|@models.strong
models.verify|@models.default
turns.implement|200
turns.conflicts|60
turns.fix|80
turns.decompose|120
turns.odin|60
turns.verify|40
labels.scan|.github/'

parsed=''
if [ -f "$file" ]; then
  parsed=$(tr -d '\r' < "$file" | awk -v F="$file" '
    function emit(p, v) { printf "%s\037%s\036", p, v }
    function scalar(v, n) {
      if (v ~ /^"/) { n = match(substr(v, 2), /"/); if (!n) bad("unclosed quote"); return substr(v, 2, n - 1) }
      if (v ~ /^\x27/) { n = match(substr(v, 2), /\x27/); if (!n) bad("unclosed quote"); return substr(v, 2, n - 1) }
      sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); return v
    }
    function bad(why) { printf "%s:%d: %s: %s\n", F, NR, why, $0 > "/dev/stderr"; failed = 1; exit 2 }
    function flush() { if (bpath != "") { sub(/\n+$/, "", bval); emit(bpath, bval); bpath = ""; bval = "" } }
    {
      line = $0
      if (bpath != "") {
        if (line ~ /^[ \t]*$/) { bval = bval "\n"; next }
        match(line, /^ */)
        if (RLENGTH > bind) {
          if (bcut < 0) bcut = RLENGTH
          bval = bval (bval == "" ? "" : "\n") substr(line, bcut + 1); next
        }
        flush()
      }
      if (line ~ /^[ \t]*(#.*)?$/) next
      if (line ~ /\t/) bad("tab in indentation")
      if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) { indent = 0 }
      else if (line ~ /^  [A-Za-z_][A-Za-z0-9_-]*:/) { indent = 2 }
      else bad("not a key: value line")
      key = line; sub(/^ */, "", key); sub(/:.*$/, "", key)
      val = line; sub(/^[^:]*:[ ]*/, "", val)
      if (indent == 0) section = ""
      else if (section == "") bad("indented key outside a section")
      path = (indent == 2 ? section "." key : key)
      if (val ~ /^\|[-+]?[ \t]*(#.*)?$/) { bpath = path; bval = ""; bind = indent; bcut = -1; next }
      if (indent == 0 && val ~ /^[ \t]*(#.*)?$/) { section = key; next }
      emit(path, scalar(val))
    }
    END { if (!failed) flush() }') || exit 2
fi

declare -A value=() known=()
envs=()
while IFS='|' read -r p d; do known[$p]=1; done <<< "$defaults"
while IFS=$'\037' read -r -d $'\036' p v; do
  if [ "${p%%.*}" = env ] && [ "$p" != env ]; then
    name=${p#env.}
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "$file: env name '$name' is not a variable name" >&2; exit 2; }
    envs+=("$name"); value[$p]=$v; continue
  fi
  [ -n "${known[$p]:-}" ] || { echo "$file: unknown setting '$p' (docs/config.md lists them)" >&2; exit 2; }
  value[$p]=$v
done <<< "$parsed"

order=()
while IFS='|' read -r p d; do
  order+=("$p")
  [ -n "${value[$p]+x}" ] && continue
  case $d in @*) value[$p]=${value[${d#@}]-} ;; *) value[$p]=$d ;; esac
done <<< "$defaults"
[ -n "${value[repository]}" ] || value[repository]=${GITHUB_REPOSITORY:-}

out=${GITHUB_OUTPUT:-/dev/stdout}
env_out=${GITHUB_ENV:-/dev/stdout}
put() { # put <file> <name> <value>
  if [[ $3 == *$'\n'* ]]; then
    local eof="EOF_$RANDOM$RANDOM"
    printf '%s<<%s\n%s\n%s\n' "$2" "$eof" "$3" "$eof" >> "$1"
  else
    printf '%s=%s\n' "$2" "$3" >> "$1"
  fi
}
for p in "${order[@]}"; do
  name=${p//./_}
  put "$out" "$name" "${value[$p]}"
  put "$env_out" "FACTORY_$(printf '%s' "${name//-/_}" | tr '[:lower:]' '[:upper:]')" "${value[$p]}"
done
put "$env_out" FACTORY_REPO "${value[repository]}"
put "$env_out" FACTORY_CHECK "${value[checks.full]}"
for e in "${envs[@]}"; do put "$env_out" "$e" "${value[env.$e]}"; done
