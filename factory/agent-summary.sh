#!/usr/bin/env bash
# Markdown for the run summary of an agent step (factory-implementer.yml, "Conflict agent summary";
# #434): the agent's last words and the shell commands it ran, from the action's execution file.
#
#   agent-summary.sh <execution file> >> "$GITHUB_STEP_SUMMARY"
#
# Only those two: the full log carries tool output and stays off this public repository. Each command
# is cut to 200 characters. Before anything is printed, the values of the environment variables named
# in REDACT_VARS (space separated, default `CLAUDE_CODE_OAUTH_TOKEN GITHUB_TOKEN GH_TOKEN`) and token
# shapes (ghp_ gho_ ghs_ ghu_ github_pat_ sk-…) are replaced with `***`. A missing or unreadable file
# prints a line saying so; the script always exits 0 (the summary must not fail the run).
set -u
f=${1:?usage: agent-summary.sh <execution file>}
echo '### Conflict agent'
if [ ! -s "$f" ]; then echo; echo '(no execution file)'; exit 0; fi
REDACT_VARS=${REDACT_VARS-CLAUDE_CODE_OAUTH_TOKEN GITHUB_TOKEN GH_TOKEN} jq -r '
  def secrets: [$ENV.REDACT_VARS | splits(" +") | select(. != "") | $ENV[.] // empty | select(length >= 4)];
  def clean: reduce secrets[] as $s (.; split($s) | join("***"))
    | gsub("(gh[opsu]_|github_pat_)[A-Za-z0-9_]{8,}"; "***")
    | gsub("sk-[A-Za-z0-9_-]{8,}"; "***");
  (if type == "array" then . else [.] end) as $all
  | ([$all[] | select(.type == "result") | .result // empty | strings] | last) as $result
  | ([$all[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last) as $text
  | ($result // $text // "(no final message)") as $last
  | [$all[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "Bash")
      | (if .input.run_in_background then "[background] " else "" end)
        + (.input.command // "" | gsub("\r?\n"; " ") | .[0:200])] as $cmds
  | "", "#### Last message", "", ($last | clean | split("\n") | map("> " + .) | join("\n")),
    "", "#### Bash commands (\($cmds | length))", "",
    (if ($cmds | length) == 0 then "(none)" else ($cmds[] | clean | "- `" + gsub("`"; "ˋ") + "`") end)
' "$f" 2> /dev/null || { echo; echo '(could not read the execution file)'; }
exit 0
