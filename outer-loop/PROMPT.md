# Task

<Describe the task here: what to build or fix, where, and any constraints.>

# How to work

Each run of this loop starts with a fresh context. Everything you need to
know about earlier runs is in the files, so:

1. Read `.chipagents/goal.md` (the checklist) and `NOTES.md` (what earlier
   runs did, learned and left for next time).
2. Take the FIRST open `- [ ]` item and do only that item, or a small group of
   items that belong together.
3. Verify it with fresh evidence: run its check and read the output. Tick it
   `- [x]` only if the check passes.
4. If an item truly cannot be done without a person, mark it
   `- [!] <item> - BLOCKED: <reason and what the person must do>` and move on.
5. Append to `NOTES.md`: what you did, what you learned, what the next run
   should do first.
6. Commit only your own files: `git flock-commit -m "<message>" -- <files>`
   (or `git add <files> && git commit` when git-flock-kit is not installed).
7. When every item is `[x]` or `[!]` and `.chipagents/verify.sh` passes,
   print `LOOP_COMPLETE` as the very last line of your output.

Never tick, delete or reword a checklist item, and never weaken a test or
the verify script, just to finish.
