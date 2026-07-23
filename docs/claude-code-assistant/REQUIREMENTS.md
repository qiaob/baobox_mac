# Claude Code 助手 — 需求文档

> 状态:已评审,进入开发。技术方案见同目录 `TECH_DESIGN.md`。

## 1. 背景与定位

程序员大量使用终端 AI 编码工具(Claude Code)。它的状态与配置分散在 `~/.claude/` 下的本地文件里(会话 JSONL、settings.json、hooks),缺少 GUI:看用量要开终端跑 CLI、改配置要手编 JSON、多会话跑长任务时不知道哪个结束了/哪个在等确认。

「Claude Code 助手」作为 Baobox 的一个 `ToolModule`,把这些状态收进菜单栏、把配置做成表单。**全部数据来自本地文件系统,不调用任何 AI API,不需要登录**——与 Baobox 本地优先的定位一致(版本检查是唯一的可选网络请求,手动触发)。

不做:AI 聊天窗、API key 管理、Cursor/Copilot 支持(后续再评估)、自定义 slash command 管理(已评审移除)。

## 2. 功能清单(按常用程度排序,菜单顺序与此一致)

### P0 — 菜单即仪表盘(每天多次)

| # | 功能 | 说明 | 验收标准 |
|---|---|---|---|
| 1 | 会话状态 | 菜单顶部状态行汇总:N 个运行中 / N 个等待确认;依赖 Baobox hooks(见 #5),未装 hooks 时按会话文件 mtime 降级推断"活跃" | 装好 hooks 后,新开/结束 Claude Code 会话,菜单状态 10s 内正确变化 |
| 2 | 会话续接(合并原"快速续接"+"会话浏览") | 菜单直接列最近 5 个会话(项目名 + 首条提示词摘要),点击即开终端 `cd <项目> && claude --resume <id>`;「浏览会话历史…」打开完整窗口:搜索、按项目/时间筛选、续接、复制 resume 命令、导出 Markdown、删除;可绑定全局快捷键(出厂不绑定,遵循框架惯例) | 点击最近会话后,终端在正确目录续接正确会话;窗口搜索能命中历史提示词 |
| 3 | 额度/用量展示 | 菜单显示当前 5 小时额度窗口:窗口内 token 用量、预估花费、距重置倒计时;今日累计花费。费用为按公开定价的**估算值**,UI 需标注 | 与 ccusage 同数据源(JSONL usage 字段)结果同数量级;窗口外显示"当前无活跃窗口" |
| 4 | 今日改动审计 | 窗口展示某日(默认今天)Claude 通过 Edit/Write 等工具改过的文件:按项目分组、文件路径、次数、末次时间;可在访达显示 | 当天有编辑的文件全部列出,路径可点击定位 |

### P1 — 后台增强(装好即长期生效)

| # | 功能 | 说明 | 验收标准 |
|---|---|---|---|
| 5 | 完成/等待通知 | 一键安装 Baobox hooks(Stop / Notification / SessionStart / UserPromptSubmit → 事件落盘,Baobox 监听);任务完成、Claude 等待权限确认时发系统通知,提示音可选,可全局开关 | 任务跑完 ≤5s 收到系统通知,含项目名 |
| 6 | 额度窗口提醒 | 用户可设每窗口 token 预算;用量达预算 80% 通知一次;窗口重置时可选通知"额度已恢复" | 阈值通知每窗口最多一次,不重复轰炸 |
| 7 | 危险命令卫士 | 一键安装 PreToolUse(Bash) hook;命令匹配危险规则(rm -rf、push --force、reset --hard、DROP TABLE 等预置 + 自定义正则)时阻断并把原因反馈给 Claude;规则可增删、可整体开关 | 让 Claude 执行 `git push --force` 被拦截且 Claude 收到拦截原因;卸载后不再拦截 |

### P2 — 配置中心(每周/按需)

> 设置页归组(已评审):权限 Allowlist、危险命令卫士规则、Co-Authored-By 开关、CLAUDE.md 管理
> 同属"编辑 Claude Code 配置",在设置页合并为一个「配置」节(折叠分组);
> Statusline(生成器带预览)与 MCP(列表+表单)交互形态不同,保持独立节。
>
> 交互原则(已评审):配置节不做"裸 JSON 数据搬进列表"式编辑——取值有限的配置一律可视化为
> 单选/多选/勾选控件并配人话说明,裸文本编辑只保留在「高级」折叠内。据此配置节新增覆盖:
> 默认权限模式(default/acceptEdits/plan/bypassPermissions 单选)、默认模型(单选)、
> 会话保留天数(选择器)、隐私开关(遥测/错误上报/非必要流量 多选)、
> 权限预设矩阵(按用途分组勾选)、卫士预置规则(带描述勾选)。

| # | 功能 | 说明 | 验收标准 |
|---|---|---|---|
| 8 | Statusline 定制 | 勾选段(模型、目录、git 分支、会话花费、时间)与分隔符,生成 shell 脚本写入 `~/.claude/baobox-statusline.sh` 并配置 settings.json 的 `statusLine`;可一键移除还原 | 新会话状态栏按所选段显示;移除后 settings.json 无残留 |
| 9 | 权限 Allowlist 管理 | 表单编辑用户级 settings.json 的 `permissions.allow/deny`,提供常用预设包(如前端: npm/pnpm/eslint);保留文件中其他字段不破坏 | 增删规则后 settings.json 合法且其余键原样保留 |
| 10 | MCP 服务器面板 | 列出用户级(~/.claude.json `mcpServers`)服务器:名称、类型、命令/URL;支持添加(表单)与删除 | 增删后 claude CLI 能正常读取配置 |
| 11 | CLAUDE.md 管理 | 列出全局 `~/.claude/CLAUDE.md` 与各已知项目(来自会话索引)的 CLAUDE.md 存在状态;一键用默认编辑器打开;缺失可从内置模板创建 | 列表覆盖所有出现过会话的项目 |
| 12 | 用量报表 | 窗口:按天(近 30 天)/按项目/按模型三个维度的 token 与估算费用汇总表;另含「调用统计」——Skill/斜杠命令触发次数、MCP 按服务器与工具的调用次数、内置工具调用分布(数据源:会话 JSONL 的 tool_use 块与 user 消息命令标记) | 三维度合计一致;调用统计与手工抽查一致 |

### P3 — 维护(低频)

| # | 功能 | 说明 | 验收标准 |
|---|---|---|---|
| 13 | Co-Authored-By 开关 | 一键切换 settings.json `includeCoAuthoredBy: false`,commit 不再署名 Claude;UI 说明仅影响以后提交,不改写历史 | 开关后新提交无 Co-Authored-By 尾行 |
| 14 | 磁盘清理 | 展示 `~/.claude` 占用分布(projects / todos / shell-snapshots 等);按"早于 N 天"清理会话 JSONL,删除前二次确认并显示可释放空间 | 清理后仅目标文件被删,统计刷新 |
| 15 | 版本检查 | 显示本机 claude CLI 版本;手动"检查最新版"(请求 npm registry,唯一联网点);提供复制升级命令 | 断网时优雅失败,不影响其他功能 |

## 3. 非功能需求

- 解析 `~/.claude/projects`(可能数 GB)不得阻塞主线程;菜单打开延迟 < 100ms(用缓存,后台刷新)。
- 对 settings.json / .claude.json 的所有写入必须保留未知字段;写前备份一份 `.baobox.bak`。
- 未安装/未使用过 Claude Code 时,模块降级为引导文案,不报错。
- 全部文案中英双语(xcstrings),遵循现有 L() 约定。
- 零第三方依赖;hooks 脚本只用 POSIX sh 内置能力,不依赖 jq/python。

## 4. 里程碑

- **MVP(本次)**:上表全部 15 项,深度按"说明"列;录屏/图表等增强不做。
- 后续观察:Cursor 支持、statusline 主题预设分享、审计 diff 详情。
