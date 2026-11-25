# 快速入口 · 开发与验证约定

> 2026-11-25。给实现者和验证者看的固定规则。每一步的设计在同目录的 `STEP-*.md` 里。
> 分工（用户定的）：设计者写设计文档 → 一个实现者照文档开发 → 另一个验证者独立验证 → 设计者合并、安装、向用户汇报。

## 1. 角色

- **设计者**：做设计决定，写进 `docs/launcher/`。实现中遇到文档没写的小细节，实现者选最简单的做法并在回报里列出，由设计者确认。
- **实现者**：只在指派给它的 worktree 里改文件；照设计文档做；某一条读完代码发现接不上或要动很多现有行为，就先不做那一条，回报里说明原因。
- **验证者**：只验证、不改代码、不提交。对照设计逐条检查，另写探针，不复用实现者的结论。

## 2. 语言

思考和回报用中文。代码标识符用英文，代码注释沿用仓库习惯写中文，提交信息用英文。

## 3. 必读

仓库根的 `CLAUDE.md`（架构、「约定」8 条、本地化规则）。和这一步有关的 `docs/launcher/TECH_DESIGN.md` 小节（尤其 §4 的「焦点」「选中行」两段，是已定的规则，不要改）。

## 4. 硬约束

- 打字路径（每次按键在主线程上跑的代码）零磁盘 IO、零模型调用、零网络。
- `@MainActor`、后台再回主线程的写法照 `CLAUDE.md` 约定 1；`@Published` 和界面状态只在主线程写。
- 不 force-unwrap、不 `try!`；外部数据全程容错。
- 只用项目里已出现的 API 和 Apple 稳定公开 API（部署目标 macOS 14）。
- 框架（`Core/`、`Modules/Launcher/`）不直接引用别的工具模块的类型，只经 `ToolModule` 的方法和 `Core/Launcher/` 里的协议。
- `Core/Launcher/` 和 `Modules/Launcher/Logic/` 只能 `import Foundation`（它们进单元测试 target）。纯逻辑放这两处并加单元测试。
- 新类型以 `Launcher` 开头（别的模块里的用它们自己的前缀），新建前在 `mac/Sources` 里 grep 确认不重名。
- 用户可见文案走 `L("…")` / `Text("…")`，每个 key 在 `mac/Sources/Resources/Localizable.xcstrings` 里有 en + zh-Hans，紧凑单行 JSON。改完校验：
  `python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"`
- 日志（`os.Logger`，subsystem `com.baobox.app`，category `launcher`）只记 bundle id、数量、布尔值、毫秒数，**不记任何内容**（文字、路径、文件名）；要读的字段用 `privacy: .public`。

## 5. 用户正在用这台机器

- **绝对不要** `make install` / `make dev` / `make stop`，不要运行编出来的 Baobox.app，不要动 `/Applications/Baobox.app`，不要退出或启动正在运行的 Baobox。装到用户机器上只由设计者做。
- 不要跑任何会成为 key 窗口、激活自己、抢键盘焦点的探针；不要向别的 App 发按键；`NSPasteboard.general` 只许读不许写。
- 探针里不真的执行动作：不开终端跑命令、不启动 claude、不发东西到手机、不发通知、不往用户目录写文件（测试用临时目录）。测到「会用什么参数调用现成入口」为止。
- 这个 shell 没有辅助功能权限（AX 调用返回 -25211），也不能模拟按键、点界面。真机上才能验证的，如实列进回报，不要猜。
- 系统日志用 `/usr/bin/log`（zsh 里 `log` 是内建命令）。

## 6. 构建与测试

命令前都带 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；测试必须带 `-derivedDataPath`（否则用户的 App 列表里会多出一个 Baobox 图标）：

```
cd <worktree>/mac
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Baobox.xcodeproj -scheme Baobox -derivedDataPath build.noindex/DerivedData test 2>&1 | grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED|error:" | tail
make build
find -d build.noindex -name "*.app" -type d -print0 | xargs -0 -n1 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u >/dev/null 2>&1
```

- 自己的草稿、探针、渲染图放在会话 scratchpad 下自己的子目录里；编译输出一律放在名字以 `.noindex` 结尾的目录里，用完先 `lsregister -u` 再删。
- 收尾检查：`mdfind 'kMDItemContentType == "com.apple.application-bundle" && kMDItemFSName == "Baobox*"c'` 应只有 `/Applications/Baobox.app`。
- 界面要自己看过：把真实视图文件编进探针，离屏渲染成 PNG 再用 Read 看图，深色浅色各一遍（做法见 scratchpad 里前几步的 `pr*/probe/`）。

## 7. 提交

- **做完一块、能编过就提交一次**。会话可能随时中断（已经发生过四次），提交过的才留得住。
- 每个提交带 `Co-authored-by: Claude <noreply@anthropic.com>`。提交前 `git status --short` 确认只有该有的文件（不要加 `Baobox.xcodeproj`、`build.noindex`、`Vendor`）。
- 不要 push，不要开 PR。

## 8. 回报

实现者：改了哪些文件与职责；动了哪些共享文件的哪些位置（`LauncherEngine` / `LauncherController` / `LauncherViews` / `ToolModule.swift` / 各模块 `…Tool.swift`）；自己补的细节；测试数与构建结果；渲染图的完整绝对路径和看图结论；和文档不一致并已改文档的地方；需要真机才能验证的清单；没把握的地方。

验证者：结论（可以合并 / 改完下列问题后可以合并 / 有严重问题）；问题清单按严重程度，每条写文件和行号、怎么确认的（推断的写明是推断）、建议；逐条对照设计；测试与构建结果；需要真机验证的清单。没发现问题就直说，不要凑。
