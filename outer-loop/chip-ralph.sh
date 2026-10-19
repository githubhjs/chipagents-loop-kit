#!/bin/bash

# chip-ralph.sh: outer "Ralph" loop for ChipAgents (or any agent CLI).
# Runs the agent headless again and again, each run with a fresh context,
# until the project's goal is met:
#   - the plan is finished: every item in the goal checklist
#     (.chipagents/goal.md or .claude/goal.md) is [x] or [!]; without a
#     checklist, the agent printed LOOP_COMPLETE as its last line
#   - and the verify script passes (.chipagents/verify.sh or
#     .claude/verify.sh), when there is one
#
# Circuit breakers (ideas from frankbria/ralph-claude-code):
#   - no change in the working tree for NO_PROGRESS_LIMIT runs
#   - the same verify failure for SAME_ERROR_LIMIT runs
#   - the agent exits non-zero FAILURE_LIMIT runs in a row
#   - MAX_LOOPS runs, MAX_CALLS_PER_HOUR, LOOP_TIMEOUT seconds per run
#   - TOKEN_BUDGET total tokens, read from ChipAgents' --stats-file
#   - touch .chip-ralph/stop to stop before the next run
#
# The agent command is AGENT_ARGV (a bash array, best set in
# .chip-ralph.conf) or AGENT_CMD (a string split on spaces). These
# placeholders are replaced in every argument for each run:
#   {prompt_file}  file holding this run's prompt (then it is not passed
#                  as an argument or on stdin)
#   {output_file}  where the agent should write its final response
#   {stats_file}   where the agent should write token statistics (JSON)
#   {run}          the run number
# ChipAgents example (see .chip-ralph.conf.example):
#   AGENT_ARGV=(chipagents batch --name "chip-ralph-{run}"
#     --prompt-file "{prompt_file}" --output "{output_file}"
#     --stats-file "{stats_file}" --allow-edits "rtl/**" ".chipagents/goal.md")
#
#   ./chip-ralph.sh [prompt-file]
#
# Settings come from the environment or ./.chip-ralph.conf (bash syntax).
# Exit status: 0 goal met, 1 max loops, 2 no progress, 3 same error,
# 4 agent failures, 5 stopped, 6 token budget, 64 usage or configuration
# error. Needs bash, git, coreutils (timeout, md5sum). No jq.

set -uo pipefail

if [[ -f .chip-ralph.conf ]]; then
  # shellcheck disable=SC1091
  source ./.chip-ralph.conf
fi

AGENT_CMD="${AGENT_CMD:-}"
PROMPT_FILE="${1:-${PROMPT_FILE:-PROMPT.md}}"
PROMPT_MODE="${PROMPT_MODE:-arg}"
MAX_LOOPS="${MAX_LOOPS:-30}"
LOOP_TIMEOUT="${LOOP_TIMEOUT:-3600}"
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-30}"
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"
SAME_ERROR_LIMIT="${SAME_ERROR_LIMIT:-3}"
FAILURE_LIMIT="${FAILURE_LIMIT:-3}"
TOKEN_BUDGET="${TOKEN_BUDGET:-0}"
STATE_DIR=".chip-ralph"

# Hook bookkeeping files change without the agent doing any work.
EXCLUDES=(
  ":(exclude)$STATE_DIR"
  ':(exclude).chipagents/goal-gate.state' ':(exclude).claude/goal-gate.state'
  ':(exclude).chipagents/verify-gate.count' ':(exclude).claude/verify-gate.count'
  ':(exclude).chipagents/nonstop.*'
)

die() {
  echo "chip-ralph: $*" >&2
  exit 64
}

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$STATE_DIR/chip-ralph.log"
}

first_existing() {
  local file
  for file in "$@"; do
    if [[ -f "$file" ]]; then
      echo "$file"
      return
    fi
  done
}

open_items() {
  grep -E '^[[:space:]]*[-*] \[ \]' "$1"
}

fingerprint() {
  {
    git rev-parse -q --verify HEAD
    git status --porcelain -uall -- . "${EXCLUDES[@]}"
    git diff HEAD -- . "${EXCLUDES[@]}" 2> /dev/null
    git ls-files -o --exclude-standard -z -- . "${EXCLUDES[@]}" | xargs -0 -r cat 2> /dev/null
  } | md5sum | cut -d' ' -f1
}

build_prompt() {
  local loop="$1" goal
  echo "[chip-ralph run $loop of $MAX_LOOPS] You are one run in a loop; every run starts with a fresh context, so read the files below for state."
  goal=$(first_existing .chipagents/goal.md .claude/goal.md)
  if [[ -n "$goal" ]]; then
    echo
    echo "Open items in $goal:"
    open_items "$goal" || echo "(none)"
  fi
  if [[ -s "$STATE_DIR/last-verify.log" ]]; then
    echo
    echo "The verify script failed after the previous run (last 30 lines):"
    tail -n 30 "$STATE_DIR/last-verify.log"
  fi
  echo
  echo "----"
  cat "$PROMPT_FILE"
}

agent_argv=()
if declare -p AGENT_ARGV 2> /dev/null | grep -q '^declare -a'; then
  agent_argv=("${AGENT_ARGV[@]}")
elif [[ -n "$AGENT_CMD" ]]; then
  read -ra agent_argv <<< "$AGENT_CMD"
fi
[[ ${#agent_argv[@]} -gt 0 ]] || die 'set AGENT_ARGV in .chip-ralph.conf (see .chip-ralph.conf.example) or AGENT_CMD'
[[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
[[ "$PROMPT_MODE" == arg || "$PROMPT_MODE" == stdin ]] || die "PROMPT_MODE must be arg or stdin"
[[ "$TOKEN_BUDGET" =~ ^[0-9]+$ ]] || die "TOKEN_BUDGET must be a number of tokens (0 = no limit)"
git rev-parse --is-inside-work-tree > /dev/null 2>&1 || die "run inside a git repository; progress is measured with git"
command -v "${agent_argv[0]}" > /dev/null || die "agent command not found: ${agent_argv[0]}"

prompt_via_file=no
for arg in "${agent_argv[@]}"; do
  [[ "$arg" == *"{prompt_file}"* ]] && prompt_via_file=yes
done

# If our own output is redirected to a file inside the repository
# (./chip-ralph.sh > loop.log), that file changes every run; it is not
# progress.
toplevel=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
for fd in 1 2; do
  target=$(readlink -f "/proc/$$/fd/$fd" 2> /dev/null) || continue
  if [[ -f "$target" && "$target" == "$toplevel"/* ]]; then
    EXCLUDES+=(":(top,exclude)${target#"$toplevel"/}")
  fi
done

mkdir -p "$STATE_DIR/logs"
rm -f "$STATE_DIR/stop" "$STATE_DIR/last-verify.log"
exclude_file="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude_file")"
grep -qxF "/$STATE_DIR/" "$exclude_file" 2> /dev/null || echo "/$STATE_DIR/" >> "$exclude_file"

calls_hour=
calls=0
no_progress=0
same_error=0
failures=0
last_error=
total_tokens=0
previous_fingerprint=$(fingerprint)

for ((loop = 1; loop <= MAX_LOOPS; loop++)); do
  if [[ -f "$STATE_DIR/stop" ]]; then
    log "stop requested; exiting before run $loop"
    exit 5
  fi

  hour=$(date +%Y%m%d%H)
  if [[ "$hour" != "$calls_hour" ]]; then
    calls_hour="$hour"
    calls=0
  fi
  if [[ $calls -ge $MAX_CALLS_PER_HOUR ]]; then
    wait_seconds=$((3600 - $(date +%s) % 3600 + 5))
    log "rate limit of $MAX_CALLS_PER_HOUR runs/hour reached; sleeping ${wait_seconds}s"
    sleep "$wait_seconds"
    calls_hour=$(date +%Y%m%d%H)
    calls=0
  fi
  calls=$((calls + 1))

  run_log="$STATE_DIR/logs/run-$loop.log"
  prompt_path="$PWD/$STATE_DIR/logs/run-$loop.prompt.md"
  output_path="$PWD/$STATE_DIR/logs/run-$loop.response.txt"
  stats_path="$PWD/$STATE_DIR/logs/run-$loop.stats.json"
  run_argv=()
  for arg in "${agent_argv[@]}"; do
    arg="${arg//"{run}"/$loop}"
    arg="${arg//"{prompt_file}"/$prompt_path}"
    arg="${arg//"{output_file}"/$output_path}"
    arg="${arg//"{stats_file}"/$stats_path}"
    run_argv+=("$arg")
  done

  log "run $loop/$MAX_LOOPS started (log: $run_log)"
  build_prompt "$loop" > "$prompt_path"
  if [[ "$prompt_via_file" == yes ]]; then
    timeout "$LOOP_TIMEOUT" "${run_argv[@]}" < /dev/null > "$run_log" 2>&1
  elif [[ "$PROMPT_MODE" == arg ]]; then
    timeout "$LOOP_TIMEOUT" "${run_argv[@]}" "$(cat "$prompt_path")" < /dev/null > "$run_log" 2>&1
  else
    timeout "$LOOP_TIMEOUT" "${run_argv[@]}" < "$prompt_path" > "$run_log" 2>&1
  fi
  status=$?

  # ChipAgents --stats-file: {"status": "completed"|"failed", "tokenUsage": {"totalTokens": N, ...}}
  if [[ -s "$stats_path" ]]; then
    run_status=$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[A-Za-z]+"' "$stats_path" | head -n 1 | sed -E 's/.*"([A-Za-z]+)"$/\1/')
    run_tokens=$(grep -oE '"totalTokens"[[:space:]]*:[[:space:]]*[0-9]+' "$stats_path" | head -n 1 | grep -oE '[0-9]+$')
    total_tokens=$((total_tokens + ${run_tokens:-0}))
    log "run $loop: stats status ${run_status:-?}, ${run_tokens:-?} tokens (total $total_tokens)"
    if [[ $status -eq 0 && "$run_status" == failed ]]; then
      status=1
    fi
  fi

  if [[ $status -eq 124 ]]; then
    log "run $loop hit the ${LOOP_TIMEOUT}s timeout"
  elif [[ $status -ne 0 ]]; then
    failures=$((failures + 1))
    log "run $loop: agent exited $status ($failures in a row)"
    if [[ $failures -ge $FAILURE_LIMIT ]]; then
      log "circuit breaker: agent failed $FAILURE_LIMIT runs in a row; see $run_log"
      exit 4
    fi
  else
    failures=0
  fi

  current_fingerprint=$(fingerprint)
  if [[ "$current_fingerprint" == "$previous_fingerprint" ]]; then
    no_progress=$((no_progress + 1))
  else
    no_progress=0
  fi
  previous_fingerprint="$current_fingerprint"

  goal=$(first_existing .chipagents/goal.md .claude/goal.md)
  verify=$(first_existing .chipagents/verify.sh .claude/verify.sh)

  if [[ -n "$goal" ]]; then
    open_count=$(open_items "$goal" | grep -c .)
    plan_done=$([[ $open_count -eq 0 ]] && echo yes || echo no)
  else
    open_count=-
    # The final response (--output) is cleaner than the console log.
    response="$run_log"
    [[ -s "$output_path" ]] && response="$output_path"
    last_line=$(grep -v '^[[:space:]]*$' "$response" | tail -n 1 | tr -d '[:space:]')
    plan_done=$([[ "$last_line" == LOOP_COMPLETE ]] && echo yes || echo no)
  fi

  verify_ok=yes
  if [[ -n "$verify" ]]; then
    if timeout "$LOOP_TIMEOUT" bash "$verify" > "$STATE_DIR/verify.log" 2>&1; then
      rm -f "$STATE_DIR/last-verify.log"
      same_error=0
      last_error=
    else
      verify_ok=no
      cp "$STATE_DIR/verify.log" "$STATE_DIR/last-verify.log"
      error_signature=$(tail -n 30 "$STATE_DIR/verify.log" | md5sum | cut -d' ' -f1)
      if [[ "$error_signature" == "$last_error" ]]; then
        same_error=$((same_error + 1))
      else
        same_error=1
        last_error="$error_signature"
      fi
    fi
  fi

  log "run $loop done: open items $open_count, plan done $plan_done, verify ok $verify_ok, no-progress $no_progress/$NO_PROGRESS_LIMIT, same error $same_error/$SAME_ERROR_LIMIT, tokens $total_tokens"
  printf 'run=%s\nopen_items=%s\nplan_done=%s\nverify_ok=%s\nno_progress=%s\nsame_error=%s\nfailures=%s\ntotal_tokens=%s\n' \
    "$loop" "$open_count" "$plan_done" "$verify_ok" "$no_progress" "$same_error" "$failures" "$total_tokens" > "$STATE_DIR/status"

  if [[ "$plan_done" == yes && "$verify_ok" == yes ]]; then
    log "goal met after $loop run(s)"
    exit 0
  fi
  if [[ $no_progress -ge $NO_PROGRESS_LIMIT ]]; then
    log "circuit breaker: no change in the working tree for $NO_PROGRESS_LIMIT runs"
    exit 2
  fi
  if [[ $same_error -ge $SAME_ERROR_LIMIT ]]; then
    log "circuit breaker: the same verify failure $SAME_ERROR_LIMIT runs in a row; see $STATE_DIR/last-verify.log"
    exit 3
  fi
  if [[ $TOKEN_BUDGET -gt 0 && $total_tokens -ge $TOKEN_BUDGET ]]; then
    log "token budget reached: $total_tokens of $TOKEN_BUDGET tokens used"
    exit 6
  fi
done

log "stopped after $MAX_LOOPS runs without meeting the goal"
exit 1
