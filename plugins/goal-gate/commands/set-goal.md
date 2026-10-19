---
description: Write the goal checklist that goal-gate enforces, so the agent keeps working until every item is done
argument-hint: "<what done looks like>"
---

Turn this goal into a checklist file that the goal-gate hook will enforce:

$ARGUMENTS

Rules:

1. Write the file to `.chipagents/goal.md` when you are ChipAgents, or to
   `.claude/goal.md` when you are Claude Code; create the directory if needed.
   If a goal file already exists, show it and ask before replacing it.
2. Start with a short `# Goal` section (one paragraph), then
   `## Acceptance criteria` with one `- [ ]` line per item.
3. Every item must be objectively checkable. Name the command, file, test or
   signal that proves it, for example:
   `- [ ] make sim TEST=uart_basic passes with 0 errors and 0 UVM_ERROR`
   `- [ ] slang --lint-only rtl/uart.sv reports no warnings`
   Never write vague items such as "code is clean" or "works well".
4. Order the items so earlier ones unblock later ones. Aim for 3 to 12 items.
5. Show the checklist and wait for the user to confirm it before starting.
   After confirmation, start on the first item.

While working:

- Tick an item (`- [x]`) only after verifying it with fresh evidence: run the
  check in this turn and read its output.
- If an item truly cannot be done without the user, mark it
  `- [!] <item> - BLOCKED: <reason and what the user must do>` and move on.
- Never tick, delete or reword an item just to end the loop.
