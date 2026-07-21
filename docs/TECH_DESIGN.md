# Baobox M1 技术设计文档

> 版本：v1.0（2026-07-20）
> 配套文档：`docs/REQUIREMENTS.md`（需求）、`docs/design/ui-design-v1.html`（UI 设计稿）
> 实现约定：Swift 5.9 · SwiftUI + AppKit 混合 · macOS 14+ · **零第三方依赖** · XcodeGen 生成工程

## 0. 总体架构

```
┌─ BaoboxApp (SwiftUI @main, Settings scene)
│   └─ AppDelegate (NSApplicationDelegate)
│       ├─ ToolRegistry ──── 注册 ────┐
│       ├─ StatusItemController       │  每个工具 = 一个 ToolModule
│       └─ OnboardingController       │
│                                     ▼
│   ┌───────────── ToolModule 协议 ─────────────┐
│   │  ScreenshotTool          ClipboardTool     │
│   │  ├ CaptureController     ├ ClipboardMonitor│
│   │  ├ CaptureOverlayView    ├ ClipboardStore  │
│   │  ├ WindowDetector        ├ PanelController │
│   │  └ CaptureEngine (SCK)   └ PasteService    │
│   └───────────────────────────────────────────┘
│   共享基础设施：HotkeyCenter (Carbon) · Permissions · Geometry
```

设计原则：
1. **框架不认识具体工具**。菜单栏、快捷键、设置页全部由 `ToolRegistry` 里注册的 `ToolModule` 驱动，新增工具 = 新增一个模块目录 + AppDelegate 一行注册。
2. **AppKit 做系统交互**（状态栏、Overlay 窗口、浮层面板、事件监听），**SwiftUI 做内容界面**（设置、剪贴板面板内容、引导页），通过 `NSHostingView`/`NSHostingController` 桥接。
3. 所有 UI 相关类标注 `@MainActor`。

## 1. 目录与文件清单

已存在（骨架，勿重写，可小幅补充）：

```
project.yml                          # XcodeGen 配置（macOS 14+, LSUIElement, 非沙盒）
Sources/App/BaoboxApp.swift        # 入口，Settings scene
Sources/App/AppDelegate.swift        # 注册模块 → activateAll → 状态栏 → 引导
Sources/Core/ToolModule.swift        # ToolModule 协议 + HotkeyDefinition
Sources/Core/ToolRegistry.swift      # 模块注册表
```

待实现：

```
Sources/App/StatusItemController.swift
Sources/Core/HotkeyCenter.swift
Sources/Core/KeyCombo.swift
Sources/Core/Permissions.swift
Sources/Core/Geometry.swift
Sources/Onboarding/OnboardingController.swift   # 含 SwiftUI 视图
Sources/Settings/SettingsView.swift             # TabView 容器
Sources/Settings/GeneralSettingsView.swift
Sources/Settings/HotkeySettingsView.swift       # 含 KeyRecorder (NSViewRepresentable)
Sources/Settings/AboutView.swift
Sources/Modules/Screenshot/ScreenshotTool.swift
Sources/Modules/Screenshot/CaptureController.swift
Sources/Modules/Screenshot/CaptureOverlayWindow.swift
Sources/Modules/Screenshot/CaptureOverlayView.swift
Sources/Modules/Screenshot/WindowDetector.swift
Sources/Modules/Screenshot/CaptureEngine.swift
Sources/Modules/Screenshot/ScreenshotResultHandler.swift
Sources/Modules/Screenshot/ScreenshotSettingsView.swift
Sources/Modules/Clipboard/ClipboardTool.swift
Sources/Modules/Clipboard/ClipboardItem.swift
Sources/Modules/Clipboard/ClipboardMonitor.swift
Sources/Modules/Clipboard/ClipboardStore.swift
Sources/Modules/Clipboard/ClipboardPanelController.swift
Sources/Modules/Clipboard/ClipboardPanelView.swift
Sources/Modules/Clipboard/PasteService.swift
Sources/Modules/Clipboard/ClipboardSettingsView.swift
```

## 2. 核心框架

### 2.1 HotkeyCenter（Carbon 全局快捷键）

`import Carbon.HIToolbox`，单例 `HotkeyCenter.shared`。

- `KeyCombo`（独立文件）：`struct KeyCombo: Codable, Equatable { var keyCode: UInt32; var carbonModifiers: UInt32 }`
  - `display: String`：修饰键符号（⌃⌥⇧⌘ 按此顺序）+ 键名。键名用硬编码表覆盖 ANSI 字母/数字/F 键/方向键/空格/回车等常用 kVK 常量即可，未知键显示 `key(\(keyCode))`。
  - `init?(event: NSEvent)`：从 keyDown 事件构造；NSEvent modifierFlags → Carbon 位（cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096）。至少含一个修饰键才有效（F 键除外）。
  - `keyEquivalent: (String, NSEvent.ModifierFlags)?`：供 NSMenuItem 显示。
- 注册：`RegisterEventHotKey(keyCode, carbonModifiers, EventHotKeyID(signature: "TMHK" 四字码, id: 自增 UInt32), GetApplicationEventTarget(), 0, &ref)`，返回 `noErr` 之外视为**冲突/失败**。
- 事件回调：`InstallEventHandler` 一次性安装，C 回调里 `GetEventParameter(..., typeEventHotKeyID, ...)` 取 id，转发 `HotkeyCenter.shared.handle(id:)`（C 函数指针不能捕获上下文，经单例转发；用 `DispatchQueue.main.async` 回主线程执行 action）。
- 持久化：自定义键存 UserDefaults `hotkey.<definition.id>`（JSON 编码 KeyCombo）；`effectiveCombo(for:)` = 自定义 ?? 默认。
- API：
  ```swift
  func register(_ def: HotkeyDefinition)                    // 用 effectiveCombo 注册，失败记入 conflictedIDs
  @discardableResult func update(id: String, to: KeyCombo) -> Bool  // 先注销旧的再注册新的，失败回滚并返回 false
  func resetToDefault(id: String)
  var conflictedIDs: Set<String> { get }                    // @Published，供设置页标红
  func combo(for id: String) -> KeyCombo?
  ```
  为支持 `@Published`，HotkeyCenter 声明为 `final class HotkeyCenter: ObservableObject`。

### 2.2 StatusItemController（菜单栏）

- `NSStatusBar.system.statusItem(withLength: .squareLength)`，图标 `NSImage(systemSymbolName: "wrench.and.screwdriver.fill")`（模板渲染）。
- 菜单结构严格按 UI 稿 Screen 01：
  1. 每个工具一个 `NSMenuItem`：`image` = tool.symbolName、title = tool.name、keyEquivalent 显示 primaryHotkey、**点击主行 = performDefaultAction**（NSMenu 中带 submenu 的 item 主行不可点，因此：submenu 第一项即为默认动作，主行仅悬停展开；这与系统菜单行为一致，可接受）。
  2. submenu = `tool.submenuItems()` + 分隔线 + "〈工具名〉设置…"（打开设置窗口并 `selectTab(tool.id)`）。
  3. 工具列表之后：分隔线 + "设置…"(⌘,) + "检查更新…"(占位 disabled，M2 接 Sparkle) + "退出"(⌘Q)。
- 实现 `NSMenuDelegate.menuNeedsUpdate` 每次重建菜单，保证快捷键改动即时反映。
- 打开设置窗口：`NSApp.activate(ignoringOtherApps: true)` 后 `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`；选中目标 Tab 通过 `SettingsTabSelection.shared`（`ObservableObject`，`@Published var selectedTab: String`）。

### 2.3 Permissions

```swift
enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { CGRequestScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static func promptAccessibility()   // AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])
    static func openSystemSettings(pane: Pane)  // x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture / Privacy_Accessibility
}
```

### 2.4 OnboardingController + 引导视图

- 单例。`showIfNeeded()`：任一权限缺失时弹出（每次启动最多一次）；两项都有则不弹。
- `NSWindow`（titled/closable，居中，`level: .floating`）承载 SwiftUI `OnboardingView`，按 UI 稿 Screen 06：App 徽标、两行权限（图标/名称/说明/状态徽章）、主按钮"打开系统设置"、底部"稍后在设置中补齐"。
- 状态徽章用 1s `Timer` 轮询刷新（授权后实时变绿，无需重启）。"辅助功能"行未授权时点击 = `promptAccessibility()` + 打开对应设置页。

### 2.5 Geometry（坐标转换）

CoreGraphics 全局坐标（CGWindowList、CGEvent）**原点在主屏左上角，y 向下**；AppKit（NSScreen/NSWindow/NSView 非翻转）**原点在主屏左下角，y 向上**。统一提供：

```swift
enum Geometry {
    static var primaryScreenHeight: CGFloat   // NSScreen.screens[0].frame.height（注意不是 main）
    static func cgRect(fromAppKit r: NSRect) -> CGRect   // y' = H - r.maxY
    static func appKitRect(fromCG r: CGRect) -> NSRect   // 逆变换
    static func cgPoint(fromAppKit p: NSPoint) -> CGPoint
}
```

所有跨界传参**注明坐标系**（变量名后缀 `CG` / `AK`）。

## 3. 截图模块

### 3.1 ScreenshotTool（模块壳）

- `id: "screenshot"`, name "截图", symbol `"viewfinder"`。
- hotkeys：一条 `screenshot.capture`，默认 `⌘⇧2`（kVK_ANSI_2=0x13，cmd|shift），subtitle "单击截窗口 · 拖拽选区域 · ⏎ 全屏"，action = `captureController.begin()`。
- submenuItems：开始截图（默认动作）/ 截图历史(disabled, "M2") / 贴图管理(disabled, "M2")。
- performDefaultAction = begin()。

### 3.2 CaptureController（会话协调）

- `begin()`：若已激活则忽略；无屏幕录制权限 → `requestScreenRecording()` + 弹引导，返回。
- 为**每个 NSScreen** 创建一个 `CaptureOverlayWindow`（borderless、`level = .screenSaver`、`backgroundColor = .clear`、`isOpaque = false`、`ignoresMouseEvents = false`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`、`canBecomeKey = true`），frame = screen.frame，内容为 `CaptureOverlayView`。鼠标所在屏的窗口 `makeKeyAndOrderFront`。
- 回调（由 overlay 调用）：
  - `finishWindow(_ win: DetectedWindow)`
  - `finishRect(_ rectAK: NSRect, on screen: NSScreen)`
  - `finishFullScreen(on screen: NSScreen)`
  - `cancel()`
- finish 流程：先 `dismissOverlays()`，`Task { try? await Task.sleep(0.08s)`（等 overlay 消隐）→ `CaptureEngine.capture(target)` → `ScreenshotResultHandler.handle(image)` }，错误走 `NSAlert`（简单提示即可）。

### 3.3 CaptureOverlayView（核心交互，NSView）

状态机：

```swift
enum Phase {
    case hovering(DetectedWindow?)          // 初始：跟随鼠标高亮窗口
    case dragging(anchorAK: NSPoint, currentAK: NSPoint)
    case adjusting(rectAK: NSRect)          // 拖拽结束后可微调
}
```

- **hovering**：`mouseMoved`（overlay window `acceptsMouseMovedEvents = true`）→ `WindowDetector.window(atCG:)` → `needsDisplay`。绘制：全屏 45% 黑色蒙层，命中窗口区域**挖洞**（`CGContext` `setBlendMode(.clear)` 填充窗口 rect），洞边缘 3pt 描边（`NSColor.controlAccentColor` 或品牌色 #2BC4B8）+ 淡填充，窗口下方绘制信息徽章 "App 名 · 标题 — W × H"（等宽字体，深底白字圆角 6）。
- hovering 中 `mouseDown` 记录 anchor；`mouseDragged` 位移 > 4pt → 进入 dragging；`mouseUp` 未超阈值 → **单击**：有命中窗口则 `finishWindow`，否则忽略。
- **dragging**：蒙层 + 选区挖洞 + 1.5pt 白描边 + 右下角尺寸徽章 "W × H"（点单位）。`mouseUp` → adjusting。
- **adjusting**：绘制同 dragging + 8 个 6×6pt 白色方形手柄（四角四边中点）。交互：
  - 手柄命中（±6pt）拖动 → 对应方向 resize；选区内部拖动 → 平移；选区外 mouseDown → 重新开始 dragging。
  - 方向键移动 1pt，⇧+方向键 10pt（clamp 在本屏内）。
- **键盘**（overlay window keyDown）：`Esc` → cancel；`⏎`：adjusting 时 = `finishRect`，hovering 时 = `finishFullScreen`；`⌥⏎` adjusting = finishRect 但标记"仅保存"（通过 controller 传 `ResultMode`）。`⌘⏎` M2 进标注，现阶段行为同 `⏎`。
- **底部提示条**：作为子视图绘制（或直接在 draw 里画圆角胶囊 + attributed string），内容随 Phase 切换，文案与 UI 稿一致。
- 光标：hovering 用 `NSCursor.crosshair`。
- 多屏：每个 overlay 独立处理本屏事件；controller 收到任一屏的 finish/cancel 后关闭全部。
- 放大镜（loupe）**M1 不做**，留 TODO 注释。

### 3.4 WindowDetector

```swift
struct DetectedWindow { let windowID: CGWindowID; let frameCG: CGRect; let appName: String; let title: String?; let ownerPID: pid_t }
static func window(atCG point: CGPoint) -> DetectedWindow?
```

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` 返回**前到后**排序；遍历取第一个满足：`kCGWindowLayer == 0`、`ownerPID != getpid()`、`alpha > 0`、bounds 含 point、宽高 ≥ 40pt（滤掉小控件窗）。bounds 从 `kCGWindowBounds` 字典经 `CGRect(dictionaryRepresentation:)` 解析。

### 3.5 CaptureEngine（ScreenCaptureKit）

```swift
enum CaptureTarget {
    case window(CGWindowID)
    case display(CGDirectDisplayID)                 // 全屏
    case displayRect(CGDirectDisplayID, rectAK: NSRect, screen: NSScreen)  // 区域
}
static func capture(_ target: CaptureTarget) async throws -> CGImage
```

- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` 取内容；窗口 → 匹配 `SCWindow.windowID`，filter = `SCContentFilter(desktopIndependentWindow:)`；显示器 → 匹配 `SCDisplay.displayID`，filter = `SCContentFilter(display:excludingWindows: [])`。
- `SCStreamConfiguration`：`width/height = Int(filter.contentRect.size * filter.pointPixelScale)`、`showsCursor = false`、`captureResolution = .best`。
- `SCScreenshotManager.captureImage(contentFilter:configuration:)`（macOS 14 API）。
- 区域：先截全屏，再 `cgImage.cropping(to: pixelRect)`。pixelRect 换算：`scale = screen.backingScaleFactor`；`x = (rectAK.minX - screen.frame.minX) * scale`；`y = (screen.frame.maxY - rectAK.maxY) * scale`（图像原点左上）。
- NSScreen → displayID：`screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID`。

### 3.6 ScreenshotResultHandler + 设置

- `handle(image: CGImage, mode: ResultMode)`；`enum ResultMode { case standard; case saveOnly }`。
- standard：**总是**写剪贴板（`NSPasteboard` 清空后 `setData(png, forType: .png)` + `NSImage` tiff）；若设置"自动保存"开 → 同时存文件。saveOnly：只存文件。
- PNG 编码：`NSBitmapImageRep(cgImage:).representation(using: .png, properties: [:])`。
- 设置（UserDefaults 键统一 `screenshot.` 前缀，用 `@AppStorage`）：
  - `screenshot.autoSave` Bool = true
  - `screenshot.saveDirectory` String = `~/Pictures/Baobox`（首次保存时 `createDirectory`）
  - `screenshot.filenameTemplate` String = `"截图 yyyy-MM-dd HH.mm.ss"`（经 DateFormatter，追加 `.png`）
- `ScreenshotSettingsView`：Form——自动保存开关、目录选择（NSOpenPanel，`canChooseDirectories`）、文件名模板输入框 + 实时示例。

## 4. 剪贴板模块

### 4.1 数据模型与存储

```swift
enum ClipboardItemType: String, Codable { case text, link, image, file }
struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    let type: ClipboardItemType
    var text: String?            // text/link：内容；file：路径（多文件 \n 分隔）
    var imageFilename: String?   // image：Application Support 下的相对文件名
    let sourceAppName: String?
    let sourceBundleID: String?
    let createdAt: Date
    var isPinned: Bool
}
```

- `ClipboardStore: ObservableObject`：`@Published private(set) var items: [ClipboardItem]`（新→旧，pinned 排最前）。
- 目录：`~/Library/Application Support/Baobox/`，`clipboard.json` + `ClipboardImages/<uuid>.png`。
- `add(_:)`：与最近一条内容相同则仅刷新时间戳；超出上限（`clipboard.maxItems`，默认 200）从**未置顶**尾部淘汰并删除关联图片文件；节流写盘（0.5s debounce，`DispatchWorkItem`）。
- `togglePin` / `delete` / `clearAll`；启动时从磁盘加载。

### 4.2 ClipboardMonitor

- 0.3s `Timer`（`.common` runloop mode）轮询 `NSPasteboard.general.changeCount`。
- 跳过条件：changeCount 未变；`ignoreNextChange` 标志（PasteService 回填时置位，消费一次后复位）；pasteboard types 含 `org.nspasteboard.ConcealedType` 或 `org.nspasteboard.TransientType`。
- 读取优先级：`fileURLs`（`readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`）→ file；`NSImage` 可读 → image（PNG 落盘）；string → 以 `URL(string:)` 且 scheme http(s) 判定 link，否则 text。
- 来源 App：`NSWorkspace.shared.frontmostApplication`（读取时刻的前台 App 即复制来源，足够准确）。

### 4.3 面板（ClipboardPanelController + ClipboardPanelView）

- `NSPanel`，styleMask `[.borderless, .nonactivatingPanel]`，子类覆写 `canBecomeKey = true`；`level = .floating`、`isMovableByWindowBackground = true`、`hidesOnDeactivate = false`、圆角由 SwiftUI 内容自绘（背景 `.ultraThinMaterial` + `clipShape(RoundedRectangle(cornerRadius: 14))`，窗口透明）。尺寸 660×420，唤出时居中于鼠标所在屏，`makeKeyAndOrderFront`。**非激活面板**保证前台 App 不失活，回填无需切换。
- 再按一次 `⌘⇧V` 或 `Esc` 或点击面板外（`NSEvent.addGlobalMonitorForEvents` 监听 leftMouseDown）→ 关闭。
- `ClipboardPanelViewModel: ObservableObject`：`query`、`typeFilter: ClipboardItemType?`、`selectedIndex`、`filtered: [ClipboardItem]`（搜索匹配 text/文件名，大小写不敏感）。
- 布局按 UI 稿 Screen 04：顶部搜索框（唤出即聚焦，`@FocusState`）+ 类型过滤 chips；左列表（280pt，图标/单行内容/来源+相对时间/置顶星标）右预览（text 全文等宽、image `Image(nsImage:)`、file 路径列表；底部元信息：来源、字符数、时间）；底部快捷键提示条。
- 键盘：controller 安装 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`——`↑/↓` 移动选中（滚动跟随 `ScrollViewReader`）、`⏎` 粘贴、`⌥⏎` 纯文本粘贴、`⌘P` 置顶、`Esc` 关闭；其余事件返回原值给搜索框。面板关闭时移除 monitor。
- 相对时间：`RelativeDateTimeFormatter`（zh_CN）。

### 4.4 PasteService

```swift
static func paste(_ item: ClipboardItem, plainText: Bool, store: ClipboardStore, monitor: ClipboardMonitor)
```

1. `monitor.ignoreNextChange = true`；按类型写回 `NSPasteboard.general`（plainText 时仅写 string）。
2. 关闭面板。
3. `AXIsProcessTrusted()` 为 true → 延迟 0.12s 后 CGEvent 合成 ⌘V：`CGEventSource(stateID: .combinedSessionState)`，keyDown/keyUp `kVK_ANSI_V`，`flags = .maskCommand`，`post(tap: .cghidEventTap)`。false → 仅复制，并首次弹 `promptAccessibility()`。

### 4.5 ClipboardTool（模块壳）

- `id: "clipboard"`, name "剪贴板", symbol `"doc.on.clipboard"`。
- hotkeys：`clipboard.togglePanel` 默认 `⌘⇧V`（kVK_ANSI_V=9）；`clipboard.pastePlainLast` 默认 `⌘⌥V`（subtitle "纯文本粘贴上一条"）。
- submenu：打开剪贴板历史（默认动作）/ 清空历史（confirm NSAlert）。
- `ClipboardSettingsView`：历史上限（Stepper 50–1000）、"忽略密码管理器标记的内容"（只读说明，恒开）、清空按钮。

## 5. 设置窗口

- `SettingsView(registry:)`：`TabView` 样式的 mac 设置窗（系统默认 toolbar style）。Tab 顺序：**通用 / 快捷键 /（每个工具一个 Tab，遍历 registry）/ 关于**，`tag = id`，绑定 `SettingsTabSelection.shared.selectedTab`。
- **通用**：开机自启（`SMAppService.mainApp.register()/unregister()`，Toggle 反映 `.status`）；权限两行（状态徽章 + "前往开启"按钮，复用 Permissions）。
- **快捷键**：遍历 `registry.allHotkeys()` 按工具分组（GroupBox），每行 title/subtitle + 右侧 `KeyRecorder`；`HotkeyCenter.conflictedIDs` 含该 id 时行下方红色小字"快捷键被占用，请更换"；右键或小按钮"恢复默认"。
- **KeyRecorder**（`NSViewRepresentable` 包 `RecorderView: NSView`）：常态画当前 `combo.display` 圆角键帽；点击 → `window.makeFirstResponder(self)` 进入录制态（品牌色描边 + "按下新快捷键…"）；`keyDown` → `KeyCombo(event:)` 有效则回调 `onChange`（内部调 `HotkeyCenter.update`），`Esc` 取消录制；`resignFirstResponder` 退出录制态。
- **关于**：版本号（Bundle 读取）、"检查更新"占位按钮（disabled，注 "M2 接入 Sparkle"）。

## 6. 构建与验收（需在 Mac 上执行）

```bash
brew install xcodegen
xcodegen generate
open Baobox.xcodeproj    # 或 xcodebuild -scheme Baobox build
```

验收清单（M1 DoD）：
1. 启动后菜单栏出现图标，菜单结构与 UI 稿 Screen 01 一致；无 Dock 图标。
2. 首启弹权限引导；授权"屏幕录制"后徽章实时变绿。
3. `⌘⇧2`：悬停高亮窗口 + 信息徽章；单击截窗口；拖拽出选区可手柄微调、方向键移动；⏎ 全屏；Esc 取消；结果进剪贴板且按设置落盘。
4. 复制文本/链接/图片/文件后 `⌘⇧V` 面板中可见，带来源与时间；搜索、类型过滤、↑↓⏎ 回填粘贴（已授权辅助功能）生效；密码管理器内容不入库。
5. 设置页：改快捷键立即生效并持久化；冲突标红；重启后历史与设置保留。
6. 内存目标：常驻 < 50MB。

## 7-A. M2 增量模块：取色器与防休眠

两个模块均为标准 `ToolModule`，在 AppDelegate 中于 ClipboardTool 之后注册（菜单顺序：截图、剪贴板、取色器、防休眠）。

### 7-A.1 取色器（ColorPicker）

```
Sources/Modules/ColorPicker/ColorPickerTool.swift        # 模块壳
Sources/Modules/ColorPicker/ColorHistoryStore.swift      # 历史 + 格式化
Sources/Modules/ColorPicker/ColorPickerSettingsView.swift
```

- `id: "colorpicker"`, name "取色器", symbol `"eyedropper"`。
- hotkeys：一条 `colorpicker.pick`，默认 `⌘⇧C`（kVK_ANSI_C=8），action = 开始取色。
- **取色**：`NSColorSampler().show { color in ... }`——系统原生放大镜取色 UI，**无需任何权限**。回调 `NSColor?`（nil = 用户取消）；转 sRGB（`usingColorSpace(.sRGB)`）后：
  1. 按设置格式生成字符串并写入剪贴板（"取色后自动复制"开关，默认开）；
  2. 存入历史。
- **ColorFormat**（enum，Codable，存 UserDefaults `colorpicker.format`）：
  - `.hex` → `#1AB3A6`（大写可选，`colorpicker.hexUppercase`，默认开）
  - `.rgb` → `rgb(26, 179, 166)`
  - `.swiftui` → `Color(red: 0.102, green: 0.702, blue: 0.651)`（三位小数）
- **ColorHistoryStore: ObservableObject**：`[ColorEntry]`（`id: UUID, hex: String, createdAt: Date`，统一存 sRGB hex），上限 50 条新→旧，JSON 持久化到 `Application Support/Baobox/colors.json`（复用 ClipboardStore 的目录约定与 debounce 写盘模式）。
- **submenu**：取色（默认动作）/ 分隔线 / 最近 5 个颜色（`NSMenuItem` image = 16×16 圆角色块 NSImage 现场绘制，title = 按当前格式的字符串，点击 = 复制该色）/ 分隔线 / 清空历史。
- **设置页**：格式 Picker（三选一，附实时示例文本）、Hex 大写 Toggle（仅 hex 时启用）、取色后自动复制 Toggle。

### 7-A.2 防休眠（Caffeinate）

```
Sources/Modules/Caffeinate/CaffeinateTool.swift          # 模块壳
Sources/Modules/Caffeinate/CaffeinateController.swift    # IOPMAssertion 管理
Sources/Modules/Caffeinate/CaffeinateSettingsView.swift
```

- `id: "caffeinate"`, name "防休眠", symbol `"cup.and.saucer"`。
- hotkeys：**空数组**（纯菜单操作，避免占用组合键；后续有需求再加）。⚠️ 这是第一个无快捷键的模块，快捷键设置页遍历时需跳过空分组（GroupBox 不渲染）。
- **CaffeinateController: ObservableObject**（`import IOKit.pwr_mgt`）：
  ```swift
  @Published private(set) var isActive: Bool
  @Published private(set) var until: Date?          // nil = 无限期
  func start(duration: TimeInterval?)               // nil = 无限期
  func stop()
  ```
  - `start`：先 `stop()` 清旧断言，再 `IOPMAssertionCreateWithName(type, kIOPMAssertionLevelOn, "Baobox 防休眠" as CFString, &assertionID)`；type 按设置：`kIOPMAssertionTypePreventUserIdleSystemSleep`（默认）或 `kIOPMAssertionTypePreventUserIdleDisplaySleep`（"同时防显示器休眠"开时）。返回值非 `kIOReturnSuccess` 时 NSAlert 提示。
  - 定时：`duration` 非 nil 时挂一个 `Timer` 到期自动 `stop()`；`until = Date() + duration`。
  - `stop`：`IOPMAssertionRelease` + 置空 + 取消 Timer。App 退出时（`applicationWillTerminate`）确保释放。
- **performDefaultAction** = toggle：未激活 → `start(duration: 默认时长设置)`；激活 → `stop()`。
- **submenu**（`menuNeedsUpdate` 每次重建以刷新剩余时间）：
  - 状态行（disabled）：未激活 "未开启"；激活无限期 "已开启 · 无限期"；激活定时 "已开启 · 剩余 mm 分钟"
  - 分隔线 / 开启 15 分钟 / 开启 1 小时 / 开启 2 小时 / 无限期开启（当前生效项打 `state = .on` 勾）/ 分隔线 / 关闭（未激活时 disabled）
- **设置页**：默认时长 Picker（15 分钟/1 小时/2 小时/无限期，存 `caffeinate.defaultDuration`，秒数 Double，-1 表无限期）、"同时防止显示器休眠" Toggle（存 `caffeinate.preventDisplaySleep`，默认关；变更时若正在生效则重建断言）。
- 菜单栏主图标不随状态变化（全局图标属框架），状态通过二级菜单状态行表达。

## 7-B. M2 增量模块：窗口管理（多显示器兼容）

标准 `ToolModule`，在 AppDelegate 中于 CaffeinateTool 之后注册。依赖**辅助功能**权限（与剪贴板回填共用，无新授权）。

```
Sources/Modules/WindowManager/WindowManagerTool.swift         # 模块壳 + 快捷键定义
Sources/Modules/WindowManager/WindowLayout.swift              # 布局枚举 + 纯函数几何计算
Sources/Modules/WindowManager/AXWindow.swift                  # AX 前台窗口读写封装
Sources/Modules/WindowManager/WindowManagerSettingsView.swift
```

- `id: "windowmanager"`, name "窗口管理", symbol `"macwindow.on.rectangle"`。

### 7-B.1 布局动作与默认快捷键（对齐 Rectangle 惯例）

| 动作 | hotkey id | 默认键 |
|---|---|---|
| 左半屏 | windowmanager.left | ⌃⌥← |
| 右半屏 | windowmanager.right | ⌃⌥→ |
| 上半屏 | windowmanager.top | ⌃⌥↑ |
| 下半屏 | windowmanager.bottom | ⌃⌥↓ |
| 左上¼ | windowmanager.topLeft | ⌃⌥U |
| 右上¼ | windowmanager.topRight | ⌃⌥I |
| 左下¼ | windowmanager.bottomLeft | ⌃⌥J |
| 右下¼ | windowmanager.bottomRight | ⌃⌥K |
| 最大化（非全屏） | windowmanager.maximize | ⌃⌥⏎ |
| 居中（不改尺寸） | windowmanager.center | ⌃⌥C |
| 移到下一个显示器 | windowmanager.nextDisplay | ⌃⌥⌘→ |
| 移到上一个显示器 | windowmanager.prevDisplay | ⌃⌥⌘← |
| 恢复原始位置 | windowmanager.restore | ⌃⌥⌫ |

方向键 kVK：←0x7B →0x7C ↓0x7D ↑0x7E；⏎ kVK_Return=0x24；⌫ kVK_Delete=0x33。submenu 列全部动作（ClosureMenuItem），未授权辅助功能时首项显示"需要辅助功能权限（点击开启）"。

### 7-B.2 AXWindow（AX 封装）

```swift
@MainActor enum AXWindow {
    static func focusedWindow() -> AXUIElement?     // frontmostApplication → AXUIElementCreateApplication(pid) → kAXFocusedWindowAttribute
    static func frameCG(of: AXUIElement) -> CGRect? // kAXPositionAttribute/kAXSizeAttribute，AXValueGetValue(.cgPoint/.cgSize)
    static func setFrameCG(_ rect: CGRect, on: AXUIElement)
}
```

- **AX 坐标 = CG 全局坐标（主屏左上原点，y 向下）**，与 NSScreen 的换算必须走 `Geometry`，这是本模块最大风险点。
- `setFrameCG` 顺序：**先 size → 再 position → 再 size**（部分 App 会按旧位置约束尺寸，两遍 size 是平台通行做法）。设置失败（AXError ≠ .success）静默忽略（固定尺寸窗口尽力而为）。
- 前置检查：`AXIsProcessTrusted()` 为 false → `Permissions.promptAccessibility()` + 打开系统设置，动作直接返回。

### 7-B.3 WindowLayout（几何计算，多屏核心）

```swift
enum WindowLayout { case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight,
                    maximize, center, nextDisplay, prevDisplay, restore }
```

- **目标屏判定**：取窗口 frame（转 AK 坐标）与各 `NSScreen.frame` 交集面积最大者；零交集（窗口游离）时用鼠标所在屏。基准区域一律用 `screen.visibleFrame`（**自动避开菜单栏与 Dock**，且每屏各自不同——这就是多屏正确性的关键）。
- 半屏/四分屏/最大化：对 visibleFrame 做几何切分，四周内缩 `windowmanager.gap`（设置项，默认 0pt，切分线两侧各留 gap/2）。纯函数实现：`static func targetFrameAK(for layout:, window frameAK:, on screen: NSScreen, gap: CGFloat) -> NSRect`，便于单元测试。
- **跨屏移动**：屏幕列表按 `frame.origin.x`（再按 y）排序保证顺序稳定，next/prev 循环取目标屏；窗口在源屏 visibleFrame 内的**相对位置与相对尺寸等比映射**到目标屏 visibleFrame（不同分辨率/缩放比的屏之间不变形溢出），映射后 clamp 确保完全落在目标屏内。单屏时动作无效果（不报错）。
- **恢复**：单槽记录——任何布局动作生效前，若当前记录的窗口（`CFEqual` 比较 AXUIElement）不是本窗口，则记下 `(AXUIElement 强引用, 原 frameCG)`；`restore` 写回并清槽。窗口已关闭时 set 失败静默清槽。
- center：仅平移到目标屏 visibleFrame 中心，不改尺寸。

### 7-B.4 设置页

- 窗口间距 gap：Stepper 0–20pt（存 `windowmanager.gap`，Double）。
- 辅助功能权限状态行（复用 Onboarding 的徽章样式：已授权绿 / 前往开启按钮）。
- 说明文字：全部快捷键可在"快捷键"Tab 中修改。

### 7-B.5 注意

- 本模块 13 条快捷键——HotkeySettingsView 的分组渲染量最大，确认滚动可用即可。
- ⌃⌥ 组合与输入法/个别 App 可能冲突，冲突红字提示已由 HotkeyCenter 覆盖，无需特殊处理。
- 不做窗口拖拽吸附（screen-edge snapping）、不做自定义比例布局——M3 再评估。

## 7. 风险与注意

- **Carbon 回调不能捕获 Swift 上下文**——必须经单例转发。
- **overlay 不能挡住自己**：WindowDetector 过滤 `getpid()`；截图前先关 overlay 再延迟捕获。
- **NSPanel borderless 默认不能成为 key window**——必须子类覆写。
- **坐标系翻转**是最易错点，一律走 `Geometry`，禁止就地换算。
- 非沙盒 + Hardened Runtime，无需 entitlements 文件；屏幕录制/辅助功能授权面向 bundle id `com.toolsmac.app`，改 id 会导致重新授权。
