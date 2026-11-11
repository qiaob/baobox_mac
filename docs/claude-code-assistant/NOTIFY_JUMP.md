# 点通知跳回会话所在的终端

> 用户需求（2026-11-06）：「点击通知需要能跳到对应的窗口」—— 比如 Claude Code「等你确认 · baobox_mac」，
> 点了应该切回跑这个会话的那个 Otty 窗口。Codex「回合完成」同理。

## 1. 现状与问题

- 通知内核早就支持「点卡片」：宠物气泡卡片被点（没按钮时）、系统通知被点，都会回调投稿方的 `onAction("open")`。
  但 Claude Code / Codex 的通知没接这个回调，点了只是收起。
- 快速切换面板已有「切到会话所在终端」（`TerminalLauncher.findRunningSession` + `focusTerminalWindow`，2026-11 起收进 `focusRunningSession`，见 §3；
  #164 起这几个在 Claude 模块的 `ClaudeTerminal`）：
  按进程命令行（`--resume <id>` 或「项目里最新的会话」）猜是哪个进程，沿父进程找终端 App，iTerm2 / 系统 Terminal
  再用 AppleScript 按 tty 选中标签页。两个缺口：
  1. 同一个目录开着好几个会话时会猜错（用户常在 `~/cmb` 下同时开五六个 Claude）；
  2. 只认 `TerminalAppChoice` 里的终端，**不认 Otty**。

## 2. 做法：会话自己报「我在哪」

hook / notify 脚本就跑在会话的进程环境里，直接把终端位置记进事件：

| 字段 | 来源 | 用途 |
|---|---|---|
| `app` | `$__CFBundleIdentifier`（终端起 shell 时系统带上的 bundle id） | 前台化哪个 App |
| `otty_pane` | `$OTTY_PANE_ID`（Otty 给每个面板设的） | 精确到 Otty 的窗口 / 标签页 / 面板 |
| `tty` | `ps -o tty= -p $PPID`（会话进程的控制终端） | iTerm2 / 系统 Terminal 按 tty 选中标签页 |

- Claude：`report-event.sh` 读 stdin 的事件 JSON，在末尾 `}` 前补 `,"baobox_terminal":{…}` 再追加进 `events.jsonl`。
  值里去掉引号、反斜杠和换行，拼出来仍是合法 JSON；输入不是 `{…}` 时原样写。
- Codex：`codex-notify.sh` 对最后一个参数（事件 JSON）做同样的事。
- 已装 hooks / notify 的用户：启动时发现脚本内容不是新版就换掉（只动自家脚本文件，不碰 `settings.json` / `config.toml`）。

## 3. 点通知时

`TerminalFocus.focus(_:)`（`Core/Terminal/TerminalFocus.swift`）：

1. 用 Launch Services 前台化终端 App（macOS 14 起后台 App 直接 `activate()` 会被拒，与按进程找到会话后切窗口相同）。
2. **Otty**：`otty-cli pane list --json` 找到面板（环境变量里的 id 不带 `p_` 前缀）所在的窗口和标签页，
   依次 `window focus` → `tab focus` → `pane focus`。
3. **iTerm2 / 系统 Terminal**：沿用快速切换面板的 AppleScript，按 tty 选中窗口和标签页（首次会弹「自动化」授权；#164 起是 Core 的 `TerminalLauncher.selectTab`）。
4. 其他终端（Ghostty、Kitty、VS Code…）：只能前台化 App，没有按标签页定位的接口。

Claude 的通知在发出那一刻取好终端位置（会话之后可能结束、被清掉），点的时候直接用；没有位置信息（旧版脚本还没换、不认识的终端）时
退回按进程猜（命令行带 `--resume <id>`，或项目目录里裸跑的 `claude` 且这个会话是项目里最新的一条）。Codex 没有对应的猜法，没位置就不跳。

2026-11 起（#109 PR5a），点通知跳回和快速切换面板续接走同一个函数 `TerminalLauncher.focusRunningSession`（`ClaudeEnv.swift`；
#164 起是 `ClaudeTerminal.focusRunningSession`，在 `ClaudeTerminal.swift`）：
先用位置，用不了再按进程猜，都不行由调用方兜底（通知什么也不做，面板开新窗口续接）。两边只差一点：通知的位置直接用，面板的位置要先确认（§3.1）。

### 3.1 快速切换面板续接正在跑的会话（2026-11，#109 PR5a）

面板 ⏎ / 双击续接时，会话要是正开在某个终端里，就只把那个终端切到前台，不再开第二个窗口跑同一个会话。以前面板只按进程猜，
§1 的两个缺口在面板里一直留着；现在也先用 hook 记下的位置（`ClaudeLiveStatus` 里这个会话最近一次事件带的 `baobox_terminal`）。

但面板拿到的位置不能直接用：reporter 不报 SessionEnd，会话结束后它连同位置还在实时状态里留 6 小时（之后才清掉），
而面板要续接的常常正是早些时候关掉的会话 —— 直接用位置，会把一个只剩 shell、甚至已经关掉的标签页切到前台，而不是续接。
所以面板用位置之前先过两关（纯逻辑在 `Modules/ClaudeCode/ClaudeRunningSession.swift`，`BaoboxTests` 有单元测试）：

1. **会话还占着那个终端**（`ClaudeLiveStatus.currentTerminal(of:)`）：同一个 tty 上后来没见过别的会话。它结束后在同一个标签页里
   又开了一个会话，或者标签页关了、tty 被新标签页复用，那个终端就归后来的会话。没记 tty 的位置确认不了。
2. **那个 tty 上现在有 claude 在跑**：后台跑一次 `ps`，看那个 tty 上有没有 claude 进程。

两关都过才切过去（Otty 精确到面板；iTerm2 / 系统 Terminal 按 tty 选中标签页；其他终端只前台化 App）；
过不了就退回按进程猜（用同一份 `ps` 快照）；再不行照旧开新窗口 `claude --resume`。

| 情形 | 以前 | 现在 |
|---|---|---|
| 同一目录开着几个会话，续接其中一个（装了 hooks） | 按「项目里最新的一条」猜，可能切到别的会话的窗口 | 按 tty 切到它自己的标签页 |
| 会话正开在 Otty 里 | 认不出 Otty，再开一个新窗口 | 切到那个 Otty 面板 |
| 会话正开在终端偏好列表以外的 App 里（VS Code 等，hook 记下了 App） | 再开一个新窗口 | 把那个 App 切到前台（定位不到标签页） |
| 会话已经结束（标签页里只剩 shell，或开了别的会话） | 按进程猜，猜不到开新窗口 | 同左（位置过不了关） |
| 没装 hooks、6 小时没动静、位置里没记 tty | 按进程猜 | 同左 |

## 4. 没做

- 没在跑的会话续接时在 Otty 里开新窗口（`TerminalAppChoice` 还没有 Otty；正开在 Otty 里的会话见 §3.1）。
- Ghostty 等终端精确到标签页。
- 位置用不了、退回按进程猜时，§1 的第一个缺口还在：会话已经结束、同一目录里另有一个裸跑的 claude，而这个会话恰好是项目里最新的一条，
  会切到那个会话的窗口。hook 其实知道那个进程的 tty 属于谁，可以拿来排除，没做（按进程猜原样保留）。
