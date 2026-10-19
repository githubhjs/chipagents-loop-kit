#!/bin/bash

# nonstop post_turn hook for ChipAgents (Claude Code uses nonstop.sh).
# Port of andylizf/nonstop. ChipAgents' hook input carries no session id,
# so the flags are project-scoped and live in .chipagents/:
#   nonstop.activate    written by the agent once the user confirms pre-flight
#   nonstop.active      created here at the next turn end
#   nonstop.deactivate  written by the agent to end nonstop mode
# A nudge exits non-zero, which makes ChipAgents rerun the agent.

set -uo pipefail

# Drain the hook input; this hook does not need it.
cat > /dev/null

STATE_DIR=".chipagents"
NONSTOP_MAX="${NONSTOP_MAX:-5}"  # max nudges before auto-deactivation; 0 = unlimited
active_file="$STATE_DIR/nonstop.active"
counter_file="$STATE_DIR/nonstop.count"

if [[ -f "$STATE_DIR/nonstop.deactivate" ]]; then
  rm -f "$STATE_DIR/nonstop.deactivate" "$active_file" "$counter_file"
  exit 0
fi

if [[ -f "$STATE_DIR/nonstop.activate" ]]; then
  rm -f "$STATE_DIR/nonstop.activate"
  touch "$active_file"
fi

[[ -f "$active_file" ]] || exit 0

count=$(cat "$counter_file" 2> /dev/null || true)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))
echo "$count" > "$counter_file"

if [[ $NONSTOP_MAX -gt 0 ]] && [[ $count -gt $NONSTOP_MAX ]]; then
  rm -f "$active_file" "$counter_file"
  echo "nonstop: auto-deactivated after $NONSTOP_MAX nudges. Summarize what was completed, what used workarounds, and what is blocked."
  exit 0
fi

cat << 'EOF'
[nonstop mode — nudge] Do NOT stop. Follow the nonstop protocol:

1. CHECK TASKS: Review your task list (.chipagents/goal.md if it exists). Is every task completed?
2. IF BLOCKED on something:
   a. Can you solve it yourself? (search code, read docs, fix errors) → Do it.
   b. Can you work around it WITHOUT changing the outcome? → Do it, update the task with what you did.
   c. Is it a HIGH-RISK op not pre-approved? → Mark the task as blocked, move to the next task.
   d. Truly stuck on everything? → Deactivate nonstop: touch .chipagents/nonstop.deactivate
3. FOR LONG-RUNNING OPS: Hand them to a subagent, don't block.
4. NEVER: brute-force retry, disable safety checks, guess credentials, or take destructive actions not pre-approved.

Keep working.
EOF
exit 1
