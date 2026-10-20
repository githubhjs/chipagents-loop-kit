# ChipAgents hook mechanics: what was measured

For anyone porting a Claude Code hook to ChipAgents. Everything below was
measured by Josh_HUANG on **ChipAgents 0.42.3**, mostly in **batch mode**, on
2026-10-16 and 2026-10-19, with real command output behind every number.
Each scenario was run once; see [Not verified](#not-verified) for the gaps.

## 1. How a hook reports a block depends on the event

The documentation's general rule ("return `{"block": true}` to block") holds
for one case and misleads for another:

| Event | Hook reports | Blocks | Reruns the agent |
|---|---|---|---|
| `post_turn` | `{"block": true}` and exit 0 | yes | **no** |
| `post_turn` | message on stdout and **exit 1** | yes | **yes** |
| `pre_tool_use` | `{"block": true}` and exit 0 | yes | n/a |
| `pre_tool_use` | message on stdout and exit 1 | yes | n/a |
| `post_turn` | `type = "agent"` hook returning JSON | **no** | **no** |

Evidence: the same hook, changing only how it reports, gave 1 call, 1 turn and
no rerun with JSON + exit 0, versus 3 calls, 3 turns with message + exit 1 (the
agent acted on the message). Token use was 137k versus 411k, consistent with
three real turns.

**Rule: to make the agent run again, exit non-zero and put the message on
stdout.** All gates in this kit (goal-gate, verify-gate, nonstop, ralph-loop,
review-gate) do that.

## 2. `type = "agent"` post_turn hooks do not run at all

| Observation | Result |
|---|---|
| `chipagents validate` | parses the hook fully |
| the hook's `command` (writes a file at an absolute path) | the file is never created |
| a bash hook in the same file (positive control) | runs, with the right cwd |
| turns | 1, no rerun |
| token use versus the same run without the hook | identical in every field |

The decisive row is the second: a shell command writing to an absolute path
has no other explanation. This is why review-gate is a **bash** hook that
starts the reviewer itself (`chipagents batch`). Whether agent-type hooks run
on other events (`pre_turn`, `pre_tool_use`) was not tested.

## 3. `post_turn_restarts` is a budget of attempts, and plugins rarely set it

| `post_turn_restarts` | Turns | Reruns |
|---|---|---|
| 1 | 1 | 0 |
| 4 | 4 | 3 |
| not set in the workspace | 2 | 1 |

- **Reruns = `post_turn_restarts` − 1.**
- **The first value found while loading wins**, and a value in the user's
  `~/.chipagents` beats the one in a plugin's hooks.toml. On the test machine a
  user-level plugin set 2, so a plugin asking for 20 got 2: one extra turn.
- To get N reruns, put `post_turn_restarts = N + 1` in the **workspace**
  `.chipagents/hooks.toml`.

## 4. What hooks receive

- The payload arrives on **stdin**, not as arguments. The working directory of a
  bash hook is the **workspace root**.
- `post_turn` payload has **one field**:
  `{"user_message": "Last turn transcript:\nUser:\n...\n---\n\nAssistant:\n..."}`.
  There is no `.files`, no `transcript_path` and no session id.
- `pre_tool_use`: `tool_name` is exactly `"Bash"` (capitalised; the `tools`
  filter is case-insensitive). `tool_input.command` is the **whole shell line
  the agent built**, for example `cd ip && git add a.sv; echo rc=$?`, not the
  user's words, so patterns must tolerate prefixes and suffixes.
- **A hook's stdout is fed back into the next transcript.** Anything a hook
  prints (a completion tag in a banner, for instance) shows up in the next
  `user_message`, so never look for a completion signal in the transcript that
  the hook itself may have printed. ralph-loop uses a promise **file** for this
  reason.

## 5. When hooks fire

- `pre_tool_use` fires in **normal mode**. The documentation files it under
  client-agent mode, which is historical: the switching environment variable
  was removed in v0.25.0.
- **Subagent turns trigger `post_turn` too**, but do not appear in the run log;
  they are only visible through side effects (an orchestrator that started two
  subagents left 3 hook records where a plain turn leaves 1). A gate such as
  goal-gate can therefore push a subagent as well. Whether subagents run
  concurrently was not measured.
- **Child batch runs load the same hooks.** A hook that starts
  `chipagents batch` (review-gate) must stop its own recursion; this kit uses
  `REVIEW_GATE_INNER=1` and the shared `CHIPAGENTS_HOOKS_INNER=1`, which every
  gate here honours. chip-swarm sets the latter for its read-only investigate
  and merge runs.
- `post_edit` is unreliable: the same hook fired when a turn edited one file
  and did not fire when it edited two (`{{FILES}}` ruled out; one sample per
  cell, cause unknown). Nothing in this kit depends on it.

## 6. JSON from a blocking hook must be fully escaped

A raw newline inside a JSON string makes the reply unparseable, and an
unparseable block is **ignored**: a guard ran, printed its refusal, and the
`git commit` it meant to stop went through. Escape backslash, quote, newline,
carriage return and tab (see `json_escape` in git-flock-kit's guard), and test
blocking hooks by feeding the whole output to a real JSON parser. Checking that
the output "starts with `{"block"`" lets invalid JSON pass.

## 7. Permissions in batch mode

- `--skip-permissions` lets the agent create files (measured). A reviewer
  started without `--allow-edits` and without `--skip-permissions` cannot
  modify anything, which is how review-gate keeps its reviewer read-only.

## 8. Installing plugins

- Use the **same ChipAgents version that runs your sessions**. On the test
  machine an older 0.20.2 came first on `PATH` while sessions ran 0.42.3; a
  plugin installed with 0.20.2 got an `installed.json` without a `hooks` field,
  so its hooks were never registered, silently.
- `chipagents plugin install` is a **no-op for an installed plugin**. After
  changing a plugin's files, run `chipagents plugin update <plugin>@<marketplace>`.

## Not verified

- Each scenario was run once; LLM decisions vary between runs.
- Interactive mode: almost everything above was measured in batch mode.
- Whether agent-type hooks run on `pre_turn` or `pre_tool_use`.
- Why `post_edit` fired for one edited file and not for two.
