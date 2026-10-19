# chipagents-loop-kit: finish the goal, don't stop early, review every turn

English | [繁體中文](README.zh-TW.md)

Loop-control kit for **ChipAgents** that also works in **Claude Code**.

It makes the agent **keep working until the goal is really done**, **get an
automatic peer review every turn**, and **stop on its own when it is stuck**
instead of spinning forever.

## Layers

| Layer | Tool | When it holds the agent back | Built-in brake |
|---|---|---|---|
| **Every turn** | `goal-gate` (new) | `goal.md` still has an unchecked `- [ ]` item | 3 turns in a row with no item resolved |
| | `review-gate` (new) | A reviewer subagent finds a real problem in the turn's changes | `post_turn_restarts` (default 5) |
| | `verify-gate` (in [claude-self-review-kit](https://github.com/githubhjs/claude-self-review-kit)) | `.chipagents/verify.sh` fails (lint, simulation, regression) | 10 blocks in a row |
| **Whole session** | `nonstop` (port) | Once nonstop mode is on, every attempt to stop is pushed back | `NONSTOP_MAX` (default 5) |
| **Across sessions (outer loop)** | `chip-ralph.sh` (new) | Starts a fresh-context ChipAgents run again and again until the checklist is done **and** verify passes | No progress, same error, agent failures, run limit, hourly limit, token budget |
| | `ralph-orchestrator` (downloaded binary) | Same idea with more features (hats, events) | Iterations, time, consecutive failures |
| **Working discipline** | `superpowers` (port) | Skills: no completion claim without fresh evidence, TDD, systematic debugging, code review | — |

The key ChipAgents mechanism is a **`post_turn` hook with `blocking = true`
and `enable_restarts = true`**: when the hook fails, ChipAgents reruns the
agent with the hook's output.

## Contents

```
chipagents-loop-kit/
├── .claude-plugin/marketplace.json     ← marketplace name: loop-kit
├── plugins/
│   ├── goal-gate/      goal checklist gate (new)
│   ├── review-gate/    automatic peer-review gate (new, ChipAgents only)
│   ├── nonstop/        nonstop mode (port of andylizf/nonstop)
│   └── superpowers/    discipline skills (port of obra/superpowers)
├── outer-loop/
│   ├── chip-ralph.sh   outer loop (new)
│   ├── PROMPT.md       prompt template for the outer loop
│   ├── chip-ralph.conf.example          chipagents batch settings template
│   ├── automatic-commands.toml.example  commands batch mode may run
│   └── ralph-orchestrator/  v2.10.1 static Linux binary + ralph.yml template
└── vendor/ralph-claude-code-4fd2fe9-src.tar.gz   reference source
```

Every plugin ships both:
- `.claude-plugin/plugin.json` and `hooks/hooks.json` for Claude Code
- `.chipagents-plugin/plugin.json` and `hooks/hooks.toml` for ChipAgents

## Sources, versions, licenses

| Item | Version | License | Changes |
|---|---|---|---|
| [obra/superpowers](https://github.com/obra/superpowers) | `bb92a77` (v7.0.0, ★301k) | MIT | Added `rules/using-superpowers.md` and `references/chipagents-tools.md`; one line added to using-superpowers' platform list |
| [andylizf/nonstop](https://github.com/andylizf/nonstop) | `9511b6f` (★263) | MIT | Packaged as a plugin, ChipAgents hook added, ChipAgents paths added to SKILL.md |
| [mikeyobrien/ralph-orchestrator](https://github.com/mikeyobrien/ralph-orchestrator) | v2.10.1 musl binary (★3.2k) | MIT | Unchanged; SHA-256 verified |
| [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) | `4fd2fe9` (★9.7k) | MIT | Reference only; chip-ralph borrows its circuit-breaker design |
| goal-gate, review-gate, chip-ralph | this kit | MIT (`LICENSE`) | New |

---

## Install

### ChipAgents (e.g. CentOS)

```bash
chipagents plugin marketplace add githubhjs/chipagents-loop-kit --type claude
chipagents plugin install goal-gate@loop-kit --scope project     # project scope recommended
chipagents plugin install review-gate@loop-kit --scope project
chipagents plugin install nonstop@loop-kit
chipagents plugin install superpowers@loop-kit
```

From a local clone, use `chipagents plugin marketplace add /path/to/chipagents-loop-kit --type claude`.
Run `/reload` in a running session afterwards.

**Set the rerun limit explicitly in the project's `.chipagents/hooks.toml`.**
Each plugin declares its own `post_turn_restarts`, but ChipAgents uses only
the first value it finds, and the project directory is read before plugins:

```toml
post_turn_restarts = 20
```

### Claude Code

```bash
claude plugin marketplace add githubhjs/chipagents-loop-kit
claude plugin install goal-gate@loop-kit
```

nonstop and superpowers install the same way. In Claude Code, review-gate only
provides the `turn-reviewer` agent; there is no automatic hook.

---

## 1. goal-gate: no stopping until the checklist is done

1. Have the agent write the checklist:
   `/set-goal make the uart module pass lint and the uart_basic simulation`.
   - The agent writes `.chipagents/goal.md` (`.claude/goal.md` in Claude Code)
     and asks you to confirm it before starting.
2. Checklist format:

   ```markdown
   # Goal
   UART TX/RX implemented and verified.

   ## Acceptance criteria
   - [ ] slang --lint-only rtl/uart.sv reports no warnings
   - [ ] make sim TEST=uart_basic passes with 0 errors
   - [ ] make sim TEST=uart_parity passes with 0 errors
   ```

3. At the end of every turn, while any `- [ ]` is left, the hook hands the
   remaining items back to the agent.
4. Markers:
   - `- [x]`: done, backed by a check that was just run
   - `- [!] … - BLOCKED: reason`: needs a person; does not hold the agent back
5. **No spinning**: if 3 turns in a row resolve no item (`[x]` or `[!]`), the
   agent may stop. Change the limit with `GOAL_GATE_MAX_STALLS`.
6. Pause it by renaming or deleting `goal.md`.

## 2. review-gate: automatic peer review every turn

> ChipAgents only, and it **needs client-agent mode**, because `agent`-type
> hooks are a client-agent feature.

- After every turn, `review-context.sh` collects for the reviewer:
  - the goal checklist
  - `git status`
  - `git diff HEAD` (up to 1500 lines by default; set
    `REVIEW_GATE_MAX_DIFF_LINES`)
- When ChipAgents passes the list of files this agent edited, **only those
  files are reviewed**, so other agents' changes in a shared repository are
  not counted.
- A **read-only** reviewer subagent then checks for:
  - RTL bugs: reset/clocking, latches, width truncation, blocking vs
    non-blocking misuse, unsynchronised CDC, FSM states that cannot exit
  - shortcuts: TODOs, empty modules, weakened tests
  - **items ticked without evidence**
  - changes that contradict the goal
- On a real problem it returns `{"block": true, "message": "..."}` and the
  agent reworks with the list of issues. Style and naming nitpicks do not
  block.
- With no changes (`NO_CHANGES`) it passes at once without using any tools.
- **Cost**: one extra LLM review per turn. Install it with `--scope project`
  only where you need it.
- For a manual review with the same standard, use the `turn-reviewer` agent
  (`agents/turn-reviewer.md`).

## 3. nonstop: hands-off mode before you leave

1. Say "go nonstop" or "I'm leaving, keep working", and the skill starts the
   **pre-flight**:
   - it simulates the whole task and asks **now** every question that could
     make it stop later
   - it lists dangerous operations (deleting files, force-pushing, killing
     processes, posting externally, …) and gets your yes or no for each
   - it checks that ChipAgents' sandbox or approval settings will not stall it
     while you are away
2. After you confirm, the agent runs `touch .chipagents/nonstop.activate`.
3. From then on, every attempt to stop is pushed back with a **blocker
   decision framework**:
   - can solve it itself → solve it
   - can work around it with an equivalent result → do so and record what it
     did
   - high-risk and not pre-approved → mark the task blocked, move on
   - stuck on everything → turn nonstop mode off itself
4. At most `NONSTOP_MAX` nudges (default 5; 0 = unlimited, still capped by
   `post_turn_restarts`).
5. Turn it off with `touch .chipagents/nonstop.deactivate`; the agent then
   reports what was completed, what used workarounds and what is blocked.

ChipAgents hooks receive no session ID, so in ChipAgents the flags are
**project-scoped**. The Claude Code version keeps the original session scope
and needs python3.

## 4. superpowers: completion discipline

It has 15 skills; the ones that matter most for finishing work are:

| Skill | Purpose |
|---|---|
| `verification-before-completion` | **No "done" or "passing" without verification evidence from a check just run** |
| `writing-plans` / `executing-plans` | Write a plan first, then execute it item by item |
| `subagent-driven-development` | Hand each task to an implementer subagent, then a reviewer subagent |
| `requesting-code-review` / `receiving-code-review` | Ask for review and respond to it properly |
| `systematic-debugging` | Find the root cause instead of guessing |
| `test-driven-development` | Write a failing test first |

ChipAgents does not run SessionStart hooks of Claude-format plugins, so
`rules/using-superpowers.md` takes their place. Rules are always loaded, which
has the same effect as the original hook, and it includes a ChipAgents tool
mapping.

---

## 5. Outer loop: a fresh context every run

For long tasks that outgrow one context. Every run is a new ChipAgents
process; progress lives only in files: `goal.md`, `NOTES.md` and git.

### 5a. chip-ralph.sh (new; needs only bash, git and coreutils, no jq)

It drives ChipAgents' non-interactive **`chipagents batch`** mode. Setup:

```bash
K=/path/to/chipagents-loop-kit/outer-loop
cp $K/PROMPT.md .                                         # describe the task
cp $K/chip-ralph.conf.example .chip-ralph.conf            # adjust --allow-edits
mkdir -p .chipagents
cp $K/automatic-commands.toml.example .chipagents/automatic-commands.toml   # adjust allowed commands
bash $K/chip-ralph.sh
```

The command in `.chip-ralph.conf` (the `AGENT_ARGV` array) expands for each
run to:

```
chipagents batch --name chip-ralph-3 --prompt-file .chip-ralph/logs/run-3.prompt.md \
  --output .chip-ralph/logs/run-3.response.txt --stats-file .chip-ralph/logs/run-3.stats.json \
  --allow-edits .chipagents/goal.md NOTES.md "rtl/**" "tb/**" ...
```

**Batch-mode permissions (where unattended runs usually get stuck)**
- **Without `--allow-edits` the agent cannot change any file.** The template
  lists `goal.md`, `NOTES.md`, `rtl/**`, `tb/**` and more; adjust them for the
  project. The option takes every following word, so keep it **last**.
- **Shell commands are limited to `.chipagents/automatic-commands.toml`.** The
  template allows read-only commands, git queries, `git flock-commit`,
  `bash .chipagents/verify.sh`, `slang`, `verilator --lint-only`, `make lint`
  and `make sim`. Batch mode never asks: **anything not listed is refused**.
- `--skip-permissions` approves everything; the ChipAgents docs say to use it
  **only inside an isolated sandbox or container**.
- Log in once with the interactive CLI (`chipagents`, then `/login`); batch
  mode uses `~/.chipagents/credentials.json`. Use `--api-key` only in CI.
- Batch mode loads rules and skills from `.chipagents/`. **The docs do not say
  whether batch mode runs hooks**, so chip-ralph checks the checklist and
  verify itself after every run instead of relying on hooks.

**Done means both:**
1. The plan is finished: no `- [ ]` left in the checklist. Without a
   checklist, the last line of the agent's final response (the `--output` file)
   is `LOOP_COMPLETE`.
2. `.chipagents/verify.sh` passes (when it exists).

**Reading `--stats-file`**
- `"status": "failed"` counts as a failure even when the exit code is 0.
- Each run's `totalTokens` is added up. Set `TOKEN_BUDGET` to stop when the
  total reaches it (exit code 6). ralph-orchestrator's cost limit does not work
  with ChipAgents; this replaces it.

**Why not the Python SDK**: it needs Python 3.10 or later (CentOS 8 ships 3.6),
and its docs state that the SDK **does not load hooks at all**.

**Circuit breakers**

| Situation | Exit code | Setting |
|---|---|---|
| Goal met | 0 | — |
| Ran out of runs | 1 | `MAX_LOOPS=30` |
| Working tree unchanged for N runs | 2 | `NO_PROGRESS_LIMIT=3` |
| Identical verify failure for N runs | 3 | `SAME_ERROR_LIMIT=3` |
| Agent failed N runs in a row | 4 | `FAILURE_LIMIT=3` |
| Someone ran `touch .chip-ralph/stop` | 5 | — |
| Token budget reached | 6 | `TOKEN_BUDGET=0` (0 = no limit) |

Other settings:
- per-run timeout `LOOP_TIMEOUT=3600` seconds
- hourly limit `MAX_CALLS_PER_HOUR=30`
- settings can live in the project's `.chip-ralph.conf`

**Differences from ralph-claude-code**: progress also counts **new untracked
files** (the original does not), and ignores hook state files and chip-ralph's
own output when it is redirected into the repository. The next run's prompt
automatically includes the previous verify failure and the remaining
checklist. Logs go to `.chip-ralph/`, which is added to `.git/info/exclude`
automatically.

### 5b. ralph-orchestrator (full-featured)

```bash
tar xJf outer-loop/ralph-orchestrator/ralph-cli-x86_64-unknown-linux-musl.tar.xz
sudo install -m 0755 ralph-cli-x86_64-unknown-linux-musl/ralph /usr/local/bin/
cp outer-loop/ralph-orchestrator/ralph.yml .      # adjust the --allow-edits patterns
mkdir -p .ralph-tmp && export TMPDIR=$PWD/.ralph-tmp
ralph doctor -c ralph.yml
ralph run -a -c ralph.yml -P PROMPT.md
```

- The `custom` backend runs
  `chipagents batch --name ralph --allow-edits … --prompt "<prompt>"`. It is a
  static musl binary, so it runs on CentOS 8's glibc 2.28.
- **Always point `TMPDIR` inside the project**: for prompts over 7000
  characters Ralph passes "read and execute the task in `<tmpfile>`" instead,
  and the file goes to `$TMPDIR` (confirmed in the source). ChipAgents must be
  able to read it.
- The loop ends when the agent runs `ralph emit LOOP_COMPLETE` or the last line
  of output is exactly `LOOP_COMPLETE`.
- Its "backpressure" is self-reported by the agent; **it does not run tests**.
  For objective checks, combine it with verify-gate and goal-gate inside
  ChipAgents.
- Its docs' `custom_command:` key **is wrong**; the real key is `command:`.
- The cost limit does nothing for plain-text backends, which always report $0.

---

## Recommended setup (RTL projects)

1. `/set-goal …` to write `.chipagents/goal.md`, and a `.chipagents/verify.sh`
   that runs lint and simulation.
2. Install goal-gate, verify-gate, review-gate (project scope) and superpowers.
3. Short tasks: just give ChipAgents the task; the three gates make it finish,
   verify and pass review before it stops.
4. Leaving your desk: say "go nonstop" and finish the pre-flight before you go.
5. Very long tasks: run the outer loop with `chip-ralph.sh` or
   `ralph-orchestrator`; the gates above still apply inside each run.
6. Several agents in one repository: add `git flock-commit` from
   [git-flock-kit](https://github.com/githubhjs/git-flock-kit).

## Notes

- **Not yet run inside real ChipAgents.** Every hook has only been tested with
  simulated ChipAgents input. After deploying, run `chipagents validate` first
  and use the E2E test in claude-self-review-kit.
- To see what a hook actually receives, temporarily add a `post_turn` hook with
  `command = "cat > /tmp/post-turn.json"`.
- **All gates share the `post_turn_restarts` budget.** Too small and the
  budget runs out before the gates are satisfied; too large and costs grow.
- **Preserved-thinking models** (`thinkingRequiresIdenticalPrefix`): the
  ChipAgents docs warn that restarts can invalidate earlier thinking blocks.
  Try it on a small scale first.
- Hooks run with `$SHELL`. They work under tcsh too, because each command is
  just `bash "<path>"`.
- **ChipAgents' shell tool is named `Bash`**, confirmed from exported
  ChipAgents transcripts (commits run as `Bash(git commit …)`; the separate
  `Git` tool was only seen doing read-only status, log and diff).

## Projects not used

| Project | Reason |
|---|---|
| hamelsmu/claude-review-loop (★722) | **No license**, so it cannot be redistributed; also needs OpenAI Codex |
| Yeachan-Heo/oh-my-claudecode (★40k) | 101 MB of TypeScript, too tied to Claude Code to port |
| AnandChowdhary/continuous-claude (★1.4k) | Built around GitHub PRs (open PR, wait for CI); a poor fit for internal RTL flows |
| sour4bh/claude-loop, sdsrss/loop_eng | Experimental projects with 1–2 stars |
| Claude Code's built-in `/goal` and `/loop` | Built into Claude Code, not available in ChipAgents; goal-gate is the ChipAgents counterpart of `/goal` |

## Test status

All tested on Windows Git Bash with simulated input:

- **goal-gate**:
  - no goal file
  - open items
  - stall counter resets on progress and grows without it
  - lets the agent stop at the stall limit
  - `[x]`, `[X]` and `[!]` all count as resolved
  - Claude mode (output on stderr)
- **review-gate**:
  - not a git repository
  - empty repository
  - no changes
  - only the files listed on stdin
  - the whole repository
  - fixed a CRLF problem with jq output on Windows along the way
- **nonstop**:
  - ChipAgents version: activate, nudge, auto-deactivate, manual deactivate
  - original Claude version: session scope, `stop_hook_active`
- **chip-ralph**:
  - with a mock agent: every exit path (0, 2, 3, 4, 5, 6, 64), stdin mode,
    previous verify failure carried into the next prompt, and no false
    progress when its output is redirected into the repository
  - with a **mock `chipagents batch`** written from the Batch Mode docs:
    - `--prompt-file`, `--output`, `--stats-file` and multi-value
      `--allow-edits` (`rtl/**` passed through unexpanded)
    - token totals and `TOKEN_BUDGET`
    - stats status `failed` with exit code 0
    - `LOOP_COMPLETE` present only in the `--output` file
    - the legacy `AGENT_CMD` string
- **All plugins**: `claude plugin validate` passes, and every hooks.toml parses
  with Python's tomllib.

## Author

Chih-Hsueh "Josh" HUANG
