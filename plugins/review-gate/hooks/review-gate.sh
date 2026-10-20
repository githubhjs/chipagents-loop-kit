#!/bin/bash

# review-gate: post_turn peer-review gate for ChipAgents.
#
# Runs a read-only reviewer (`chipagents batch`) over this turn's changes and,
# when the reviewer objects, exits non-zero so ChipAgents reruns the agent with
# the findings. Design and measurements: Josh_HUANG, ChipAgents 0.42.3,
# 2026-10-16/19; see docs/chipagents-hook-mechanics.md.
#
# Opt-in, because a reviewer costs an LLM call on every turn:
#   REVIEW_GATE=1                    turn the gate on
#   REVIEW_GATE_PATHS="rtl tb"       review scope (required; see review-context.sh)
# Optional:
#   REVIEW_GATE_CHIPAGENTS=<path>    chipagents binary (default: chipagents on PATH;
#                                    use the same version that runs your sessions)
#   REVIEW_GATE_THINKING=low         reviewer thinking level
#   REVIEW_GATE_TIMEOUT=300          seconds for the reviewer run
#   REVIEW_GATE_KEEP=<dir>           keep each prompt and verdict there
#   REVIEW_GATE_TRACE=<file>         append one line per decision
#
# WHY A bash HOOK AND NOT AN agent HOOK
# The obvious design is type = "agent" on post_turn with the reviewer replying
# {"block": true, ...}. Measured on 2026-10-19 it does nothing at all:
# validate parses it, but its command never runs (absolute-path probe), no
# restart happens, and token usage is identical to the same run without it,
# while a bash hook in the same file ran as a positive control. So the
# reviewer is started from here, and the verdict is reported the one way that
# is measured to rerun the agent: a NON-ZERO EXIT with the findings on stdout.
#
# No JSON is emitted, which also avoids the multi-line escaping trap: a raw
# newline inside a JSON string makes the reply unparseable, and an
# unparseable block is ignored.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

trace() {
  [[ -n "${REVIEW_GATE_TRACE:-}" ]] || return 0
  printf '%s  %s\n' "$(date +%H:%M:%S)" "$1" >> "$REVIEW_GATE_TRACE" 2> /dev/null
}

# Read stdin first in every path, so ChipAgents never writes into a closed pipe.
INPUT=$(cat 2> /dev/null || true)

# RECURSION AND INNER RUNS. This hook starts `chipagents batch`, and that child
# loads the same hooks (measured: the child's trace shows inner-skip), so its
# post_turn would start another reviewer, forever. The child inherits these
# variables, which stops it. CHIPAGENTS_HOOKS_INNER is the shared flag the
# other gates in this kit honour too (chip-swarm sets it for read-only runs).
if [[ -n "${REVIEW_GATE_INNER:-}" || -n "${CHIPAGENTS_HOOKS_INNER:-}" ]]; then
  trace "inner-skip: recursion guard held"
  exit 0
fi

[[ -n "${REVIEW_GATE:-}" ]] || exit 0
trace "fired cwd=$(pwd)"

PY=
for candidate in python3 python; do
  if command -v "$candidate" > /dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

# Recover the request this turn was answering, so the reviewer can tell a
# defect from something the user asked for explicitly. Measured 2026-10-19:
# without it a real reviewer blocked three rounds in a row over a file whose
# whole content was the word TODO, while the user had asked, verbatim, for a
# file containing the single line TODO.
#
# post_turn payload (measured):
#   {"user_message":"Last turn transcript:\nUser:\n<request>\n---\n\nAssistant:..."}
extract_request() {
  if [[ -n "$PY" ]]; then
    printf '%s' "$INPUT" | "$PY" -c 'import json, re, sys
try:
    m = json.load(sys.stdin).get("user_message", "")
except Exception:
    sys.exit(1)
parts = re.split(r"^User:[ \t]*$", m, maxsplit=1, flags=re.M)
if len(parts) < 2:
    sys.exit(1)
body = re.split(r"^---[ \t]*$", parts[1], maxsplit=1, flags=re.M)[0].strip()
if not body:
    sys.exit(1)
print(body)' 2> /dev/null && return 0
  fi
  # Without a JSON parser: unescape \n and take the User block. Imprecise on
  # quotes, which is acceptable because the consumer is an LLM.
  printf '%s' "$INPUT" | sed -e 's/\\n/\
/g' | awk '/^User:/ { f = 1; next } /^---/ { if (f) exit } f' | sed '/^[[:space:]]*$/d'
}

CA="${REVIEW_GATE_CHIPAGENTS:-chipagents}"
if ! command -v "$CA" > /dev/null 2>&1; then
  # Fail OPEN: this is a quality gate, not a safety gate (verify-gate is the
  # objective one). Say so rather than pretending the review passed.
  echo "[review-gate] SKIPPED: no chipagents binary ($CA). The turn was NOT reviewed."
  trace "skip: no binary"
  exit 0
fi

CTX=$(printf '%s' "$INPUT" | bash "$HERE/review-context.sh" 2> /dev/null)
case "$CTX" in
  NO_CHANGES* | NOT_A_GIT_REPOSITORY* | "")
    if [[ "$CTX" == *"no REVIEW_GATE_PATHS"* ]]; then
      echo "[review-gate] SKIPPED: REVIEW_GATE_PATHS is not set, so the turn was NOT reviewed."
      trace "skip: no scope"
    else
      trace "no changes"
    fi
    exit 0
    ;;
esac

REQ=$(extract_request)
[[ -n "$REQ" ]] || trace "request not recovered"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-gate.XXXXXX") || exit 0
PF="$WORK/prompt.md"
OF="$WORK/verdict.txt"

# REVIEW_GATE_KEEP preserves the prompt and the verdict. Without it there is no
# way to check WHICH finding a block was for: the agent's own rebuttal names the
# files too, so counting filenames in the transcript proves nothing.
keep() {
  [[ -n "${REVIEW_GATE_KEEP:-}" ]] || return 0
  mkdir -p "$REVIEW_GATE_KEEP" 2> /dev/null || return 0
  cp -f "$PF" "$REVIEW_GATE_KEEP/prompt.$$.md" 2> /dev/null
  cp -f "$OF" "$REVIEW_GATE_KEEP/verdict.$$.txt" 2> /dev/null
}

finish() {
  rm -rf "$WORK"
  exit "$1"
}

{
  echo "You are a strict, fair peer reviewer for the turn another agent just"
  echo "finished. Read files and run read-only commands only. Change nothing."
  echo
  echo "Block ONLY for problems that are real and that matter:"
  echo "  1. Correctness bugs. RTL/SystemVerilog: wrong reset or clocking,"
  echo "     inferred latches, width mismatch or truncation, blocking vs"
  echo "     non-blocking misuse, missing default/else, CDC without a"
  echo "     synchronizer, off-by-one counters, FSM states with no exit."
  echo "     Scripts/software: wrong logic, unhandled or swallowed errors."
  echo "  2. Incomplete work presented as done: TODO/FIXME stubs, empty"
  echo "     modules, commented-out checks, tests weakened to pass."
  echo "  3. Claims without evidence: a checklist item ticked [x] whose"
  echo "     check was not run or does not pass. Re-run cheap read-only"
  echo "     checks yourself when that settles it."
  echo "  4. Changes that contradict the stated goal."
  echo
  echo "Do NOT block for style, naming, formatting, anything a linter would"
  echo "catch, pre-existing issues on untouched lines, or anything you could"
  echo "not confirm."
  echo
  echo "Do NOT block for content the request below asked for explicitly."
  echo "If the request names exact file contents, those contents are the"
  echo "requirement, not a defect, even if they look like a stub. Judge the"
  echo "turn against what was asked, not against what you would have asked"
  echo "for. If you believe the request itself is a bad idea, that is not a"
  echo "reason to block the turn."
  echo
  echo "Your reply MUST end with a line that is exactly one of:"
  echo "VERDICT: PASS"
  echo "VERDICT: BLOCK"
  echo "When blocking, put a numbered list ABOVE that line, each entry giving"
  echo "file:line, the problem, and the concrete fix."
  echo
  echo "===== THE REQUEST THIS TURN WAS ANSWERING"
  if [[ -n "$REQ" ]]; then
    printf '%s\n' "$REQ"
  else
    echo "(could not be recovered from the hook payload; judge the changes on"
    echo " their own merits, and do not assume intent)"
  fi
  echo
  echo "===== CONTEXT COLLECTED AFTER THE TURN"
  printf '%s\n' "$CTX"
} > "$PF"

# Read-only by construction: no --allow-edits and no --skip-permissions, so
# batch mode cannot modify a file (measured: with --skip-permissions the agent
# CAN create files). The inner flags stop this child's own hooks.
REVIEW_GATE_INNER=1 CHIPAGENTS_HOOKS_INNER=1 timeout "${REVIEW_GATE_TIMEOUT:-300}" \
  "$CA" batch --name review-gate --prompt-file "$PF" --output "$OF" \
  --thinking "${REVIEW_GATE_THINKING:-low}" < /dev/null > /dev/null 2>&1
RC=$?

if [[ ! -s "$OF" ]]; then
  echo "[review-gate] SKIPPED: reviewer produced no output (rc=$RC). The turn was NOT reviewed."
  trace "skip: empty output rc=$RC"
  finish 0
fi

# Anchor on the LAST verdict line: earlier text may quote the words.
VERDICT=$(grep -E '^[[:space:]]*VERDICT:[[:space:]]*(PASS|BLOCK)' "$OF" | tail -n 1 | grep -oE '(PASS|BLOCK)')

case "$VERDICT" in
  PASS)
    trace "pass"
    keep
    finish 0
    ;;
  BLOCK)
    echo "[review-gate] The peer reviewer BLOCKED this turn. Fix these, then finish again."
    echo
    sed '/^[[:space:]]*VERDICT:[[:space:]]*BLOCK/d' "$OF"
    echo
    echo "If a finding is wrong, say why instead of silently ignoring it."
    trace "block"
    keep
    # NON-ZERO: the only form measured to make ChipAgents rerun the agent.
    finish 1
    ;;
  *)
    echo "[review-gate] SKIPPED: reviewer gave no VERDICT line. The turn was NOT reviewed."
    trace "skip: no verdict"
    keep
    finish 0
    ;;
esac
