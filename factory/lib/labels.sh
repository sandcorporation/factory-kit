# Generated from factory/labels.json by factory/labels-sync.sh --gen. Do not edit by hand:
# tests/labels.sh fails when this file and labels.json disagree.
# Scripts read label names only from these variables.
L_READY=state:ready
L_RUNNING=state:running
L_HUMAN=state:human
L_DEFERRED=state:deferred
L_DECISION=wait:decision
L_BUDGET=wait:budget
L_CHECK=wait:check
L_SPEC=kind:spec
L_LEDGER=kind:ledger
L_LOCAL=kind:local
L_STRONG=model:strong
L_BENCH_ALERT=bench-alert
# Exclusive groups: an issue carries at most one label of each.
L_EXCLUSIVE_GROUPS="state kind model"
