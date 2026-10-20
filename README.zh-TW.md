# chipagents-loop-kit：自主完工、目標達成前不停、自動 peer review

[English](README.md) | 繁體中文

給 **ChipAgents** 用的 loop control 套件，也同時支援 **Claude Code**。

目標是讓 agent **在目標確實完成前不停下來**、**每一輪自動接受 peer review**，並且**卡住時會自動煞車**，不會無限空轉。

## 分層設計

| 層級 | 工具 | 什麼時候擋下 agent | 自動煞車條件 |
|---|---|---|---|
| **每一輪（turn 內）** | `goal-gate`（新寫） | 目標清單 `goal.md` 還有 `- [ ]` 沒打勾 | 連續 3 輪沒有任何項目完成 |
| | `review-gate`（新寫） | 唯讀 reviewer（`chipagents batch`）在這一輪的修改裡找到真正的問題 | `post_turn_restarts`；沒設 `REVIEW_GATE=1` 時不啟用 |
| | `verify-gate`（在 [claude-self-review-kit](https://github.com/githubhjs/claude-self-review-kit) 裡） | `.chipagents/verify.sh` 沒通過（lint／模擬／regression） | 連續 10 次 |
| **整個 session** | `nonstop`（移植） | 啟動 nonstop 模式後，每次想停就被推回去 | `NONSTOP_MAX`（預設 5 次） |
| **跨 session（外層迴圈）** | `chip-ralph.sh`（新寫） | 每次重新開一個全新 context 的 ChipAgents 跑，直到清單全勾**而且** verify 通過 | 沒進度、同樣的錯誤、agent 連續失敗、次數上限、每小時上限 |
| | `ralph-orchestrator`（下載的 binary） | 同上，功能更完整（hats、events） | 迭代次數、時間、連續失敗 |
| **工作紀律** | `superpowers`（移植） | 以 skill 規範：沒有新鮮證據就不能宣稱完成、TDD、系統化除錯、code review | — |

ChipAgents 的關鍵機制是 **`post_turn` bash hook 設定 `blocking = true` 加 `enable_restarts = true`，並且以非 0 結束**：ChipAgents 會帶著 hook 的 stdout 讓 agent 重跑。實測：回傳 `{"block": true}` 並以 0 結束只會擋住、不會重跑；agent 型別的 post_turn hook 則完全不會執行。這些實測結果整理在 [docs/chipagents-hook-mechanics.md](docs/chipagents-hook-mechanics.md)（英文）。

## 內容

```
chipagents-loop-kit/
├── .claude-plugin/marketplace.json     ← marketplace 名稱：loop-kit
├── plugins/
│   ├── goal-gate/      目標清單關卡（新寫）
│   ├── review-gate/    自動 peer review 關卡（新寫，ChipAgents 限定）
│   ├── nonstop/        nonstop 模式（移植自 andylizf/nonstop）
│   └── superpowers/    工作紀律 skills（移植自 obra/superpowers）
├── outer-loop/
│   ├── chip-ralph.sh   外層迴圈（新寫）
│   ├── PROMPT.md       外層迴圈用的 prompt 範本
│   ├── chip-ralph.conf.example          chipagents batch 設定範本
│   ├── automatic-commands.toml.example  batch mode 允許的指令範本
│   └── ralph-orchestrator/  v2.10.1 static Linux binary + ralph.yml 範本
├── docs/chipagents-hook-mechanics.md   ChipAgents hook 行為實測（英文）
└── vendor/ralph-claude-code-4fd2fe9-src.tar.gz   參考原始碼
```

每個 plugin 都同時有：
- `.claude-plugin/plugin.json` 和 `hooks/hooks.json`：給 Claude Code 用
- `.chipagents-plugin/plugin.json` 和 `hooks/hooks.toml`：給 ChipAgents 用

## 來源、版本、授權

| 項目 | 版本 | 授權 | 修改 |
|---|---|---|---|
| [obra/superpowers](https://github.com/obra/superpowers) | `bb92a77`（v7.0.0，★301k） | MIT | 新增 `rules/using-superpowers.md`、`references/chipagents-tools.md`，並在 using-superpowers 的平台清單加一行 |
| [andylizf/nonstop](https://github.com/andylizf/nonstop) | `9511b6f`（★263） | MIT | 包成 plugin，新增 ChipAgents hook，SKILL.md 補上 ChipAgents 路徑 |
| [mikeyobrien/ralph-orchestrator](https://github.com/mikeyobrien/ralph-orchestrator) | v2.10.1 musl binary（★3.2k） | MIT | 沒有修改，SHA-256 已驗證 |
| [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) | `4fd2fe9`（★9.7k） | MIT | 只當參考；chip-ralph 借用了它的斷路器設計 |
| goal-gate、review-gate、chip-ralph | 本套件 | MIT（`LICENSE`）| 新寫 |

---

## 安裝

### ChipAgents（CentOS）

```bash
chipagents plugin marketplace add githubhjs/chipagents-loop-kit --type claude
chipagents plugin install goal-gate@loop-kit --scope project     # 建議裝在專案層級
chipagents plugin install review-gate@loop-kit --scope project
chipagents plugin install nonstop@loop-kit
chipagents plugin install superpowers@loop-kit
```

從本機 clone 安裝時改用 `chipagents plugin marketplace add /path/to/chipagents-loop-kit --type claude`。
裝完在 session 裡執行 `/reload`。

**請在 workspace 的 `.chipagents/hooks.toml` 設定重跑額度。** 實測：
- 重跑次數 = `post_turn_restarts` − 1（這個值算的是嘗試次數）。
- ChipAgents 採用載入時最先找到的值，所以 `~/.chipagents` 或 workspace 裡的值會蓋掉所有 plugin 的值。

要最多重跑 20 次：

```toml
post_turn_restarts = 21
```

兩個安裝陷阱（實測）：
- **安裝時要用和跑 session 相同版本的 ChipAgents。** 如果 `PATH` 上排在前面的是較舊的 `chipagents`（例如 0.20.2，而 session 跑的是 0.42.3），裝出來的 `installed.json` 沒有 `hooks` 欄位，hook 會安靜地完全不執行。
- **`chipagents plugin install` 對已安裝的 plugin 不會有任何動作。** repo 更新後要執行 `chipagents plugin update <plugin>@loop-kit`。

### Claude Code

```bash
claude plugin marketplace add githubhjs/chipagents-loop-kit
claude plugin install goal-gate@loop-kit
```

nonstop 和 superpowers 也可以用同樣方式安裝。review-gate 在 Claude Code 只提供 `turn-reviewer` agent，沒有自動 hook。

---

## 1. goal-gate：清單沒打完不准停

1. 讓 agent 產生清單：`/set-goal 讓 uart 模組通過 lint 和 uart_basic 模擬`。
   - agent 會寫出 `.chipagents/goal.md`（Claude Code 是 `.claude/goal.md`），先給你確認，確認後才開始做。
2. 清單格式：

   ```markdown
   # Goal
   UART TX/RX 完成並驗證。

   ## Acceptance criteria
   - [ ] slang --lint-only rtl/uart.sv 沒有 warning
   - [ ] make sim TEST=uart_basic 0 error
   - [ ] make sim TEST=uart_parity 0 error
   ```

3. 每一輪結束時，只要還有 `- [ ]`，hook 就把剩下的項目交給 agent 繼續做。
4. 標記方式：
   - `- [x]`：完成，而且必須有剛跑過的檢查作為證據
   - `- [!] … - BLOCKED: 原因`：需要人處理，不會擋住 agent
5. **防空轉**：連續 3 輪都沒有新完成的項目（`[x]` 或 `[!]`）就放行。可用環境變數 `GOAL_GATE_MAX_STALLS` 調整。
6. 暫停：把 `goal.md` 改名或刪掉。

## 2. review-gate：每一輪自動 peer review

> 只能在 ChipAgents 用。它是一個 **bash** hook，由自己啟動 reviewer，因為實測 agent 型別的 post_turn hook 完全不會執行。

在 ChipAgents 執行的環境裡開啟：

```bash
export REVIEW_GATE=1
export REVIEW_GATE_PATHS="rtl tb"        # review 範圍：必填
```

| 變數 | 預設 | 用途 |
|---|---|---|
| `REVIEW_GATE` | 關閉 | 設 `1` 開啟（每一輪都會多一次 LLM 呼叫） |
| `REVIEW_GATE_PATHS` | 無 | 要 review 的路徑，以空白分隔。沒設就拒絕執行 |
| `REVIEW_GATE_CHIPAGENTS` | `PATH` 上的 `chipagents` | 執行 reviewer 的 binary；請用和 session 相同的版本 |
| `REVIEW_GATE_THINKING` | `low` | reviewer 的 thinking 等級 |
| `REVIEW_GATE_TIMEOUT` | `300` | reviewer 執行的秒數上限 |
| `REVIEW_GATE_MAX_DIFF_LINES` | `1500` | 交給 reviewer 的 diff 行數 |
| `REVIEW_GATE_KEEP` | 無 | 保存每次的 prompt 和 verdict 的目錄，用來確認某次 BLOCK 是為了什麼 |
| `REVIEW_GATE_TRACE` | 無 | 每個判斷寫一行紀錄的檔案 |

- **收集範圍**：每一輪結束後，`review-context.sh` 收集目標清單，以及 **`REVIEW_GATE_PATHS` 範圍內**尚未 commit 的修改。
  - 範圍必須明確宣告，不從 payload 推斷：`post_turn` 的 payload 只有 transcript 文字，沒有修改過的檔案清單。
  - 審整個工作樹太慢，還會把別的 session 的修改當成這一輪的來審。
- **唯讀 reviewer**：接著 `review-gate.sh` 用 `chipagents batch` 跑一個**唯讀**的 reviewer，不給 `--allow-edits`，也不給 `--skip-permissions`。
- **附上原始需求**：prompt 會附上從 transcript 還原的使用者需求，避免把使用者明確要求的內容誤判為 stub。
- **檢查項目**：
  - RTL bug：reset／clock、latch、位寬截斷、blocking 和 non-blocking 誤用、CDC 沒有同步、FSM 出不去
  - 偷懶：TODO、空模組、把測試改弱
  - **打了勾但沒有證據的項目**
  - 改動和目標矛盾
- **判定**：reviewer 必須以 `VERDICT: PASS` 或 `VERDICT: BLOCK` 結尾，以最後一行為準。**BLOCK** 會印出問題清單並以 1 結束，agent 就會重做。風格、命名這類小問題不會擋。
- **不擋的情況**：範圍內沒有修改時直接放行，不啟動 reviewer。如果 reviewer 不存在、執行失敗或沒有給出 verdict，會印出「The turn was NOT reviewed」並放行。這是品質關卡，不是安全關卡。
- **防止遞迴**：reviewer 自己的 batch run 也會載入同一組 hook，所以啟動時會帶 `REVIEW_GATE_INNER=1` 和 `CHIPAGENTS_HOOKS_INNER=1`，本套件所有關卡都會跳過這種內部 run。
- 想手動 review 時，可以直接使用同一套標準的 `turn-reviewer` agent（`agents/turn-reviewer.md`）。

## 3. nonstop：離開座位前的全自動模式

1. 說「go nonstop」或「我要離開，繼續做」，skill 就會啟動 **pre-flight**：
   - 先在腦中模擬整個任務，**現在**就問清楚所有可能讓它停下來的問題
   - 列出危險操作清單（刪檔、force push、殺 process、對外發訊息……），逐項取得你的同意
   - 確認 ChipAgents 的 sandbox 或核准機制不會在你離開時卡住它
2. 你確認後，agent 會執行 `touch .chipagents/nonstop.activate`。
3. 之後 agent 每次想停，hook 就推回去，並附上**卡關決策框架**：
   - 自己能解決 → 自己解決
   - 能繞過而且結果等價 → 繞過，並記錄做了什麼
   - 高風險而且沒被允許 → 標記為 blocked，換下一個任務
   - 全部都卡住 → 自行關閉 nonstop 模式
4. 最多推 `NONSTOP_MAX` 次（預設 5，設 0 表示不限，但仍受 `post_turn_restarts` 限制）。
5. 關閉：`touch .chipagents/nonstop.deactivate`，agent 會回報完成、繞過和 blocked 的項目。

ChipAgents 的 hook 拿不到 session ID，所以 ChipAgents 版的旗標是**專案層級**的。Claude Code 版維持原本的 session 層級，而且需要 python3。

## 4. superpowers：完工紀律

裡面有 15 個 skill，和「自主完工」最相關的是：

| Skill | 作用 |
|---|---|
| `verification-before-completion` | **沒有剛跑過的驗證證據，就不能說「完成」或「通過」** |
| `writing-plans` / `executing-plans` | 先寫計畫，再照計畫逐項執行 |
| `subagent-driven-development` | 每個任務分派給實作 subagent，再交給 reviewer subagent 審 |
| `requesting-code-review` / `receiving-code-review` | 請求 review、正確回應 review |
| `systematic-debugging` | 先找根因，不亂猜 |
| `test-driven-development` | 先寫會失敗的測試 |

ChipAgents 不執行 Claude 格式 plugin 的 SessionStart hook，所以改用 `rules/using-superpowers.md`。rules 會一直載入，效果和原本的 hook 一樣，內容附上 ChipAgents 的工具對照表。

---

## 5. 外層迴圈：每一輪都是全新的 context

適合很長、會超過一個 context 的任務。每一輪都是新的 ChipAgents 執行，進度只靠檔案傳遞：`goal.md`、`NOTES.md`、git。

### 5a. chip-ralph.sh（新寫，只需要 bash、git、coreutils，不需要 jq）

使用 ChipAgents 的 **`chipagents batch`**（非互動模式）。設定步驟：

```bash
K=/path/to/chipagents-loop-kit/outer-loop
cp $K/PROMPT.md .                                         # 填入任務
cp $K/chip-ralph.conf.example .chip-ralph.conf            # 調整 --allow-edits
mkdir -p .chipagents
cp $K/automatic-commands.toml.example .chipagents/automatic-commands.toml   # 調整允許的指令
bash $K/chip-ralph.sh
```

`.chip-ralph.conf` 裡設定的指令（`AGENT_ARGV` 陣列），每一輪會展開成：

```
chipagents batch --name chip-ralph-3 --prompt-file .chip-ralph/logs/run-3.prompt.md \
  --output .chip-ralph/logs/run-3.response.txt --stats-file .chip-ralph/logs/run-3.stats.json \
  --allow-edits .chipagents/goal.md NOTES.md "rtl/**" "tb/**" ...
```

**batch mode 的權限（無人看管時最容易卡住的地方）**
- **沒有 `--allow-edits` 的話，agent 一個檔案都不能改。** 範本已列出 `goal.md`、`NOTES.md`、`rtl/**`、`tb/**` 等，請依專案調整。這個參數會吃掉後面所有字，所以要放在**最後**。
- **shell 指令只能跑 `.chipagents/automatic-commands.toml` 允許的。** 範本允許了唯讀指令、git 查詢、`git flock-commit`、`bash .chipagents/verify.sh`、`slang`、`verilator --lint-only`、`make lint`、`make sim`。batch mode 不會跳出來問你，**不在清單裡的指令會直接被拒絕**。
- `--skip-permissions` 會全部放行，ChipAgents 文件說**只能在隔離的 sandbox 或 container 裡用**。
- 登入：先用互動模式 `chipagents` 執行 `/login`（batch 會用 `~/.chipagents/credentials.json`）。CI 才用 `--api-key`。
- batch mode 會自動載入 `.chipagents/` 的 rules 和 skills。**文件沒有說 batch mode 會不會跑 hooks。** 所以 chip-ralph 自己在每一輪之後檢查清單和 verify，不依賴 hook。

**完成條件（兩個都要成立）**
1. 計畫做完：清單沒有 `- [ ]`。沒有清單時，看 agent 的最終回覆（`--output` 檔）最後一行是否為 `LOOP_COMPLETE`。
2. `.chipagents/verify.sh` 通過（有這個檔案時）。

**讀取 `--stats-file`**
- `"status": "failed"` 視為失敗，即使結束碼是 0。
- 每一輪的 `totalTokens` 會累加。設 `TOKEN_BUDGET` 就能在用量到達上限時停止（結束碼 6）。ralph-orchestrator 的費用上限對 ChipAgents 無效，這個可以取代它。

**為什麼不用 Python SDK**：SDK 需要 Python 3.10 以上（CentOS 8 內建的是 3.6），而且文件寫明 SDK **完全不載入 hooks**。

**斷路器**

| 狀況 | 結束碼 | 設定 |
|---|---|---|
| 目標達成 | 0 | — |
| 跑滿次數 | 1 | `MAX_LOOPS=30` |
| 連續 N 輪 working tree 完全沒變 | 2 | `NO_PROGRESS_LIMIT=3` |
| 連續 N 輪 verify 失敗訊息完全相同 | 3 | `SAME_ERROR_LIMIT=3` |
| agent 連續 N 次非 0 結束 | 4 | `FAILURE_LIMIT=3` |
| 有人執行 `touch .chip-ralph/stop` | 5 | — |
| token 用量到達上限 | 6 | `TOKEN_BUDGET=0`（0 = 不限） |

其他設定：
- 每輪逾時 `LOOP_TIMEOUT=3600` 秒
- 每小時上限 `MAX_CALLS_PER_HOUR=30`
- 設定可以寫在專案的 `.chip-ralph.conf`

**和 ralph-claude-code 的差別**：判斷進度時把**未追蹤的新檔**也算進去（原版沒算），並且排除 hook 自己的狀態檔，以及 chip-ralph 被導向 repo 內檔案的輸出。下一輪的 prompt 會自動帶入上一輪 verify 的失敗訊息和剩下的清單。日誌在 `.chip-ralph/`，這個目錄會自動加進 `.git/info/exclude`。

### 5b. ralph-orchestrator（功能完整版）

```bash
tar xJf outer-loop/ralph-orchestrator/ralph-cli-x86_64-unknown-linux-musl.tar.xz
sudo install -m 0755 ralph-cli-x86_64-unknown-linux-musl/ralph /usr/local/bin/
cp outer-loop/ralph-orchestrator/ralph.yml .      # 調整 --allow-edits 的 pattern
mkdir -p .ralph-tmp && export TMPDIR=$PWD/.ralph-tmp
ralph doctor -c ralph.yml
ralph run -a -c ralph.yml -P PROMPT.md
```

- 用 `custom` backend 執行 `chipagents batch --name ralph --allow-edits … --prompt "<prompt>"`。這是 static musl binary，CentOS 8 的 glibc 2.28 也能跑。
- **一定要設 `TMPDIR` 指到專案內**：prompt 超過 7000 字元時，Ralph 會改成傳「去讀 `<暫存檔>`」，暫存檔放在 `$TMPDIR`（已從原始碼確認）。ChipAgents 必須讀得到這個檔案。
- 結束條件是 agent 執行 `ralph emit LOOP_COMPLETE`，或輸出的最後一行剛好是 `LOOP_COMPLETE`。
- 它的「backpressure」是讓 agent 自己回報，**不會真的跑測試**。要客觀驗證，請搭配 ChipAgents 裡的 verify-gate 和 goal-gate。
- 注意它文件裡的 `custom_command:` **是錯的**，正確的 key 是 `command:`。
- 費用上限對純文字 backend 無效，因為一律記為 $0。

---

## 推薦組合（RTL 專案）

1. `/set-goal …` 產生 `.chipagents/goal.md`，寫 `.chipagents/verify.sh` 跑 lint 和模擬。
2. 安裝 goal-gate、verify-gate、review-gate（專案層級）和 superpowers。
3. 短任務：直接在 ChipAgents 下任務，三道關卡會讓它做完、驗證過、被 review 過才停。
4. 要離開座位：說「go nonstop」，完成 pre-flight 後再走。
5. 超長任務：用 `chip-ralph.sh` 或 `ralph-orchestrator` 跑外層迴圈，每一輪內仍然有上面的關卡。
6. 多個 agent 共用 repo：搭配 [git-flock-kit](https://github.com/githubhjs/git-flock-kit) 的 `git flock-commit`。

## 注意事項

- **已在真正的 ChipAgents 0.42.3（batch 模式）實測**，由 Josh_HUANG 執行：
  - review-gate 端到端：一律 BLOCK 的模擬 reviewer 在額度 4 時跑了 4 輪、呼叫 reviewer 4 次。
  - 真的 reviewer：使用者要求寫 TODO 時放行；同一個檔案在要求寫 DONE 時擋下，並指出 `note.txt:1`。
  - 遞迴防護：內部 run 記錄了 inner-skip。
  - goal-gate、nonstop、ralph-loop 依賴的是同一個實測過的機制（stdout + exit 1）。
  - 互動模式還沒實測。詳見 [docs/chipagents-hook-mechanics.md](docs/chipagents-hook-mechanics.md)。
- 想看 hook 實際收到什麼，可以暫時加一個 `command = "cat > /tmp/post-turn.json"` 的 `post_turn` hook。
- **多個關卡會共用 `post_turn_restarts` 這個重跑額度**，而且重跑次數 = `post_turn_restarts` − 1。設太小，關卡還沒擋完就沒額度了；設太大，花費會增加。
- **subagent 的回合也會觸發 `post_turn`**（實測），所以 goal-gate、verify-gate 也可能推 subagent 繼續做。關卡會跳過標記為 `CHIPAGENTS_HOOKS_INNER=1` 的 run。
- **Preserved thinking 模型**（`thinkingRequiresIdenticalPrefix`）：ChipAgents 文件提醒，restart 可能讓之前的 thinking blocks 失效。先小規模試用。
- hook 用 `$SHELL` 執行。在 tcsh 下也能用，因為指令只是 `bash "<路徑>"`。
- **ChipAgents 的 shell 工具名稱是 `Bash`**（實測：`tool_name` 就是 `"Bash"`；另外的 `Git` 工具只看到 status、log、diff 這類唯讀操作）。

## 沒有採用的專案

| 專案 | 原因 |
|---|---|
| hamelsmu/claude-review-loop（★722） | **沒有授權條款**，不能散布；而且需要 OpenAI Codex |
| Yeachan-Heo/oh-my-claudecode（★40k） | 101 MB 的 TypeScript，和 Claude Code 綁得太深，難以移植 |
| AnandChowdhary/continuous-claude（★1.4k） | 以 GitHub PR 為中心（開 PR、等 CI），不適合內部 RTL 流程 |
| sour4bh/claude-loop、sdsrss/loop_eng | 1～2 顆星的實驗性專案 |
| Claude Code 內建 `/goal`、`/loop` | 內建功能，ChipAgents 沒有；goal-gate 就是 `/goal` 在 ChipAgents 上的對應 |

## 測試狀態

真正 ChipAgents 0.42.3 上的實測結果，見「注意事項」第一項。

以下在 Windows Git Bash 用模擬輸入測過：

- **goal-gate**：
  - 沒有 goal 檔
  - 有未完成項目
  - 有進度時重設計數、沒進度時累加
  - 空轉達上限時放行
  - `[x]`、`[X]`、`[!]` 都算完成
  - Claude 模式（輸出到 stderr）
  - 跳過內部 run（`CHIPAGENTS_HOOKS_INNER=1`）
- **review-gate**（bash hook，搭配模擬 reviewer）：
  - 沒設 `REVIEW_GATE=1` 時不啟用；沒有 `REVIEW_GATE_PATHS` 時拒絕執行
  - 範圍內沒有修改、或只有範圍外的修改：不啟動 reviewer
  - PASS 以 0 結束；BLOCK 以 1 結束，印出問題清單且不含 VERDICT 那一行
  - 以最後一行 VERDICT 為準，前面引用的不算
  - 沒有 verdict、空輸出、找不到 binary：印出「NOT reviewed」並以 0 結束
  - reviewer 不會拿到 `--allow-edits` 或 `--skip-permissions`，帶著 inner 旗標執行，prompt 裡有使用者需求和範圍內的 diff
  - 跳過內部 run
- **nonstop**：
  - ChipAgents 版：啟動、推回去、自動關閉、手動關閉
  - Claude 原版：session 範圍、`stop_hook_active`
- **chip-ralph**：
  - 用模擬 agent 測過所有結束路徑（0、2、3、4、5、6、64）、stdin 模式、prompt 帶入上一輪 verify 失敗，以及輸出導向 repo 內時不誤判為有進度。
  - 用照 Batch Mode 文件寫的**模擬 `chipagents batch`** 測過：
    - `--prompt-file`、`--output`、`--stats-file`、`--allow-edits` 的多值參數（`rtl/**` 原樣傳入）
    - token 累加和 `TOKEN_BUDGET`
    - stats 是 `failed` 但結束碼為 0 的情況
    - 只出現在 `--output` 裡的 `LOOP_COMPLETE`
    - 舊式 `AGENT_CMD` 字串
- **全部 plugin**：`claude plugin validate` 通過，hooks.toml 都能被 Python tomllib 解析。

## 作者

Chih-Hsueh "Josh" HUANG
