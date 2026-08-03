# CLAUDE.md — macOS 实现

给在 `mac/` 下干活的会话。**先读仓库根目录的 `CLAUDE.md`** —— 那一页是产品全貌、
模块清单与八条通用约定，是这个项目的主文档。这一页只补 macOS 特有的东西。

macOS 是**功能最全的那一版**（八个工具都在），另外两个平台目前只有截图。
跨平台共享逻辑在 `../shared/`（Rust），mac 侧是独立的 Swift 实现 ——
**共享的是规格与算法，不是代码行**，见 `../docs/multiplatform/ARCHITECTURE.md`。

## 构建

```bash
brew install xcodegen
xcodegen generate && open Baobox.xcodeproj
# 或者
xcodebuild -scheme Baobox build
```

⚠️ **本仓库的开发环境是 Linux，编译不了这部分**。改 Swift 代码务必保守：
只用项目里已出现的 API 与 Apple 稳定公开 API，不引新框架、不用 Swift Charts / Observation 宏。
改完看 `.github/workflows/build-macos.yml` 那条流水线的结果。

`xcode-select` 指向 CommandLineTools 时，命令前加
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

## 工程是生成的，别改生成物

`project.yml` 是唯一的源。`Baobox.xcodeproj`、`Sources/Info.plist`、`Baobox.entitlements`
都由 XcodeGen 生成并且**已经 gitignore** —— 改它们会被下次 `generate` 覆盖。

`sources: - Sources` 是全量 glob：**新增 `.swift` 文件自动纳入，不用改 `project.yml`**。

### 版本号只有一处

`project.yml` 里改 `MARKETING_VERSION` 就行。`CFBundleShortVersionString` 与
`CFBundleVersion` 写的是 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`，
跟着构建设置走。

> 这里曾经有过一个真实的 bug：那两个键写的是**字面量**，于是发版工作流在命令行上
> 覆盖 `MARKETING_VERSION` 根本不起作用 —— 从 `v0.0.7` 标签构建出来的包里仍写着 0.0.6。
> 别改回字面量。

## 签名与权限（这块最容易把用户的授权搞丢）

- **非沙盒 + Hardened Runtime**，bundle id `com.baobox.app`，`LSUIElement`（无 Dock 图标）。
- `project.yml` 里绑了 `DEVELOPMENT_TEAM`，**这是有意的**：ad-hoc 签名的 cdhash
  每次重新编译都会变，macOS 的 TCC 会因此判定成「另一个 App」，
  **作废已授予的屏幕录制 / 辅助功能权限**。绑定开发团队后签名身份稳定，重编不掉权限。
- 所以**自己的 Mac 一律装本地构建**（Apple Development 证书签名），
  CI 产出的 ad-hoc 包只用于分发给别人。
- CI / 发版里必须显式 `DEVELOPMENT_TEAM=""` + `CODE_SIGN_IDENTITY="-"`：
  runner 上没有那个团队的凭据，留着会让 Xcode 去解析拿不到的自动签名配置。
- **不能用 `CODE_SIGNING_ALLOWED=NO` 产出要分发的包** —— 那样出来的 `.app`
  在别人机器上一打开就被系统杀掉。
- 麦克风与 AppleScript 需要 entitlement，**光有 Info.plist 的用途描述是不够的**
  （Hardened Runtime 下），见 `project.yml` 的 `entitlements` 段。

## 目录与文件

```
Sources/App/         BaoboxApp、AppDelegate（装配所有模块）、StatusItemController
Sources/Core/        ToolModule / ToolRegistry / HotkeyCenter / Permissions /
                     Geometry / L10n / TextRecognizer / QRCodeGenerator …
Sources/Settings/    设置窗口
Sources/Modules/<名>/ 八个工具，一个目录一个
Sources/Resources/   Localizable.xcstrings
```

`Sources/Core/ToolModule.swift` 的协议与 `../shared/baobox-app` 的 `ToolModule` trait
是**同一套结构的两种语言表达**。改其中一边的形状时，看一眼另一边有没有跟着走的必要。

## 两条最容易犯的错

1. **坐标系**：macOS 是**左下角原点、y 轴向上**，而 `shared/` 与另外两个平台一律用
   左上角原点。转换集中在 `Core/Geometry.swift`，别在业务代码里就地翻 y。
2. **本地化**：每个 `L("ns.key")` / `Text("ns.key")` 都必须在
   `Sources/Resources/Localizable.xcstrings` 里有 **en + zh-Hans 两条**译文。
   沿用文件里的紧凑单行 JSON 格式。校验：

   ```bash
   python3 -c "import json;json.load(open('Sources/Resources/Localizable.xcstrings'));print('valid')"
   ```

## 无法本地编译时的自查清单

1. 只引用真实存在的类型 / 方法 —— 先 grep 确认签名，别凭印象写。
2. 每个 `L()` / `Text()` 的 key 都已入 `Localizable.xcstrings`（跑上面那条校验）。
3. 所有 `@Published` 只在主线程写。
4. `Process` / `NWConnection` / `URLSession` 不在主线程同步等待。
5. 读-改-写用户文件（`settings.json` / `.claude.json` / `config.toml`）时
   **只动自己的键、保留未知字段与注释**，写前备份同名 `.baobox.bak`。
6. 解析外部文件全程容错：字段缺失 / 类型不符只跳过或降级，**决不 crash**
   （无 force-unwrap、无 `try!`）。
