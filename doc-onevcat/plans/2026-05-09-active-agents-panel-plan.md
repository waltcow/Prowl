# Active Agents Panel

## Context

Prowl 当前对"agent 在不在跑"的检测很弱：状态只有 `idle` / `running` 两态（`supacode/Domain/WorktreeTaskStatus.swift`），粒度是 per-worktree，唯一信号源是 Ghostty 的 progress state（OSC 序列）。这意味着 (a) shell integration 缺失或 agent 不上报 progress 时完全识别不到；(b) 同一 tab 内多个 split pane 各跑一个 agent 时无法区分；(c) 没有 `blocked`（agent 等用户输入）状态；(d) 没有跨 worktree 的 agent 全局视图。

目标是新增 **Active Agents** 面板：

- 位于左侧 sidebar 底部、worktree `LazyVStack` 下方
- 高度可拖拽，可通过 footer 按钮折叠/展开
- 折叠时面板从底部消失，展开时**从底部滑入**（带动画）
- 列出**所有** worktree/tab/pane 中正在运行的 agent，状态分四档：working / blocked / done(unread idle) / idle
- 点击跳转到对应 worktree → tab → pane（surface）

参考实现是 [herdr](https://github.com/ogulcancelik/herdr) (Rust, ratatui)。本计划深度借鉴其 process detection + screen heuristics 混合检测算法，并改造为 Swift / GhosttyKit 适配的形态。

实施分两个阶段：**Phase 1 重写 agent 检测（核心，决定整个特性是否靠谱）**，**Phase 2 UI 与接线**。

---

## 关于 Ghostty fork（需要一个新决定）

**现状**：

- `ThirdParty/ghostty` 是 submodule，URL 指向 **upstream** `ghostty-org/ghostty`，目前锁在 tag `v1.3.1` (commit `332b2aef`)
- **没有 onevcat fork**，**没有任何本地 patch**（`change-list.md` 历来只记录 supacode 那边的同步，从未碰过 Ghostty 源码）
- Prowl 用 `make build-ghostty-xcframework` 在本地从 Zig 源码构建产物 `Frameworks/GhosttyKit.xcframework`

**需要的改动**：暴露 `ghostty_surface_pid()` C 导出（≤ 30 行 Zig 代码）。这是 Phase 1 的硬前置——没 PID 就没 herdr-style process detection。

| 方案 | 描述 | 优 | 劣 |
|---|---|---|---|
| **建 `onevcat/ghostty` fork + per-version patched 分支** *(选定)* | fork 仓库；每个上游 tag 创建一条独立的 `release/vX.Y.Z-patched` 分支，把 onevcat 的 patches 应用在该 tag 之上；submodule pin 到对应分支的 HEAD commit | 每个版本可追溯（不重写历史）；patches 可在分支间 cherry-pick；与 OpenClaw 派生但更适合 Ghostty 这种节奏稳定的发布 | 每次升级要新建分支 + cherry-pick；分支会随版本累积（接受） |

**分支命名**：`release/v<UPSTREAM_TAG>-patched`，例如 `release/v1.3.1-patched`、`release/v1.3.2-patched`。每条分支的"基底"是对应上游 tag，"附加" commits 都是 onevcat 的 patches（如 `ghostty_surface_pid` 导出）。

**新增文档**：`doc-onevcat/fork-sync-ghostty.md`，描述升级到新上游 tag 的流程：

```bash
# 在 ThirdParty/ghostty 内（首次需 git remote add onevcat git@github.com:onevcat/ghostty.git）
cd ThirdParty/ghostty
git fetch upstream --tags
git fetch onevcat

PREV=v1.3.1
NEXT=v1.3.2

# 1. 从新 upstream tag 拉一条 patched 分支
git checkout -b "release/${NEXT}-patched" "${NEXT}"

# 2. 把上一条 patched 分支相对其基底 tag 多出来的 commits cherry-pick 过来
#    "${PREV}..onevcat/release/${PREV}-patched" 选出 = patches
git cherry-pick "${PREV}..onevcat/release/${PREV}-patched"

# 3. 推到 fork（首次推新分支，不需要 force）
git push -u onevcat "release/${NEXT}-patched"

# 4. （回到 Prowl 主仓库）更新 submodule 指针
cd ../..
git -C ThirdParty/ghostty checkout "release/${NEXT}-patched"
git add ThirdParty/ghostty
git commit -m "ghostty: bump submodule to ${NEXT}-patched"

# 5. 重建 GhosttyKit
make build-ghostty-xcframework
```

**关于 force push**：per-version 分支模式下，patched 分支**只在新建时推一次**，之后不重写历史；所以不需要 `--force` / `--force-with-lease`。如果 cherry-pick 出错需要修补，先在 `release/${NEXT}-patched-fix` 分支调整，验证 OK 再 fast-forward 到 `release/${NEXT}-patched` 推上去。

---

## Phase 1 — Detection Layer Rewrite

### 1.1 设计原则（来自 herdr，验证过靠谱）

> herdr `INTEGRATIONS.md`: "process detection owns pane identity, liveness, and 'the process is gone'; screen heuristics remain the fallback for state."

**三层职责切分**：

- **Process detection** 决定 *身份与存活*（"这个 pane 是不是有 agent / 是哪个 agent / 还在不在"）
- **Screen heuristics** 决定 *fallback state*（working / blocked / idle）
- **Hook/integration**（**Phase 1 暂不做**）：未来可让 Claude/Codex hook 通过 socket 上报权威状态，Phase 1 完全不依赖

**四档状态机**：

```
检测器内部:  AgentRawState = { working, blocked, idle, unknown }
UI 显示:    DisplayState  = { working, blocked, done, idle }
```

- `done` 是派生：`state == idle && seen == false`
- `seen` 在 surface 被聚焦/可见时翻 true，在 `working|blocked → idle` 转移且当时不在前台时翻 false

### 1.2 暴露 Ghostty surface 的 child PID

**问题**：当前 GhosttyKit C API 没导出 surface 的 child process PID。Zig 内部 `termio.Exec.cmd.pid` 是有的（`ThirdParty/ghostty/src/termio/Exec.zig:1136`，`ThirdParty/ghostty/src/Surface.zig:140-142` 已有 `child_exited` 标志位证明 surface 持有这条信息）。

**改动**（在 `onevcat/ghostty` fork 的 `release/v1.3.1-patched` 分支上做；后续 Ghostty 升级时新建对应版本号的 `release/v<TAG>-patched` 分支并 cherry-pick）：

- `src/Surface.zig`：新增 `pub fn getChildPid(self: *Surface) ?std.posix.pid_t`，从 surface 持有的 `Termio.Exec` 中读出 `cmd.pid`
- `src/apprt/embedded.zig`：紧贴现有 `ghostty_surface_process_exited` (line 1082 in header) 后面新增 `export fn ghostty_surface_pid(surface: ?*Surface) c_int`，返回 0 表示未知或已退出
- `include/ghostty.h`（生成）：新增声明
- 通过 `make build-ghostty-xcframework` 重建 xcframework

### 1.3 macOS process detection helpers

**新文件**：`supacode/Infrastructure/AgentDetection/ProcessDetection.swift`

逐条移植 [`herdr/src/platform/macos.rs`](https://github.com/ogulcancelik/herdr/blob/master/src/platform/macos.rs) 算法到 Swift，使用 Darwin C 接口：

| 功能 | herdr Rust | Swift 实现 |
|---|---|---|
| 取 pty foreground PGID | `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` 读 `e_tpgid` | 同 syscall (`Darwin.proc_pidinfo`, `proc_bsdinfo`) |
| 列所有 PID | `proc_listallpids` | 同 |
| 过滤 fg group | 比较 `pbi_pgid == fg_pgid` | 同 |
| 取 argv[0] (catch `process.title="pi"`) | `sysctl(KERN_PROCARGS2)` 解析 | 同 (`Darwin.sysctl` with `[CTL_KERN, KERN_PROCARGS2, pid]`) |
| 取短名 fallback | `pbi_comm` | 同 |

**输出 struct**：`ForegroundJob { processGroupID: pid_t, processes: [ForegroundProcess] }`，`ForegroundProcess { pid, name, argv0?, cmdline? }`

### 1.4 Agent classifier

**新文件**：`supacode/Infrastructure/AgentDetection/AgentClassifier.swift`

跟 herdr 完全对齐，**初版即支持 herdr 列表的全部 11 个**（pi, claude, codex, gemini, cursor, cline, opencode, copilot, kimi, droid, amp）：

```swift
enum DetectedAgent: String, CaseIterable {
  case pi, claude, codex, gemini, cursor, cline
  case opencode, copilot, kimi, droid, amp
}

func identifyAgent(processName: String) -> DetectedAgent?
func identifyAgentInJob(_ job: ForegroundJob) -> (agent: DetectedAgent, name: String)?
```

`identifyAgentInJob` 复刻 herdr 的 wrapped-runtime 逻辑：如果前台进程名是 `node`/`bun`/`python`/`sh`/`bash`/`zsh`/`fish`/`tmux` 等通用 runtime，扫 `cmdline` 里 token 的 basename 找 agent 名（`node /path/to/codex` → `Codex`）；priority scoring 选最佳候选。

后续要支持新 agent，只需要 (a) 加 enum case (b) 在 `identifyAgent` 加映射 (c) 写 detector + 测试。

### 1.5 Screen heuristics — per-agent detectors

> 这一节详细解释每个状态怎么从屏幕文本判定。下面分两部分：先讲整体架构与每个状态的判定规则，再走一个具体例子。

#### 1.5.1 输入：viewport text

**怎么拿屏幕内容**：复用现有 C API `ghostty_surface_read_text`（已在 `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift:664` 用过 with selection）：

- 用 `ghostty_point_s { tag: GHOSTTY_POINT_VIEWPORT, coord: TOP_LEFT, x:0, y:0 }` 起，到 viewport 右下角
- 这给我们当前可见行的纯文本（应该是最后 N 行，N = surface 高度，~30-50 行）
- 这就对应 herdr 的 `terminal.detection_text()`
- 封装成 `GhosttySurfaceBridge.readViewportText() -> String?`

#### 1.5.2 整体策略：每个 agent 一个独立 detector

```swift
func detectState(agent: DetectedAgent?, screen: String) -> AgentRawState {
  guard let agent = agent else { return .unknown }
  switch agent {
  case .claude:   return detectClaude(screen)
  case .codex:    return detectCodex(screen)
  case .gemini:   return detectGemini(screen)
  // ... 每个 agent 一个
  }
}
```

每个 detector 是一个**纯函数** `(String) -> AgentRawState`，按优先级查 blocked → working → 默认 idle。**完全可单测，不需要 Ghostty / pty / async**。

#### 1.5.3 具体规则（直接来自 herdr，已被它的测试集验证）

每条规则都是"屏幕里出现某段特定 UI 文字"。这些字符串是 agent CLI 自己渲染的（"esc to interrupt"、"❯ Yes"、"approve?" 等），所以非常稳定。一旦 agent 升级 UI 文案，detector 就要更新——**这是已知的维护成本，跟 herdr 一样接受**。

##### Claude Code（最复杂的一个）

Claude 的 UI 是个结构化 prompt box：

```
  (agent 输出 / 工具结果)
  ─────────────────────  ← 上边框
  ❯ _                    ← 输入行
  ─────────────────────  ← 下边框
```

判定优先级：

1. **Blocked**: 内容里出现 `"do you want"` 或 `"would you like"`，且后面跟 `"yes"` 或 `❯`；或显式的 `"do you want to proceed?"` / `"waiting for permission"` / `"do you want to allow this connection?"`；或 (selection prompt + yes/no choice) 组合
2. **Working**: 把 prompt box **上面**的内容单独抽出来（用边框定位，避免误把上次的 `esc to interrupt` 当成本次状态），如果上面那段含 `"esc to interrupt"` / `"ctrl+c to interrupt"`，或行首是 spinner glyph (`✱✲✳✴…` 或 `·` 中点) 后跟 `"…"` (U+2026)
3. **否则 idle**

具体例子（直接是 herdr 测试 fixture）：

```
✽ Tempering…
─────────
❯
─────────
```

→ 行首 `✽` 是 spinner，后接 `…`，认定 **working**

```
Do you want to proceed?
❯ 1. Yes
  2. No

Esc to cancel · Tab to amend
```

→ 含 `"do you want to proceed?"` + `❯` 跟数字选项，认定 **blocked**

```
Task complete.
─────────────
❯
─────────────
```

→ 上面段无 spinner、无 interrupt 文字，认定 **idle**

##### Codex

判定（更平铺直叙，没结构化 box）：

1. **Blocked**: `"press enter to confirm or esc to cancel"` / `"enter to submit answer"` / `"allow command?"` / `"[y/n]"` / `"yes (y)"` 之一
2. **Working**: `"esc to interrupt"` / `"ctrl+c to interrupt"`，或行首 `•` 后跟 `"Working ("`（codex 自己的状态行 header）
3. **否则 idle**

##### 其他 agent

- **Gemini**: blocked = `"waiting for user confirmation"` 或 box 字符 `│` 起头 + `"Apply this change"` / `"Allow execution"` / `"Do you want to proceed"`；working = `"esc to cancel"`
- **Cursor**: blocked = `"(y) (enter)"` / `"keep (n)"` / 含 `"(y)"` + (`"allow"` 或 `"run"`)；working = `"ctrl+c to stop"` 或行首 `⬡⬢` + 含 `"ing"` 字（cursor 的 spinner）
- **Cline**: blocked = `"let cline use this tool"` 或 `[act mode]/[plan mode]` + `"yes"`；idle = `"cline is ready for your message"`；**注意 cline 默认是 working**（不像别的默认 idle），因为 cline 长时间执行不显式上报
- **OpenCode**: blocked = `"△ Permission required"` 或问题菜单 (`↑↓ select` + `Enter confirm/submit/toggle` + `Esc dismiss`)；working = `"esc to interrupt"`
- **Copilot (`ghcs`)**: blocked = `"│ do you want"` 或 `"confirm with ... enter"`；working = `"esc to cancel"`
- **Kimi**: blocked = `"allow?"` / `"confirm?"` / `"approve?"` / `"proceed?"` / `"[y/n]"` / `"(y/n)"`；working = `"thinking"` / `"processing"` / `"generating"` / `"waiting for response"` / `"ctrl+c to cancel"`
- **Droid**: blocked = `"EXECUTE"` 关键字 + 选择 chrome (`"enter to select"` / `"↑↓ to navigate"`)；working = 行首 braille spinner (U+2800-28FF) + `"esc to stop"`
- **Amp**: blocked = `"approve"` 选项 + `"allow all for this session"` 等组合 + (`"waiting for approval"` 或 `"invoke tool"` / `"run this command?"` 等 header)；working = `"esc to cancel"`
- **Pi**: working = `"Working..."`；其他 idle（最简单）

#### 1.5.4 单 tick 完整流程（带具体例子）

假设开了一个 pane，跑了 `claude`，让它读个文件。看一次 detection tick 干了什么：

```
t=0:   [process probe] proc_pidinfo(panePid).e_tpgid → fgPgid=12345
                       proc_listallpids 过滤出 pgid=12345 → [{pid:12345,name:"node",cmdline:"node /usr/local/bin/claude"}]
                       identifyAgentInJob → DetectedAgent.claude
                       AgentDetectionPresence: current=Claude (新识别)
       [screen heuristic] viewport text:
           "Reading file src/main.rs
            ✽ Pondering… (esc to interrupt)
            ─────────
            ❯
            ─────────"
       detectClaude:
         - 不含 do_you_want → 不 blocked
         - content_above_prompt_box() 切到 "Reading file..." + "✽ Pondering..."
         - 含 "esc to interrupt" → working
       stabilize_agent_state(Claude, prev=unknown, raw=working) → working
       发出 .agentStateChanged(surfaceID, agent: claude, state: working)

t=300ms: 同样流程，仍 working

t=2.4s:  Claude 完成读取，UI 变成
           "Read 1245 lines
            ─────────
            ❯
            ─────────"
         detectClaude: 上面段无 spinner、无 interrupt → raw=idle
         stabilize: previous=working, raw=idle, 距离上次 last_claude_working_at < 1.2s → 仍返回 working (粘滞窗口防抖)

t=3.5s:  同样 idle，但已超过 1.2s 粘滞窗口 → idle
         发出 .agentStateChanged(state: idle)

         此时如果 surface 不在前台 → seen=false → UI 显示 "done"
         否则 seen=true → UI 显示 "idle"

(用户跟 Claude 说 "rm -rf /tmp/test")
t=10s:   viewport:
           "Allow bash: rm -rf /tmp/test?

            Do you want to proceed?

            ❯ 1. Yes
              2. No

            esc to cancel"
         detectClaude:
           - has_claude_blocked_prompt 命中 "do you want to proceed?" → blocked
         发出 .agentStateChanged(state: blocked)
         seen 立即翻 true (blocked 不算"完成"，要醒目)

t=15s:   用户点 1 (yes)，Claude 又开始干活
         viewport 重新出现 "esc to interrupt" → working
```

**轮询频率**：

- agent 已识别：300ms tick
- agent 未识别：500ms tick
- "pending release" 期：50ms tick（agent 刚退出后短暂窗口，避免漏掉重新启动）
- Process probe 节流：5s 一次（除非满足"立即检查"条件：当前无 agent / fg PGID 变了 / 有 pending release）

**Agent 退出**：连续 6 次 process probe miss 才清掉 detected agent（约 1.8s @ 300ms tick），防止瞬时误读。

#### 1.5.5 多语言策略

**问题**：Screen heuristics 依赖匹配 agent CLI 渲染的 UI 文字。如果 agent 把 UI 本地化（中文 / 德文 / 日文 / ...），detector 会失效。

**现状盘点**（onevcat 实测过的 11 个 agent）：

| Agent | UI 是否本地化 | 风险等级 |
|---|---|---|
| Claude Code | 否，UI string 在 cli.js 里硬编码英文 | 极低 |
| Codex | 否，硬编码英文 | 极低 |
| Gemini CLI | 否 | 极低 |
| Cursor CLI | 否 | 极低 |
| Cline | 否（VS Code 扩展为主） | 极低 |
| OpenCode | 否 | 极低 |
| GitHub Copilot CLI | 否 | 极低 |
| **Kimi** | **可能是**——Moonshot 的中文优先 agent，部分 footer / prompt 可能是中文 | **真实风险** |
| Droid | 否 | 极低 |
| Amp | 否 | 极低 |
| Pi | 否 | 极低 |

模型对话内容当然是多语言的，但 detector 看的是 **agent CLI 的 UI chrome**（"esc to interrupt"、"Do you want to proceed?"、"[y/n]"），这些 99% 是英文常量。

**信号天然分两类**：

- **A. Language-neutral signals**（无视语言，最稳）：
  - Spinner glyph：`✱✲✳✴✵`（Claude）、`⬡⬢`（Cursor）、`⠋⠙⠹⠸`（Droid braille）、`✽` 等
  - Box drawing chars：`─ │ ❯ ⌕`（Claude prompt box / Gemini `│ Apply` 等）
  - Control keys：`esc`, `ctrl+c`, `enter`, `tab` —— 即便本地化也保持英文（标准 CLI 惯例）
  - Symbols：`[y/n]`, `(y/n)`, `→ ↑ ↓`, `?`, ellipsis `…`
  - 数字选项：`1.` `2.` `3.`
- **B. English-text signals**（最常见但易被本地化击穿）：`"esc to interrupt"`、`"do you want to proceed"`、`"approve?"`、`"thinking"`、`"waiting for"` 等多词短语

**Phase 1 实装策略——分层防御**：

1. **每个 detector 内部，A 类信号优先级抬高**
   - working / blocked 判定用 `(A) OR (B)`，A 命中即不再看 B
   - 例：Claude working = `行首 spinner glyph`（A）OR `"esc to interrupt"`（B）
   - 例：blocked = `(selection prompt + ❯/数字选项)`（A 组合）OR `"do you want to proceed?"`（B）
   - 这种"或"组合本来就在 herdr 里大量出现，A 类能命中的场景保留语言无关性

2. **Detector 注释里标注每条规则的类别**

   ```swift
   // language-neutral: spinner glyph at line start
   if hasSpinnerActivity(above) { return .working }
   // english-only: tool footer hint
   if aboveLower.contains("esc to interrupt") { return .working }
   ```

   将来某 agent 突然本地化时，能一眼定位哪条规则要扩。

3. **Kimi 单独留一个 multi-pattern 接口**

   ```swift
   func detectKimi(_ content: String) -> AgentRawState {
     let blockedPatterns: [String] = [
       "allow?", "confirm?", "approve?", "proceed?",
       "[y/n]", "(y/n)",
       // 中文待 onevcat 跑实例后补充: "允许?", "确认?", ...
     ]
     // ...
   }
   ```

   等 onevcat 实际跑 Kimi 抓到 viewport sample 再补中文 pattern。其他 agent 维持纯英文。

**Phase 1 不做但 Phase 3 应该做**：

- **Hook integration（herdr 也走这条路）**：Claude / Codex / OpenCode 都暴露了 hook，可让它们直接通过 socket 上报 `working/blocked/idle` **语义状态**——完全无视 UI 文字。这是治本方案，但 Phase 1 范围外。

### 1.6 Per-pane state machine + stabilization

**新文件**：`supacode/Domain/AgentDetection/PaneAgentState.swift`

复刻 herdr [`pane/state.rs`](https://github.com/ogulcancelik/herdr/blob/master/src/pane/state.rs) 的 `PaneState`：

```swift
struct PaneAgentState {
  var detectedAgent: DetectedAgent?
  var fallbackState: AgentRawState
  var state: AgentRawState           // = fallback (Phase 1 没 hook authority)
  var seen: Bool = true
  var lastChangedAt: Date            // 用于 UI 排序
}

// 抖动控制
struct AgentDetectionPresence {
  var currentAgent: DetectedAgent?
  var consecutiveMisses: UInt8       // 6 次连续 miss 才清
}

func stabilizeAgentState(
  agent: DetectedAgent?,
  previous: AgentRawState,
  raw: AgentRawState,
  now: Date,
  lastClaudeWorkingAt: inout Date?
) -> AgentRawState
```

`stabilizeAgentState` 关键逻辑（仅对 Claude）：working → idle 转移有 **1.2s 粘滞窗口** (`CLAUDE_WORKING_HOLD`)，防止 tool result 渲染瞬间被误读为 idle。其他 agent 直接透传 raw。

### 1.7 Process syscall smoke test（**Phase 1 第一个动作**）

**前置事实**：Prowl **没开 App Sandbox**（`ENABLE_APP_SANDBOX = NO` in `supacode.xcodeproj/project.pbxproj`，`supacode.entitlements` 也无 `com.apple.security.app-sandbox`）。Hardened runtime + notarization 不限制 `proc_listallpids` / `proc_pidinfo` / `sysctl(KERN_PROCARGS2)` 这类只读 syscall。

所以这一步**不是验证 sandbox**，只是常规 smoke test 确认调用方式正确、数据格式符合预期：

1. 在 Debug 构建里写一个 ~50 行的小测试：spawn 一个 shell，跑 claude，调上面三个 syscall 抓一帧数据 dump 出来比对预期。直接放在 `supacodeTests/Spikes/ProcessDetectionSpikeTests.swift` 跑一次扔掉
2. 验证 `proc_pidinfo` 返回的 `e_tpgid` 跟独立 `ps` 命令的结果一致
3. 验证 `KERN_PROCARGS2` 解析能正确拿到 `argv[0]`（比如 node spawn 的 claude 应该能看到 `claude` 而不只是 `node`）

通过即开始正式实装；任何 syscall 报错（不太可能）才需要重新评估。

### 1.8 Wiring into existing model

**修改文件**：

- `supacode/Domain/WorktreeTaskStatus.swift` — 不动现有 enum；引入并行的新模型 `AgentRawState` 在 `AgentDetection/` 下
- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` — 新增 `surfaceAgentStates: [GhosttySurfaceID: PaneAgentState]`，在 surface 创建/关闭时启停 detection task
- `supacode/Clients/Terminal/TerminalClient.swift` — `Event` 新增 `.agentStateChanged(worktreeID:surfaceID:state:agent:)` 和 `.agentSeenChanged(...)`
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — 转发新事件
- 复用现有 `onTaskStatusChanged` 的派发模式（`WorktreeTerminalManager.swift:248`）

**新建顶层 registry**：`supacode/Features/ActiveAgents/Models/ActiveAgentsRegistry.swift`，`@MainActor @Observable class`，订阅所有 worktree 的 agent state 事件，维护跨 worktree 的扁平 `[ActiveAgentEntry]`，给 reducer 读。

### 1.9 测试策略

- **Unit test 全覆盖**：`ScreenHeuristics` + `AgentClassifier` + `PaneAgentState.stabilize` — 全是纯函数 / 纯数据，**直接移植 herdr `detect.rs` 测试段（约 700 行）的所有 fixture**。每个 detector 都有 working/blocked/idle 样本
- **Integration test**：`PaneAgentState` 的 detection loop 跑在 `TestClock` 上，喂假的 viewport text + 假的 ForegroundJob，断言状态转移
- **Manual smoke**：跑 claude/codex 各开一个 pane，肉眼验证 working ↔ blocked ↔ idle 切换
- **不写自动化 e2e**——对 Ghostty 真 pty 跑端到端的成本太高，靠手工冒烟覆盖

---

## Phase 2 — UI & Wiring

### 2.1 Layout（支持从底部滑入动画）

**核心问题**：希望 footer 按钮一点，面板**从底部滑出**带动画。SplitView 在 hidden/visible 之间切换会重建视图层级，动画会跳。

**方案**：始终用 VStack；面板用条件 `if !isHidden` 渲染并配 `.transition(.move(edge: .bottom))`；resize handle 是 panel 自带的顶边 drag bar，不依赖 SplitView。

```swift
// SidebarListView 改造后
ZStack(alignment: .bottom) {
  VStack(spacing: 0) {
    // 上半：worktree 列表，吃掉剩余高度
    ScrollView { LazyVStack { repositoryItems… } }
      .scrollIndicators(.never)
      .frame(maxHeight: .infinity)

    // 下半：Active Agents 面板（含顶部 resize handle）
    if !isPanelHidden {
      ActiveAgentsPanel(store: …)
        .frame(height: panelHeight)              // 用户拖拽时变化
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}
.animation(.spring(response: 0.4, dampingFraction: 0.85), value: isPanelHidden)
.safeAreaInset(.bottom) { SidebarFooterView(...) }
.clipped()  // 防止 transition 期间溢出 sidebar 边界
```

`ActiveAgentsPanel` 内部：

```swift
VStack(spacing: 0) {
  // 顶边 drag handle
  Rectangle()
    .fill(.separator)
    .frame(height: 1)
    .overlay(Color.clear.frame(height: 6))     // 点击/拖拽热区
    .contentShape(Rectangle())
    .gesture(
      DragGesture()
        .onChanged { v in
          panelHeight = clamp(panelHeight - v.translation.height, 120, maxAllowed)
        }
    )
    .onHover { hovering in NSCursor.resizeUpDown.set() }   // 视觉反馈

  // 标题栏 + 列表
  Text("Active Agents")
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 12).padding(.top, 8)
  ScrollView {
    LazyVStack(spacing: 0) {
      ForEach(entries) { entry in
        ActiveAgentRow(entry: entry).onTapGesture { … }
      }
    }
  }
}
```

**与 SplitView 的对比**：

- SplitView 现有组件依赖两侧都存在 + 拖动 divider，无法很好处理"右侧/下侧消失"的动画过渡
- 用 transition + 自带 drag handle 更适合这种 "show/hide with slide-up" 场景
- 缺点：失去 SplitView 的"双击均分"快捷功能；不重要

**持久化**：

- `@Shared(.appStorage("activeAgentsPanelHidden")) var isPanelHidden: Bool = false`
- `@Shared(.appStorage("activeAgentsPanelHeight")) var panelHeight: Double = 200`

### 2.2 TCA feature

**新文件**：`supacode/Features/ActiveAgents/Reducer/ActiveAgentsFeature.swift`

```swift
@Reducer struct ActiveAgentsFeature {
  @ObservableState struct State: Equatable {
    var entries: IdentifiedArrayOf<ActiveAgentEntry> = []
    @Shared(.appStorage("activeAgentsPanelHidden")) var isPanelHidden: Bool = false
    @Shared(.appStorage("activeAgentsPanelHeight")) var panelHeight: Double = 200
  }
  enum Action {
    case task                                  // 启动时订阅 registry
    case agentEntriesUpdated([ActiveAgentEntry])
    case entryTapped(ActiveAgentEntry.ID)
    case togglePanelVisibility
    case panelHeightChanged(Double)
  }
}
```

挂载位置：作为 `RepositoriesFeature` 的子 reducer（`var activeAgents: ActiveAgentsFeature.State` + `Scope { state: \.activeAgents, action: \.activeAgents }`）。Sidebar 范畴内，不需要爬到 AppFeature。

### 2.3 Active Agents row UI

**新文件**：`supacode/Features/ActiveAgents/Views/ActiveAgentRow.swift`

布局：

```
[icon]  agent name             [status pill]
        worktree · tab · pane
```

- icon：复用 `CommandIconMap` 的 `TabIconSource`（`supacode/Features/Terminal/Models/CommandIconMap.swift`）
- agent name：`.body.monospaced()`
- 副标题：`.caption.foregroundStyle(.secondary)`，格式 `worktree-name · tab-N · pane-N`
- status pill：颜色严格走 system color（CLAUDE.md 强制）
  - blocked → `.red`
  - working → 旋转中的 spinner + `.orange`/`.yellow`
  - done → `.blue`（亮，提示未读）
  - idle → `.secondary`（灰）

排序（在 reducer 里算）：blocked → working → done → idle，组内按 `lastChangedAt` 倒序。

空态：`Text("No active agents").font(.caption).foregroundStyle(.secondary)` 居中。

### 2.4 Footer hide toggle

**修改**：`supacode/Features/Repositories/Views/SidebarFooterView.swift`

在现有 `HStack` 里（archive / refresh / settings 旁边）加一个按钮：

```swift
Button {
  store.send(.activeAgents(.togglePanelVisibility))
} label: {
  Image(systemName: isHidden ? "rectangle.bottomthird.inset" : "rectangle.bottomthird.inset.filled")
}
.help(isHidden ? "Show Active Agents" : "Hide Active Agents")
```

（CLAUDE.md "Buttons must have tooltips"）

### 2.5 Click-to-focus

新增 TerminalClient 命令 `.focusSurface(worktreeID:tabID:surfaceID:)`：

1. `setSelectedWorktreeID(worktreeID)` — 切换 worktree（已有）
2. 切到对应 `tabID`（`TerminalTabManager` 里有 `selectedTabID`，扩展为带 surface 参数）
3. 在 split tree 里把焦点设到那个 surface（调用 Ghostty focus + `selectedSurfaceID` 更新）

reducer 流：`entryTapped(id)` → 找 entry 的 `(worktreeID, tabID, surfaceID)` → `terminalClient.send(.focusSurface(...))` → reducer 同时 `repositories.select(worktreeID)`。

副作用：聚焦后 registry 监听 focus 事件、把对应 entry 的 `seen` 翻 true，UI 上 `done` 立刻降级成 `idle`。

### 2.6 UX 收尾

- min panel height: 120pt；max: container height − 200pt（保证 worktree list 可见）
- 拖动时 throttle 持久化（避免每帧写 UserDefaults）
- 动画 spring 参数：`response: 0.4, dampingFraction: 0.85`（手感舒服，不弹）
- Dynamic Type 友好：所有文字走 `.font(.caption)` / `.body` 等系统 style
- `.scrollIndicators(.never)` 与 worktree list 一致

---

## File Map

### 新增

**Ghostty fork patches** (在 `onevcat/ghostty` 的 `release/v1.3.1-patched` 分支)

- `src/Surface.zig` — `getChildPid()`
- `src/apprt/embedded.zig` — `ghostty_surface_pid` C export

**Prowl 主仓库**

- `supacode/Infrastructure/AgentDetection/ProcessDetection.swift`
- `supacode/Infrastructure/AgentDetection/AgentClassifier.swift`
- `supacode/Infrastructure/AgentDetection/ScreenHeuristics.swift` (可拆 `Detectors/{Claude,Codex,Gemini,Cursor,Cline,OpenCode,Copilot,Kimi,Droid,Amp,Pi}Detector.swift`)
- `supacode/Domain/AgentDetection/AgentRawState.swift`
- `supacode/Domain/AgentDetection/DetectedAgent.swift`
- `supacode/Domain/AgentDetection/PaneAgentState.swift`
- `supacode/Features/ActiveAgents/Models/ActiveAgentsRegistry.swift`
- `supacode/Features/ActiveAgents/Models/ActiveAgentEntry.swift`
- `supacode/Features/ActiveAgents/Reducer/ActiveAgentsFeature.swift`
- `supacode/Features/ActiveAgents/Views/ActiveAgentsPanel.swift`
- `supacode/Features/ActiveAgents/Views/ActiveAgentRow.swift`
- `supacodeTests/AgentDetection/...` — 多个测试文件，移植 herdr `detect.rs` 测试 fixture

**文档**

- `doc-onevcat/active-agents-panel.md` — 本计划
- `doc-onevcat/change-list.md` — 增加 "Ghostty fork patches" 段
- `doc-onevcat/fork-sync-and-release.md` — 增加 Ghostty fork rebase 子节

### 修改

- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` — per-surface agent state，spawn detection task
- `supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift` — `readViewportText()` / `childPID`
- `supacode/Clients/Terminal/TerminalClient.swift` — 新事件 + `focusSurface` 命令
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — 转发事件 + 实现 focusSurface
- `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` — 嵌入 `ActiveAgentsFeature`
- `supacode/Features/Repositories/Views/SidebarListView.swift` — 嵌入 ZStack + ActiveAgentsPanel + transition
- `supacode/Features/Repositories/Views/SidebarFooterView.swift` — 加 hide toggle
- `supacode/Features/Terminal/BusinessLogic/TerminalTabManager.swift` — 扩展 focus 到 surface 级
- `Frameworks/GhosttyKit.xcframework/.../ghostty.h` — 头文件同步（`make build-ghostty-xcframework` 自动）
- `.gitmodules` — `ThirdParty/ghostty` URL 改指 `onevcat/ghostty`

---

## Verification

**Phase 0（spike，最先做）**：

1. 写小 smoke test 验证 `proc_pidinfo` / `proc_listallpids` / `sysctl(KERN_PROCARGS2)` 调用方式正确（详见 §1.7；Prowl 不在 sandbox 下，不预期阻碍）
2. 临时给 GhosttyKit 加 `ghostty_surface_pid`（在 submodule 里直接改，不进 PR），跑通 → 验证 fork 方案可行
3. 决定方向后 setup `onevcat/ghostty` fork 正式落地（`release/v1.3.1-patched` 分支）

**Phase 1 验证（不依赖 UI）**：

1. `make test` — 重点跑 `AgentDetectionTests` / `ScreenHeuristicsTests`，所有从 herdr 移植的 fixture 必须通过
2. `make run-app` Debug 构建，开 1 个 pane 跑 `claude`、1 个跑 `codex`、1 个跑 `bash`：
   - `make log-stream` 观察 `agentStateChanged` 事件序列：claude 启动 → working → blocked (问 yes/no) → working → idle 全链路
   - 关掉 agent 后状态在 6 次 miss 内（约 1.8s @ 300ms tick）回到 unknown
3. Split 一个 pane 在同一 tab 里再跑一个 agent，确认 per-surface 粒度成立

**Phase 2 验证（UI）**：

1. `make build-app` + `make run-app` — sidebar 底部出现 Active Agents 面板
2. 点击 footer toggle：面板**从底部滑入/滑出**，动画顺畅；状态在重启 app 后保持
3. 拖动 panel 顶边 drag handle：高度变化，重启后保持
4. 列表实时反映 agent 状态：
   - 启动 claude → 出现一条 entry，状态 working
   - claude 问 `Do you want to proceed?` → entry 切到 blocked，红色徽章
   - 在另一个 worktree 等 claude 完成 → entry 切到 done，蓝色（未读）
   - 点击 → sidebar 选中切到那个 worktree，tab 切对，pane 聚焦，done 立刻降为 idle
5. 关掉所有 agent，列表显示空态
6. `make check` 通过；`make test` 全绿

**Manual smoke**：

- 同一 tab 双 split：claude 在左、codex 在右，两条 entry 同时存在且独立
- agent 通过 `node /path/to/codex` 间接启动也能识别（cmdline 扫描）
- 切换 worktree 时 `seen` 标记正确翻转
- 长时间运行 (>10min) 不爆 CPU：detection tick 应非常便宜

---

## 风险与开放项

1. **Process syscall 调用形态**（低）— Prowl 无 sandbox，syscall 应直接可用；Phase 0 smoke test 验证一次即可，不预期阻碍。见 §1.7
2. **Ghostty fork 维护成本** — 见顶部"关于 Ghostty fork"段。每次上游版本升级要新建 `release/v<NEXT>-patched` 分支并 cherry-pick patches，可接受
3. **Agent 列表的扩展性** — 新 agent 需要同时改 enum + classifier + detector + 测试。可接受，与 herdr 同
4. **Hook integration（未来）** — 本计划完全不做。Phase 1+2 落地稳定后，再考虑给 claude/codex/opencode 装 hook 上报权威状态（herdr 的 socket API 模型可以照搬）
5. **ScreenHeuristics 维护策略——为什么不嵌 herdr 二进制**：

   考虑过把 herdr 的 Rust `detect.rs` 编成 dylib 直接链接。**最终选择走 Swift 移植路线**，理由：

   - **detect.rs 95% 是 `.contains("...")` 调用**，没有 Rust-only 算法精华，移植 1-2 天搞定
   - 嵌 Rust 二进制要加 cross-compile pipeline、universal dylib 签名、hardened runtime + 第三方 dylib 的 library validation 豁免、FFI marshaling（每 tick 跨 boundary 传 viewport text）
   - herdr `detect.rs` 不是干净 leaf 模块——`use crate::platform::ForegroundJob` 跟其他模块耦合，要么编整个 crate 要么 fork 出 sub-crate
   - 维护成本不会因为嵌入而消失：agent CLI 升级时 herdr 自己也得跟，我们等 herdr release 反而**延迟更长**
   - 二次定制（Kimi 中文 pattern）会变成"改 Rust + 重编 + 重签 + 重 ship"——比改 Swift 痛苦 N 倍

   **代替方案：drift-check skill**（一次性投入半天）：

   - 新建 `~/.claude/skills/herdr-detect-sync/SKILL.md`，每月 onevcat 主动跑一次（或加到 cron）
   - 拉最新 `https://raw.githubusercontent.com/ogulcancelik/herdr/master/src/detect.rs`
   - 跟 `supacode/Infrastructure/AgentDetection/ScreenHeuristics.swift` 做语义 diff：提取每个 agent detector 的 pattern 字符串列表，对比新增 / 删除
   - 输出"herdr 新加了哪些 pattern" + "我们有但 herdr 删了哪些"的报告，onevcat review 后手动 cherry-pick 进 Swift
   - 这样我们在跟进 agent CLI 变化上**不慢于 herdr**（甚至能更快——不用等他们 release）
6. **panelHeight 在 sidebar 整体高度变化时的 clamp** — 窗口缩小到 worktree list 没空间时要自动让出。需要在 layout 里加 `GeometryReader` 或在 onChange 里 clamp。（CLAUDE.md "Avoid GeometryReader when containerRelativeFrame() ... would work"——优先尝试 containerRelativeFrame）
