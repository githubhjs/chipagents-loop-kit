#!/bin/bash

# goal-gate hook for Claude Code (Stop) and ChipAgents (post_turn)
# Keeps the agent working while the project's goal checklist has open items:
# .claude/goal.md or .chipagents/goal.md, whichever exists first.
#
#   - [ ] open item                     keeps the agent working
#   - [x] done item
#   - [!] blocked item - BLOCKED: why   needs the user; does not keep it working
#
# When no item gets resolved for GOAL_GATE_MAX_STALLS turns in a row
# (default 3), the gate lets the agent stop instead of spinning forever.
# Projects without a goal file are unaffected. Needs only bash.

set -uo pipefail

# Drain the hook input; this hook does not need it.
cat > /dev/null

GOAL_FILE=
for candidate in .claude/goal.md .chipagents/goal.md; do
  if [[ -f "$candidate" ]]; then
    GOAL_FILE="$candidate"
    break
  fi
done
if [[ -z "$GOAL_FILE" ]]; then
  exit 0
fi

STATE_FILE="$(dirname "$GOAL_FILE")/goal-gate.state"
MAX_STALLS="${GOAL_GATE_MAX_STALLS:-3}"

OPEN_ITEMS=$(grep -E '^[[:space:]]*[-*] \[ \]' "$GOAL_FILE")
OPEN_COUNT=$(grep -cE '^[[:space:]]*[-*] \[ \]' "$GOAL_FILE")
RESOLVED_COUNT=$(grep -cE '^[[:space:]]*[-*] \[[xX!]\]' "$GOAL_FILE")

if [[ $OPEN_COUNT -eq 0 ]]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Progress = more items resolved than at the previous check.
PREVIOUS_RESOLVED=$(sed -n 's/^resolved=//p' "$STATE_FILE" 2>/dev/null)
STALLS=$(sed -n 's/^stalls=//p' "$STATE_FILE" 2>/dev/null)
[[ "$STALLS" =~ ^[0-9]+$ ]] || STALLS=0
if [[ "$PREVIOUS_RESOLVED" =~ ^[0-9]+$ ]] && [[ $RESOLVED_COUNT -le $PREVIOUS_RESOLVED ]]; then
  STALLS=$((STALLS + 1))
else
  STALLS=0
fi

if [[ $STALLS -ge $MAX_STALLS ]]; then
  rm -f "$STATE_FILE"
  echo "goal-gate: no checklist item resolved in $MAX_STALLS turns; letting the agent stop. Open items remain in $GOAL_FILE." >&2
  exit 0
fi
printf 'resolved=%s\nstalls=%s\n' "$RESOLVED_COUNT" "$STALLS" > "$STATE_FILE"

# Claude Code feeds stderr of an exit-2 Stop hook back to the model.
# ChipAgents reruns the agent on any non-zero exit of a blocking post_turn
# hook and reports the hook's output, so write there instead.
if [[ -n "${CHIPAGENTS_PLUGIN_ROOT:-}" ]]; then
  exec 3>&1
else
  exec 3>&2
fi
{
  echo "goal-gate: $GOAL_FILE still has $OPEN_COUNT open item(s). Do not stop yet."
  echo
  echo "$OPEN_ITEMS"
  echo
  echo "Work on the next open item now. Tick it (- [x]) only after verifying it with fresh evidence: run the check and read its output."
  echo "If an item truly cannot be done without the user, mark it '- [!] <item> - BLOCKED: <reason and what the user must do>' and move on."
  echo "Never tick, delete or reword an item just to end the loop."
} >&3
exit 2
