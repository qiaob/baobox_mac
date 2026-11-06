# 点通知跳回会话所在的终端

> 用户需求（2026-11-06）：「点击通知需要能跳到对应的窗口」—— 比如 Claude Code「等你确认 · baobox_mac」，
> 点了应该切回跑这个会话的那个 Otty 窗口。Codex「回合完成」同理。

## 1. 现状与问题

- 通知内核早就支持「点卡片」：宠物气泡卡片被点（没按钮时）、系统通知被点，都会回调投稿方的 `onAction("open")`。
  但 Claude Code / Codex 的通知没接这个回调，点了只是收起。
- 快速切换面板已有「切到会话所在终端」（`TerminalLauncher.findRunningSession` + `focusTerminalWindow`）：
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

`TerminalFocus.focus(_:)`（`Core/TerminalFocus.swift`）：

1. 用 Launch Services 前台化终端 App（macOS 14 起后台 App 直接 `activate()` 会被拒，与 `TerminalLauncher` 相同）。
2. **Otty**：`otty-cli pane list --json` 找到面板（环境变量里的 id 不带 `p_` 前缀）所在的窗口和标签页，
   依次 `window focus` → `tab focus` → `pane focus`。
3. **iTerm2 / 系统 Terminal**：沿用快速切换面板的 AppleScript，按 tty 选中窗口和标签页（首次会弹「自动化」授权）。
4. 其他终端（Ghostty、Kitty、VS Code…）：只能前台化 App，没有按标签页定位的接口。

Claude 的通知在发出那一刻取好终端位置（会话之后可能结束、被清掉）；没有位置信息（旧版脚本还没换、不认识的终端）时
退回快速切换面板的按进程猜。Codex 没有对应的猜法，没位置就不跳。

## 4. 没做

- 「会话续接」在 Otty 里开新窗口（`TerminalAppChoice` 还没有 Otty）。
- Ghostty 等终端精确到标签页。
