# ChipAgents Tool Notes

The skills speak Claude Code's vocabulary. In ChipAgents use these
equivalents. Trust your actual tool list over this table when they disagree.

| Skills say | In ChipAgents |
|---|---|
| `Skill` tool / "invoke the X skill" | ChipAgents loads skills when they are relevant. To invoke one explicitly, read that skill's `SKILL.md` and follow it. |
| Todos / "create a todo per item" | Keep the checklist in `.chipagents/goal.md` as `- [ ]` items. The goal-gate plugin keeps you working until every item is `- [x]` (or `- [!] … - BLOCKED: <reason>`). ChipAgents Plan Mode also works for planning. |
| `Agent` / `Task` tool, "dispatch a subagent" | Use a ChipAgents subagent. Agent profiles live in `.chipagents/agents/`. |
| Plan mode | ChipAgents Plan Mode. |
| `using-git-worktrees` | Same git commands. When several agents share one working tree, commit with `git flock-commit` from git-flock-kit instead of plain `git add`/`git commit`. |
| Running tests / verification | Hardware projects: the project's lint, simulation or regression commands (for example slang, verilator, the simulator's make targets). The verify-gate plugin runs `.chipagents/verify.sh` after every turn. |
