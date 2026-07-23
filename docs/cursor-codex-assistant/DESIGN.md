# Cursor / Codex 助手 — 需求与技术方案(合并)

> 独立 `ToolModule`,模块 id `aitools`,名称「Cursor / Codex 助手」,symbol `wand.and.stars`。
> 定位与「Claude Code 助手」一致:只读写本地文件,不调 AI API、不需登录。
> 已评审:只做最核心 5 项,菜单排序按常用度。

## 0. 调研结论(数据面事实)

### Codex CLI(OpenAI 终端 agent)

- 会话:`~/.codex/sessions/YYYY/MM/DD/rollout-<时间戳>-<uuid>.jsonl`(v0.136+ 另有 `archived_sessions/` 同结构,MVP 只扫 `sessions/`)。首行含 SessionMeta(id/cwd 等);token 用量在 `event_msg` 且 `payload.type=="token_count"` 的行(input_tokens / cached_input_tokens / output_tokens / total_tokens)。
- 续接:`codex resume <session-id>`、`codex resume --last`。
- 配置:`~/.codex/config.toml`(用户级;`CODEX_HOME` 可重定位,MVP 不支持):
  - `model = "..."`
  - `approval_policy = "untrusted" | "on-request" | "never"`
  - `sandbox_mode = "read-only" | "workspace-write" | "danger-full-access"`
  - `notify = ["<程序路径>"]`(仅用户级生效);Codex 每个回合结束调用该程序,并把事件 JSON(agent-turn-complete,含 last-assistant-message 等)作为最后一个参数传入。
- 全局指令文件:`~/.codex/AGENTS.md`。

### Cursor(GUI 编辑器)

- 项目规则:`<项目>/.cursor/rules/*.mdc`(YAML frontmatter + 正文,官方现行推荐);旧式 `<项目>/.cursorrules` 仍被读取。
- MCP:`~/.cursor/mcp.json`(全局)与 `<项目>/.cursor/mcp.json`,结构与 Claude 的 `mcpServers` 相同(`{"mcpServers":{"name":{"command":...,"args":[...],"env":{...}} }}`)。
- 用量/额度在服务端,需登录态,**不做**(与本地优先冲突)。聊天记录在 state.vscdb(SQLite),解析成本高且格式不稳,**不做**。

## 1. 功能清单(5 项,按常用度排序)

| # | 功能 | 说明 | 验收标准 |
|---|---|---|---|
| 1 | Codex 会话浏览/续接 | 菜单列最近 5 个 Codex 会话(项目名+首条用户输入摘要),点击开终端 `cd <cwd> && codex resume <id>`;「浏览全部…」进中心窗口列表(搜索/续接/复制命令/删除) | 点击后终端在正确目录续接正确会话 |
| 2 | Codex 完成通知 | 设置里一键把 Baobox 通知程序写入 config.toml `notify`;回合结束时系统通知(含项目名与最后回复摘要);可开关 | 回合结束 ≤5s 收到通知;移除后 config.toml 无残留 |
| 3 | Codex 配置可视化 | approval_policy 单选(三档,含人话说明)、sandbox_mode 单选(三档,danger 红色警示)、默认 model 输入/常用值单选 | 改动后 `codex` 读到新值;文件其余内容与注释不被破坏 |
| 4 | Cursor Rules 管理 | 维护项目列表(用户添加文件夹,持久化);每项目列出 `.cursor/rules/*.mdc` 与旧式 `.cursorrules`;一键用默认编辑器打开;内置模板(通用/前端/Python)一键写入 `.cursor/rules/` | 模板写入后 Cursor 可识别;列表状态准确 |
| 5 | Cursor MCP 面板 | 全局 `~/.cursor/mcp.json` 服务器列表 + 增删(表单与 Claude MCP 面板同构,复用 UI 组件) | 增删后 Cursor 能正常加载配置 |

菜单结构(常用度顺序):Codex 状态行(最近会话数,置灰)→ 最近 Codex 会话 ≤5 → 浏览全部… → 分隔 → Cursor Rules(项目子菜单)→ 分隔 → 完成通知开关。设置 Tab 两节(segmented):Codex(配置可视化 + 通知)/ Cursor(项目列表 + 模板 + MCP)。

## 2. 技术要点

- 文件:`Sources/Modules/AITools/` 下 `CodexEnv.swift`(路径/TOML 读写/二进制探测)、`CodexSessionIndex.swift`(快扫,复用 ClaudeSessionIndex 的头尾读取思路,独立实现避免耦合)、`AIToolsNotify.swift`(notify 程序生成 + 事件文件监听,复用 ClaudeLiveStatus 的 DispatchSource 模式)、`CursorEnv.swift`(rules/mcp.json 读写、项目列表 UserDefaults 持久化)、`AIToolsTool.swift`(模块壳)、`AIToolsSettingsView.swift`、中心窗口视图并入 `ClaudeCodeCenterWindow` **不做**——独立轻量窗口 `AIToolsSessionsWindow.swift`,避免两模块互相依赖。
- **TOML 编辑(关键取舍)**:零依赖且必须保注释,不写通用 TOML 解析器。只做"顶层标量键行编辑":逐行扫描,匹配 `^\s*key\s*=` 的首行整行替换;不存在则追加到文件末尾(在任何 `[section]` 之前——若文件含 section,则追加到第一个 `[` 行之前);写前备份 `.baobox.bak`。`notify` 数组键同样按整行处理。读取同理用正则提取,值只支持基础标量/单行数组——超出即在 UI 显示"手动管理"并置灰控件,不冒险改写。
- notify 程序:`supportDir/codex-notify.sh`,内容 `printf '%s\n' "$1" >> "<events 文件>"`(事件 JSON 是最后一个参数,MVP 取 `$1` 前先 shift 到最后一个:用 `for a; do last=$a; done`);Baobox 监听该文件发通知,复用 UN 通知封装(`ClaudeNotifier` 泛化或平行实现)。
- Codex 会话快扫:目录三层(年/月/日)递归枚举 jsonl,mtime 降序取前 N;标题取首个用户输入(SessionMeta 后的首条 user 文本),id 优先取 SessionMeta 的 id 字段,取不到再从文件名解析 uuid;全部容错。
- 硬约束与「Claude Code 助手」相同:零依赖、并发规范、容错不 crash、L() 双语词条、未安装(目录不存在)则降级引导文案。

## 3. 明确不做(本期)

- Cursor 用量/额度(需登录态)、聊天记录解析(state.vscdb 不稳定)。
- Codex 用量报表(token_count 聚合)——数据已在会话文件里,留作下期,不阻塞本期 5 项。
- 项目级 Codex config、`CODEX_HOME`/`archived_sessions`、Cursor 全局 rules 目录。
