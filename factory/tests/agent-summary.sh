#!/usr/bin/env bash
# Tests of .github/factory/agent-summary.sh (the conflict agent's run summary, #434).
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../agent-summary.sh"
root=$(mktemp -d)
trap 'rm -r "$root"' EXIT
passes=0 fails=0 current=
ok() { passes=$((passes + 1)); }
bad() { echo "  FAIL [$current] $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1: [$2] is in [$3]" ;; *) ok ;; esac; }

# log <entries...>: an execution file (a JSON array) made of the given JSON entries
log() { local IFS=,; printf '[%s]' "$*" > "$root/exec.json"; }
bash_call() { jq -cn --arg c "$1" --argjson bg "${2:-false}" \
  '{type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: $c, run_in_background: $bg}}]}}'; }
text() { jq -cn --arg t "$1" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}'; }
result() { jq -cn --arg t "$1" '{type: "result", result: $t, total_cost_usd: 1}'; }
run() { out=$(REDACT_VARS="SECRET_A" SECRET_A="${SECRET_A:-}" bash "$script" "$root/exec.json" 2>&1); code=$?; }

current="last message and commands"
log "$(text 'looking')" "$(bash_call 'git status')" "$(bash_call 'cargo xtask ci' true)" "$(text 'done thinking')" "$(result 'Resolved both conflicts.
cargo xtask ci passed.')"
run
eq exit 0 "$code"
has "result text" "> Resolved both conflicts." "$out"
has "second line quoted" "> cargo xtask ci passed." "$out"
hasnt "earlier text" "looking" "$out"
has "count" "Bash commands (2)" "$out"
has "command" '- `git status`' "$out"
has "background" '- `[background] cargo xtask ci`' "$out"

current="without a result entry the last assistant text counts"
log "$(text 'first')" "$(text 'I stopped here')"
run
has "text" "> I stopped here" "$out"
has "no commands" "(none)" "$out"

current="a command is cut to 200 characters and kept on one line"
long=$(printf 'x%.0s' $(seq 1 300))
log "$(bash_call "echo a
$long")"
run
line=$(printf '%s\n' "$out" | grep '^- `echo a')
eq "length" $((200 + 4)) "${#line}"

current="secret values and token shapes are taken out"
export SECRET_A=s3cr3t-value-123
log "$(bash_call "curl -H 'Authorization: $SECRET_A' x")" "$(bash_call 'git push https://x:ghp_abcdefghijklmnop1234@github.com/o/r')" \
  "$(result 'token sk-ant-oat01-abcdefghij gho_ABCDEFGHIJKL and github_pat_11ABCDEFGH_xyz')"
run
hasnt "env value" "s3cr3t" "$out"
hasnt "ghp" "ghp_abc" "$out"
hasnt "gho" "gho_ABC" "$out"
hasnt "sk-" "sk-ant" "$out"
hasnt "github_pat" "github_pat_11" "$out"
has "masked" "Authorization: ***" "$out"
unset SECRET_A

current="no execution file"
rm -f "$root/exec.json"
run
eq exit 0 "$code"
has "says so" "(no execution file)" "$out"

current="a broken execution file does not fail"
printf 'not json' > "$root/exec.json"
run
eq exit 0 "$code"
has "says so" "(could not read the execution file)" "$out"

echo "agent-summary: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
