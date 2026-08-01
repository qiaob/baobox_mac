# 剪贴板文本工具 — 技术方案

> 版本：v1.0（2026-08-01）
> 对应需求：同目录 `REQUIREMENTS.md`。归属 Clipboard 模块（`id: "clipboard"`），**不新增 ToolModule**。
> 实现约定：Swift 5.9 · macOS 14+ · SwiftUI + AppKit 混合 · 零第三方依赖 · UI/状态 `@MainActor` · 文案 `clipboard.tools.*` 双语入 `Localizable.xcstrings`。

## 0. 硬约束（实现者必读）

- **无法本地编译**（Linux 开发环境，CI 只在 main 构建）。只用项目已出现或 Apple 稳定公开 API：`Foundation`（`JSONSerialization`、`ISO8601DateFormatter`、`DateFormatter`、`URLComponents`、`Data(base64Encoded:)`）、`XMLDocument`（macOS 独有，Foundation 自带）、`CoreImage`（`QRCodeGenerator` 已封装）、`Carbon.HIToolbox`（keyCode 常量）。**不引入新框架**。
- 识别与转换全部在**主线程同步**执行，因此必须有严格的长度上限（§3.2），否则长按 ↑↓ 会掉帧。
- 所有解析**只降级不 crash**：无 force-unwrap、无 `try!`、外部文本任何形态都不得抛出未捕获错误。
- 转换结果**只进内存**。绝不写回 `ClipboardItem`、绝不落盘、写剪贴板时必须抑制监听。
- `project.yml` 用 `sources: - Sources` 全量 glob，新增子目录/文件**无需改 project.yml**。

## 1. 文件划分

新增（`Sources/Modules/Clipboard/TextTools/`）：

| 文件 | 职责 | 规模 |
|---|---|---|
| `TextFormatRecognizer.swift` | 协议、`FormatMatch` / `FormatAction` / `FormatRow`、识别器注册表与调度 | ~140 |
| `TimestampRecognizer.swift` | 时间识别与转换表 | ~230 |
| `JSONRecognizer.swift` | JSON 检测 + **保序扫描器**（格式化/压缩）+ 转义/去转义 | ~270 |
| `XMLRecognizer.swift` | XML 检测与格式化（禁 XXE） | ~90 |
| `URLRecognizer.swift` | URL 检测、编解码、query 表 | ~120 |
| `Base64Recognizer.swift` | Base64 检测（严格门槛）与编解码 | ~110 |
| `JWTRecognizer.swift` | JWT 检测与分段渲染（组合 Base64 + JSON + 时间） | ~140 |
| `CommonActions.swift` | 通用动作（本期：二维码） | ~90 |

移动：`Sources/Modules/QRCode/QRCodePanel.swift` 里的 `QRCodeGenerator` → **`Sources/Core/QRCodeGenerator.swift`**（原样搬，不改实现）。

删除：`Sources/Modules/QRCode/` 整个目录、`AppDelegate.swift:14` 的注册行。

改动：

| 文件 | 改动 | 增量 |
|---|---|---|
| `ClipboardPanelView.swift` | 徽章行、表格区、动作栏、最大化布局 | ~+200 |
| `ClipboardPanelViewModel` | 识别结果、预览缓冲、最大化状态 | ~+70 |
| `ClipboardPanelController.swift` | Tab / ⌘1–9 / ⌘0 / ⌘C / Esc 渐进撤销 | ~+50 |
| `PasteService.swift` | `overrideText` 参数 | ~+12 |
| `ClipboardTool.swift` | `clipboard.qrcodeLast` 快捷键 | ~+15 |

## 2. 核心抽象（`TextFormatRecognizer.swift`）

```swift
/// 表格里的一行（时间转换表、URL query、JWT 声明）。
struct FormatRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    /// nil = 该行不给复制按钮（如「3 小时前」）。
    let copyValue: String?
    /// 需要标红的行（如已过期的 exp）。
    var isWarning: Bool = false
}

enum FormatActionKind {
    /// 文本 → 文本。结果进预览缓冲，⏎ 粘贴的就是它。返回 nil = 本次转换不适用（按钮不该被点到，兜底静默）。
    case transform((String) -> String?)
    /// 输出不是文本，自己收尾（二维码钉屏、浏览器打开…）。
    case terminal((String) -> Void)
}

struct FormatAction: Identifiable {
    let id: String              // "json.pretty"
    let title: String           // 已本地化
    let kind: FormatActionKind
    /// false = 按钮置灰（超长度上限、超二维码容量…）。
    let isEnabled: Bool
    /// 置灰原因，作为 tooltip。
    let disabledHint: String?
}

struct FormatMatch: Identifiable {
    let id: String              // 识别器 id
    let badge: String           // 徽章文案，已本地化，可带参："Unix 时间戳(ms)"
    /// 覆盖预览正文的渲染结果；nil = 显示条目原文。
    let rendered: String?
    /// 表格区内容；空数组 = 不显示表格。
    let rows: [FormatRow]
    let actions: [FormatAction]
}

protocol TextFormatRecognizer {
    /// 与 FormatMatch.id 一致，也是本地化命名空间后缀。
    var id: String { get }
    /// 数值越小越靠前。JWT 10 / JSON 20 / XML 30 / 时间 40 / URL 50 / Base64 90。
    var priority: Int { get }
    /// 认不出返回 nil。必须是纯函数，不得有副作用。
    func detect(_ text: String) -> FormatMatch?
}
```

注册表与框架其余部分同构（顺序即优先级）：

```swift
@MainActor
enum TextFormatRegistry {
    static let recognizers: [TextFormatRecognizer] = [
        JWTRecognizer(), JSONRecognizer(), XMLRecognizer(),
        TimestampRecognizer(), URLRecognizer(), Base64Recognizer()
    ]

    /// 对一条文本跑全部识别器，按 priority 排序返回。
    static func detectAll(_ text: String) -> [FormatMatch]

    /// 对任何文本都出现的动作（当前只有二维码）。
    static func commonActions(for text: String) -> [FormatAction]
}
```

**新增一个格式 = 新增一个文件 + 在 `recognizers` 里加一行**，`ClipboardPanelView` 不需要认识任何具体格式。

## 3. 检测调度

### 3.1 时机

只对**当前选中的那一条**跑，在 `ClipboardPanelViewModel.selectedIndex` 的 `didSet` 里触发（列表点击也走这个属性，所以 `didSet` 比在 `moveSelection` 里手动清更保险）：

```swift
@Published var selectedIndex = 0 { didSet { refreshDetection() } }
@Published private(set) var matches: [FormatMatch] = []
@Published var activeMatchIndex = 0
@Published var transformed: (actionTitle: String, text: String)?
```

`refreshDetection()`：清空 `transformed`、重置 `activeMatchIndex = 0`、对 `selectedItem` 的文本重跑 `detectAll`。图片/文件类型条目不跑（`item.type == .image` 直接返回空）。

**绝不**在 `ClipboardMonitor` 入库时跑：那是 0.3s 轮询的热路径，而且结果一旦存进 `ClipboardItem` 就得跟着格式变更做迁移。

### 3.1.1 开关（`TextToolSettings`）

```swift
enum TextToolSettings {           // 纯 UserDefaults 读写，非 @MainActor，设置页与注册表共用
    static let masterKey = "clipboard.textTools.enabled"
    static func key(for id: String) -> String { "clipboard.textTools.\(id)" }
    static var descriptors: [Descriptor]      // 设置页行顺序 = 面板徽章优先级顺序
    static var isMasterEnabled: Bool          // object(forKey:) as? Bool ?? true
    static func isEnabled(_ id: String) -> Bool
}
```

`detectAll` 里 **filter 在 detect 之前** —— 关掉的识别器一次 `detect` 都不跑，这是这组开关存在的唯一意义（识别走主线程同步）。二维码不是识别器但共用同一套键（`qrCodeID = "qrcode"`），由 `commonActions(for:)` 判断。

设置页用 `@AppStorage(masterKey)` 管总开关；逐格式那组数量不固定又要 `ForEach`，没法一格式一个 `@AppStorage`，改用 `@State var toolStates: [String: Bool]` 镜像 + 自定义 `Binding` 写回 UserDefaults。

### 3.2 长度上限（常量，不做配置项）

| 常量 | 值 | 行为 |
|---|---|---|
| `maxDetectLength` | 256 KB | 超过：`matches` 直接为空，只显示原文（通用动作仍在） |
| `maxTransformLength` | 2 MB | 超过：格式化/压缩类动作 `isEnabled = false` + tooltip |
| `QRCodeGenerator.maxBytes` | 2900 | 超过：二维码动作置灰 |

### 3.3 多命中与优先级

`detectAll` 返回按 `priority` 升序的数组，徽章行按序渲染 chip，`activeMatchIndex` 默认 0。切换 chip 时清空 `transformed`（不同格式的转换结果不该串）。

优先级依据「误报率」而非「重要性」：JWT 的门槛（三段 + header 含 `alg`）几乎不可能误报所以排第一；Base64 的字符集太宽松所以排最后。

## 4. 各识别器实现要点

### 4.1 时间（`TimestampRecognizer.swift`）

`DateFormatter` / `ISO8601DateFormatter` 构造开销大，**必须 `static let` 缓存**，不要在 `detect` 里 new。固定 `locale = Locale(identifier: "en_US_POSIX")`，避免用户区域设置影响解析。

纯数字分支：

```swift
// 合理区间：1970-01-01 ~ 2100-01-01
private static let minEpoch: Double = 0
private static let maxEpoch: Double = 4_102_444_800
```

| 位数 | 解释为 | 换算 |
|---|---|---|
| 9–10 | Unix 秒 | `Date(timeIntervalSince1970:)` |
| 9–10 | **同时**给 Apple 绝对时间 | `Date(timeIntervalSinceReferenceDate:)`（2001-01-01 起算） |
| 13 | 毫秒 | `/ 1_000` |
| 16 | 微秒 | `/ 1_000_000` |
| 19 | 纳秒 | `/ 1_000_000_000` |

9–10 位的歧义**不猜**，表里出两组行，label 分别标注 `Unix 秒` 和 `Apple 绝对时间`。

文本分支按序尝试：`ISO8601DateFormatter`（`[.withInternetDateTime]` 与 `[.withInternetDateTime, .withFractionalSeconds]` 各试一次）→ `yyyy-MM-dd HH:mm:ss` → `yyyy/MM/dd HH:mm:ss` → `yyyy-MM-dd` → RFC 2822（`EEE, dd MMM yyyy HH:mm:ss zzz`）。

输出行见需求 §5.1。相对时间复用面板已有的 `RelativeDateTimeFormatter` + `L10n.locale`。

### 4.2 JSON（`JSONRecognizer.swift`）—— 本方案的技术核心

**为什么不用 `JSONSerialization` 往返格式化**（`.prettyPrinted`）：

1. **key 顺序丢失** —— 解析成 `NSDictionary` 即无序，输出顺序与原文无关。`.sortedKeys` 只是换成字典序，仍不是原始顺序。用户拿格式化结果去和同事的 JSON 对比会非常难受。
2. **数字精度静默损坏** —— 19 位雪花 ID、高精度小数会过一遍 `Double`，`1234567890123456789` 变成 `1234567890123456800`。这是**静默的数据错误**，比不支持这个功能更糟。
3. 大文档要在内存里建一整棵 `NSDictionary` 树。

**方案：合法性校验用 `JSONSerialization`，格式化/压缩自己写保序扫描器。**

```swift
/// 检测：trim 后首字符是 { 或 [，且 JSONSerialization 能解析。
/// 不开 .fragmentsAllowed，所以 `123` / `"abc"` 不会被认成 JSON。
static func isJSON(_ text: String) -> Bool
```

扫描器不解析成模型，只做**词法级单遍扫描**（O(n)、无递归、无栈溢出风险）：

```
状态：depth（缩进层级）、inString（是否在字符串内）、escaped（前一字符是否为反斜杠）

逐字符：
  inString 时：
    原样输出
    escaped → escaped = false
    '\'     → escaped = true
    '"'     → inString = false
  非 inString 时：
    '"'        → 输出，inString = true
    '{' '['    → 输出；若下一个非空白字符是对应的闭合符 → 直接输出闭合符（空对象写成 {} 而非跨两行）
                 否则 depth += 1，换行 + 缩进
    '}' ']'    → depth -= 1，换行 + 缩进，输出
    ','        → 输出，换行 + 缩进
    ':'        → 输出 + 一个空格
    空白       → 丢弃
    其他       → 原样输出（数字、true/false/null 的字面量逐字符透传 → 精度天然无损）
```

压缩 = 同一个扫描器，只是**不输出任何缩进、换行，`:` 后也不加空格**。两个动作共用一份代码，用一个 `pretty: Bool` 参数区分。

缩进固定 2 空格，不做配置项。

**转义 / 去转义**

- 转义：把当前文本包装成可嵌进代码的字符串字面量（`"` → `\"`、`\` → `\\`、换行 → `\n`、制表 → `\t`、控制字符 → `\u00XX`）。
- 去转义：若 trim 后首字符是 `"`，用 `JSONSerialization` 开 `.fragmentsAllowed` 解出内层字符串；对结果**重复最多 3 次**（日志里嵌两层很常见，三层封顶防炸）。剥完若是 JSON 则顺带格式化。

### 4.3 XML（`XMLRecognizer.swift`）

```swift
// ⚠️ 剪贴板内容来源不可信：不显式禁用外部实体，一段构造过的 XML
// 能让 App 去读本地文件或发起网络请求（XXE）。这一项不是可选的。
let parseOptions: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]
guard let doc = try? XMLDocument(xmlString: text, options: parseOptions) else { return nil }

let pretty = doc.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
let compact = doc.xmlData(options: [.nodeCompactEmptyElement])
```

检测：trim 后首字符是 `<` 且上面的构造成功。HTML（`.documentTidyHTML`）本期不做。

### 4.4 URL（`URLRecognizer.swift`）

`URLComponents(string: trimmed)` 且 `scheme != nil` 且不含空白。动作：percent 解码（`removingPercentEncoding`）、percent 编码（`addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`）。

有 `queryItems` 时每个参数一行 `FormatRow`，value 用 `removingPercentEncoding` 解码后展示，`copyValue` 给解码后的值。

### 4.5 Base64（`Base64Recognizer.swift`）

门槛（缺一不可，见需求 §5.5）：长度 ≥ 16、字符集合法、长度对齐、解出来是有效 UTF-8、可打印字符占比 ≥ 90%。

```swift
/// base64url → 标准 base64：- → +、_ → /，按需补 = 到 4 的倍数。
static func decodeFlexible(_ s: String) -> Data?
```

解出来是 JSON 时，在 `FormatMatch.rendered` 里直接给格式化后的结果，并让徽章行追加 `JSON`（由 `detectAll` 对解码结果二次识别产生，最多**一层**，不递归）。

### 4.6 JWT（`JWTRecognizer.swift`）

检测：`split(separator: ".")` 得 3 段；每段 `Base64Recognizer.decodeFlexible` 成功；**第一段解出来是含 `alg` 字段的 JSON**。

渲染：三段拼成一个 `rendered`（header 格式化 JSON + 空行 + payload 格式化 JSON + 空行 + signature 原样）。`rows` 给 payload 里的时间声明：

| 声明 | 展示 |
|---|---|
| `exp` | 人类时间 + `已过期 X` / `X 后过期`，已过期时 `isWarning = true` |
| `iat` | 签发时间 |
| `nbf` | 生效时间 |
| `auth_time` | 认证时间 |

时间换算直接调 `TimestampRecognizer` 的换算函数，不重复实现。**不做签名验证。**

JWT 的实现应当**基本是拼装**（解三段 → 丢给 Base64 → 丢给 JSON → 时间丢给 Timestamp），自己几乎不写解析逻辑。如果发现要重写一堆东西，说明 §2 的抽象没设计对，先回头改抽象。

### 4.7 二维码（`CommonActions.swift`）

```swift
static func qrCodeAction(for text: String) -> FormatAction {
    let overLimit = Data(text.utf8).count > QRCodeGenerator.maxBytes
    return FormatAction(
        id: "common.qrcode",
        title: L("clipboard.tools.qrcode"),
        kind: .terminal { text in
            guard let cg = QRCodeGenerator.image(for: text, minPixels: 1024) else { return }
            // 钉在鼠标所在屏中央，260pt 见方（照搬原 QRCodePanelController.pinCentered）
            PinnedImageWindow.pin(image: cg, at: centeredRect(side: 260))
            ClipboardPanelController.current?.hide()
        },
        isEnabled: !overLimit,
        disabledHint: overLimit ? L("clipboard.tools.qrcode.tooLong") : nil
    )
}
```

**必须钉屏而不是画在预览区**：面板装了 `globalClickMonitor`（点面板外即 `hide()`），画在预览区的话用户一去扫码面板就没了。理由详见需求 §5.7。

## 5. UI 改造

### 5.1 ViewModel 新增状态

```swift
@Published var isPreviewMaximized = false      // 初值读 UserDefaults，didSet 写回
@Published private(set) var matches: [FormatMatch] = []
@Published var activeMatchIndex = 0            // didSet 清 transformed
@Published var transformed: (actionTitle: String, text: String)?

/// 预览区实际显示、也是 ⏎ 粘贴的内容。
var previewText: String {
    transformed?.text ?? activeMatch?.rendered ?? selectedItem?.text ?? ""
}

/// 动作栏内容：格式专属在前，通用动作在后。
var visibleActions: [FormatAction]
```

**状态必须放在 ViewModel，不能放 `ClipboardPanelView` 的 `@State`** —— 键盘处理在 `ClipboardPanelController.handleKey` 里，它只够得着 `viewModel`。`hoveredItemID` 那种纯鼠标状态留在 View 里不动。

最大化持久化键：`clipboard.previewMaximized`（默认 `false`，`bool(forKey:)` 天然为 false，无需注册默认值）。

### 5.2 View 布局

`listColumn` 与其分隔线用 `if !viewModel.isPreviewMaximized` 包起来即可（最大化时预览列自然撑满 660pt，扣 padding 后约 630pt 可用）。切换加 `withAnimation(.easeOut(duration: 0.15))`。

预览区自上而下：徽章行 → `ScrollView { 正文 + 表格 }` → 动作栏 → 元信息行（已有）。徽章行在最大化时右侧追加 `activeIndex+1 / filtered.count`。

动作栏按钮标题后缀显示 `⌘n`（n ≤ 9），置灰按钮加 `.help(disabledHint)`。

### 5.3 Controller 键盘

`handleKey` 新增分支（keyCode 取自 `Carbon.HIToolbox`，注意 5 和 6 的 keyCode 是反直觉的 `0x17` / `0x16`）：

| 键 | keyCode | 处理 |
|---|---|---|
| Tab | `0x30` | `viewModel.isPreviewMaximized.toggle()` |
| Esc | `0x35` | 最大化 → 先收起并 `return true`；否则 `hide()` |
| ⌘1…⌘9 | `0x12 0x13 0x14 0x15 0x17 0x16 0x1A 0x1C 0x19` | 触发 `visibleActions[n-1]` |
| ⌘0 | `0x1D` | `viewModel.transformed = nil` |
| ⌘C | `0x08` | 只复制 `previewText`，不粘贴、不关面板 |

⏎ / ⌥⏎ 改为传 `overrideText: viewModel.previewText`。

执行 `.transform` 动作：结果写 `viewModel.transformed`，**不碰剪贴板**。执行 `.terminal`：调闭包，由动作自己收尾。

### 5.4 PasteService

```swift
static func paste(_ item: ClipboardItem, plainText: Bool,
                  overrideText: String? = nil,
                  store: ClipboardStore, monitor: ClipboardMonitor)
```

`writeToPasteboard` 里：`overrideText != nil` 时一律按纯文本写（忽略 `item.type`，转换结果永远是文本）。`monitor.ignoreNextChange = true` 的现有逻辑原样覆盖这条路径 —— **这正是「转换不污染历史」的实现**（需求验收 #2）。

⌘C 的「只复制不粘贴」路径也必须自己置 `ignoreNextChange`。

### 5.5 ClipboardTool 新快捷键

```swift
HotkeyDefinition(id: "clipboard.qrcodeLast",
                 title: L("clipboard.hotkey.qrcodeLast"),
                 subtitle: nil,
                 defaultCombo: nil) { [weak self] in self?.qrCodeLast() }
```

按项目约定**出厂不绑定**（`defaultCombo: nil`），用户在快捷键页自设。`qrCodeLast()` 取 `store.items` 里时间最新的文本类条目，走 §4.7 同一条路径。

## 6. 本地化

新增命名空间 `clipboard.tools.*`（徽章、动作名、表格 label、置灰提示），沿用 `Localizable.xcstrings` 的紧凑单行 JSON 格式，每条必须 en + zh-Hans 齐全。

删除 `qrcode.*` 中的 9 条；`qrcode.panel.tooLong` / `qrcode.panel.empty` 改名为 `clipboard.tools.qrcode.tooLong` / `.empty` 复用。

## 7. 实现顺序

依赖关系决定顺序，**不是六个格式并列**：

```
① 框架          TextFormatRecognizer + ViewModel 状态 + View 布局 + Controller 键盘 + PasteService
② QRCode 移除   QRCodeGenerator 迁 Core、删模块、删注册、清文案（早做，避免后面反复改动同一批文件）
③ 时间          独立，无依赖
④ JSON          独立，保序扫描器是重头
⑤ XML / URL     独立，各自很小
⑥ Base64        依赖 ④（解出来是 JSON 时的二次识别）
⑦ JWT           依赖 ③④⑥，基本是拼装
⑧ 二维码动作     依赖 ①②
```

每一步都应能独立编译通过。①②做完就该能在面板上看到空的徽章行与二维码按钮，验证框架是否站得住。

## 8. 风险与自查

| 风险 | 应对 |
|---|---|
| JSON 数字精度损坏 | 扫描器逐字符透传数字字面量；验收用 19 位雪花 ID 实测 |
| JSON key 顺序变化 | 同上，扫描器不建模型；验收比对原文顺序 |
| XXE | `.nodeLoadExternalEntitiesNever` 必须显式带上 |
| Base64 误报刷屏 | 五道门槛 + 优先级最低；误报只是多一个 chip，不影响正常操作 |
| 主线程卡顿 | 三档长度上限（§3.2）；识别是 O(n) 单遍 |
| 用户搞不清 ⏎ 粘的是哪个版本 | 徽章行「已转换 · 还原」是**必需**的，不是装饰 |
| 二维码扫不到 | 必须钉屏，不能只画在预览区（面板会被点没） |
| 删 QRCode 模块打断 NetCapture | `QRCodeGenerator` 迁 `Sources/Core/`，不能跟着模块一起删 |
| 转换结果污染历史 | 所有写剪贴板路径都要置 `ignoreNextChange` |

无法本地编译，提交前自查：① 引用的类型/方法先 grep 确认签名存在；② 每个 `L()` / `Text()` 的 key 已入 `Localizable.xcstrings`；③ `@Published` 只在主线程写；④ 无 force-unwrap / `try!`；⑤ 跑一遍 catalog 校验：

```bash
python3 -c "import json;json.load(open('Sources/Resources/Localizable.xcstrings'));print('valid')"
```
