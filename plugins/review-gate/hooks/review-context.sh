#!/bin/bash

# review-context.sh: print what the review-gate reviewer needs to judge the
# last agent turn: the goal checklist (if any) and the uncommitted changes.
# Prints NO_CHANGES when there is nothing to review.
#
# When the hook input (JSON on stdin) lists the files this agent edited,
# only those are shown, so other agents' work in a shared repository is not
# reviewed as if it were this agent's.

set -uo pipefail

MAX_DIFF_LINES="${REVIEW_GATE_MAX_DIFF_LINES:-1500}"

input=
if [[ ! -t 0 ]]; then
  input=$(cat)
fi

files=()
if [[ -n "$input" ]] && command -v jq > /dev/null 2>&1; then
  while IFS= read -r file; do
    file="${file%$'\r'}"
    [[ -n "$file" ]] && files+=("$file")
  done < <(printf '%s' "$input" | jq -r '.files[]? // empty' 2> /dev/null)
fi

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "NOT_A_GIT_REPOSITORY: review the files named in the conversation instead."
  exit 0
fi

for goal in .claude/goal.md .chipagents/goal.md; do
  if [[ -f "$goal" ]]; then
    echo "===== GOAL ($goal)"
    cat "$goal"
    echo
    break
  fi
done

if [[ ${#files[@]} -gt 0 ]]; then
  status=$(git status --short -- "${files[@]}")
else
  status=$(git status --short)
fi

if [[ -z "$status" ]]; then
  echo "NO_CHANGES"
  exit 0
fi

echo "===== CHANGED FILES (git status --short)"
echo "$status"
echo
echo "===== DIFF AGAINST HEAD (first $MAX_DIFF_LINES lines; read files directly for more)"
if git rev-parse --verify -q HEAD > /dev/null; then
  if [[ ${#files[@]} -gt 0 ]]; then
    git diff HEAD -- "${files[@]}" | head -n "$MAX_DIFF_LINES"
  else
    git diff HEAD | head -n "$MAX_DIFF_LINES"
  fi
else
  echo "(no commits yet: every file above is new; read them directly)"
fi
