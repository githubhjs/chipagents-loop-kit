#!/bin/bash

# review-context.sh: print what the review-gate reviewer needs to judge the
# last agent turn: the goal checklist (if any) and the uncommitted changes
# inside the review scope. Prints NO_CHANGES when there is nothing to review.
#
# The scope is DECLARED, not inferred:
#   REVIEW_GATE_PATHS="rtl tb docs"     space-separated paths
#
# Why not the hook payload: post_turn's bash payload was measured (2026-10-19,
# ChipAgents 0.42.3) to carry exactly one field,
#   {"user_message":"Last turn transcript:\nUser:\n...\nAssistant:\n..."}
# so there is no .files, and inferring would fall back to the whole working
# tree: slow in a large repository, and other sessions' changes would be
# judged as this turn's. Why not a list collected by a post_edit hook: the
# same day, a post_edit hook fired when a turn edited one file and did not fire
# when it edited two (cause unexplained), and a scope that silently empties
# itself is worse than none. The payload's .files is still used when present
# (file-oriented events).

set -uo pipefail

MAX_DIFF_LINES="${REVIEW_GATE_MAX_DIFF_LINES:-1500}"

input=
if [[ ! -t 0 ]]; then
  input=$(cat)
fi

files=()
for path in ${REVIEW_GATE_PATHS:-}; do
  files+=("$path")
done

if [[ ${#files[@]} -eq 0 && -n "$input" ]] && command -v jq > /dev/null 2>&1; then
  while IFS= read -r file; do
    file="${file%$'\r'}"
    [[ -n "$file" ]] && files+=("$file")
  done < <(printf '%s' "$input" | jq -r '.files[]? // empty' 2> /dev/null)
fi

# Neither source: refuse a whole-tree review on purpose.
if [[ ${#files[@]} -eq 0 ]]; then
  echo "NO_CHANGES"
  echo "(review-gate: no REVIEW_GATE_PATHS set and no .files in the payload, so this"
  echo " turn's changes could not be isolated. Set the scope, e.g."
  echo " REVIEW_GATE_PATHS=\"rtl tb\". A whole-tree review is refused on purpose.)"
  exit 0
fi

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "NOT_A_GIT_REPOSITORY: review the files named in the conversation instead."
  exit 0
fi

# Check for changes BEFORE printing anything else: the caller treats output
# that starts with NO_CHANGES as "nothing to review".
status=$(git status --short -- "${files[@]}")
if [[ -z "$status" ]]; then
  echo "NO_CHANGES"
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

echo "===== CHANGED FILES IN SCOPE (${files[*]}) (git status --short)"
echo "$status"
echo
echo "===== DIFF AGAINST HEAD (first $MAX_DIFF_LINES lines; read files directly for more)"
if git rev-parse --verify -q HEAD > /dev/null; then
  git diff HEAD -- "${files[@]}" | head -n "$MAX_DIFF_LINES"
else
  echo "(no commits yet: every file above is new; read them directly)"
fi
