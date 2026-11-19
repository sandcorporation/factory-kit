#!/usr/bin/env bash
# Keeps the repository's labels and factory/lib/labels.sh in line with factory/labels.json.
#
#   labels-sync.sh --gen      write factory/lib/labels.sh from labels.json (no network)
#   labels-sync.sh            dry run: print what --apply would do to the repository's labels
#   labels-sync.sh --apply    do it: rename old labels in place (`gh label edit --name`, so issues keep
#                             them), create missing ones, fix colour and description; then print the
#                             diff of the label list before and after
#
# A label that is in `removed` is only reported, never deleted: deleting a label takes it off every
# issue and cannot be undone, so a person does it by hand after reading the report.
#
# Environment: REPO (owner/name, default: the repository of the current directory),
# FACTORY_LABELS (default: labels.json next to this script), LABELS_SNAPSHOT_DIR (where the before and
# after snapshots go, default: a temporary folder).
set -u -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
defs=${FACTORY_LABELS:-$here/labels.json}
mode=dry
case "${1:-}" in
  --gen) mode=gen ;;
  --apply) mode=apply ;;
  "") ;;
  *) echo "usage: labels-sync.sh [--gen | --apply]" >&2; exit 2 ;;
esac

j() { jq "$@" | tr -d '\r'; }

gen() {
  {
    echo '# Generated from factory/labels.json by factory/labels-sync.sh --gen. Do not edit by hand:'
    echo '# tests/labels.sh fails when this file and labels.json disagree.'
    echo '# Scripts read label names only from these variables.'
    j -r '.labels[] | "\(.var)=\(.name)"' "$defs"
    echo '# Exclusive groups: an issue carries at most one label of each.'
    echo "L_EXCLUSIVE_GROUPS=\"$(j -r '[.groups | to_entries[] | select(.value.exclusive) | .key] | join(" ")' "$defs")\""
  } > "$here/lib/labels.sh"
  echo "wrote $here/lib/labels.sh"
}

if [ "$mode" = gen ]; then gen; exit 0; fi

REPO=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner | tr -d '\r')}
snap=${LABELS_SNAPSHOT_DIR:-$(mktemp -d)}
mkdir -p "$snap"

snapshot() { # snapshot <file>
  gh label list --repo "$REPO" --limit 500 --json name,color,description \
    | j -S 'sort_by(.name) | map({name, color: (.color | ascii_downcase), description: (.description // "")})' > "$1"
}

snapshot "$snap/before.json"

# One action per line: rename <old> <new> | create <new> | fix <new> | report <removed>
plan=$(j -r --slurpfile have "$snap/before.json" '
  ($have[0] | map({key: .name, value: .}) | from_entries) as $h
  | (.labels[] | . as $l
      | if $h[$l.name] then
          (if ($h[$l.name].color != ($l.color | ascii_downcase)) or ($h[$l.name].description != $l.description)
           then "fix\t\($l.name)" else empty end)
        else
          ([$l.old[] | select($h[.])] | first) as $o
          | if $o then "rename\t\($o)\t\($l.name)" else "create\t\($l.name)" end
        end),
    (.removed[] | select($h[.name]) | "report\t\(.name)")' "$defs")

if [ -z "$plan" ]; then echo "labels: nothing to do"; exit 0; fi

meta() { # meta <name> <field>
  j -r --arg n "$1" --arg f "$2" '.labels[] | select(.name == $n) | .[$f]' "$defs"
}

while IFS=$'\t' read -r act a b; do
  case $act in
    rename) echo "rename  $a -> $b" ;;
    create) echo "create  $a" ;;
    fix) echo "fix     $a (colour/description)" ;;
    report) echo "remove  $a (by hand: gh label delete \"$a\" --repo $REPO; the factory no longer reads it)" ;;
  esac
  [ "$mode" = apply ] || continue
  case $act in
    rename) gh label edit "$a" --repo "$REPO" --name "$b" --color "$(meta "$b" color)" \
              --description "$(meta "$b" description)" > /dev/null ;;
    create) gh label create "$a" --repo "$REPO" --color "$(meta "$a" color)" \
              --description "$(meta "$a" description)" > /dev/null ;;
    fix) gh label edit "$a" --repo "$REPO" --color "$(meta "$a" color)" \
              --description "$(meta "$a" description)" > /dev/null ;;
  esac || { echo "labels: $act $a failed" >&2; exit 1; }
done <<< "$plan"

if [ "$mode" = dry ]; then echo "(dry run; --apply does it)"; exit 0; fi

snapshot "$snap/after.json"
echo "--- label list diff ($snap/before.json -> after.json)"
diff <(j -r '.[] | "\(.name)\t\(.color)\t\(.description)"' "$snap/before.json") \
     <(j -r '.[] | "\(.name)\t\(.color)\t\(.description)"' "$snap/after.json") || true
