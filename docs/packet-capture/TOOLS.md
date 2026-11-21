# 网络抓包 — 第二批功能方案（筛噪音 / 参数分栏 / 重发 / Mock / Protobuf）

> 版本：2026-11-21。设计：Fable；实现：Opus 5.5（用户指定）。
> 前置：`REQUIREMENTS.md`、`TECH_DESIGN.md`（v2，已实现）。本文只写增量。
> 来由：用户看过第一版后点的五项 ——「按域名筛掉噪音 可以，请求参数分栏，可以，重发请求 可以，我觉得再加个 mock 功能，protobuf / gRPC 解码我建议也支持一下」。
> TCP 抓包用户只是问了能不能支持，**不在这一批里**，见 §8。

## 0. 现状（实现者先读）

代码在 `mac/Sources/Modules/NetCapture/`：

| 文件 | 是什么 |
|---|---|
| `NetCaptureEngine.swift` | 起停包内的 `mitmdump`，读它标准输出的事件、往标准输入写指令 |
| `Resources/NetCapture/baobox_bridge.py` | 引擎里的插件（桥脚本）。**本批需要的引擎侧能力已经写好并测过，见 §6，不用再改** |
| `Logic/CaptureEvent.swift`、`Logic/CaptureCommand.swift` | 事件解码、指令编码。纯 Foundation，进 `BaoboxTests` |
| `FlowStore.swift` | `Flow` 模型 + 内存里的列表（`apply(_ events:)`、`filtered(...)`、`hosts(device:)`、cURL / HAR） |
| `NetCaptureSession.swift` | 场景协调（这台 Mac / 手机 / 终端 / 模拟器），窗口和菜单都从它进 |
| `NetCaptureWindow.swift` | 窗口：工具条、左栏（来源 + 域名）、列表、详情、卡片、手机面板。**已经 900 多行，这一批要拆** |

约定见仓库根的 `CLAUDE.md`「约定」一节，尤其：`@Published` 只在主线程写；用户可见文案走 `L()` / `Text("key")` 且每个 key 在 `Localizable.xcstrings` 里有 en + zh-Hans（紧凑单行 JSON）；解析全程容错、无 force-unwrap；写盘失败调 `StorageWriteFailure.report`。

## 1. 按域名筛掉噪音

**要解决的**：一开抓，系统服务的域名（Android 模拟器开机就 29 个）和「未解密」的行把列表刷满，现在只能在左栏一个个点。

**交互**

- 列表行右键加两项：`只看这个域名`（= 现有的域名筛选）、`隐藏这个域名`。
- 左栏最底下加一个**不随列表滚动**的固定区：

```
│ api.x.com        42 │
│ cdn.x.com        17 │
├─────────────────────┤
│ ☑ 隐藏未解密        │
│ 已隐藏 3 个域名  ▾  │   ← 菜单：逐个「显示 xxx」、「全部显示」；没有隐藏的域名时这一行不出现
└─────────────────────┘
```

- 被隐藏的域名、（勾选时）未解密的行，不出现在列表里，也不计入左栏的数字。底部状态条「显示 X / 共 Y 条」里 Y 仍是总数，这样看得出有东西被藏了。
- 隐藏只影响显示：照常抓、照常存，取消隐藏就回来；导出 HAR 导的是当前显示的。

**数据**

- `netcapture.hiddenHosts`：`[String]`，精确域名，UserDefaults，持久（噪音域名每次都是那些）。
- `netcapture.hideUndecrypted`：`Bool`，默认 `false`。

**实现**

- `Logic/FlowFilter.swift`（纯）：一个值类型装下全部筛选条件（来源、域名、方法、状态码类别、隐藏名单、是否藏未解密），`func includes(host:method:statusClass:decrypted:device:) -> Bool`。文本搜索要读正文，留在 `FlowStore`。
- `FlowStore.filtered(...)`、`hosts(device:)`、设备计数都走它。计数不能每次重绘都 O(n) 重算三遍：在 `apply` / 筛选条件变化时算一次，存成 `@Published`。

## 2. 请求参数分栏

**要解决的**：现在「请求」页是一段头 + 一段正文文本，参数多了找不到。

**「请求」页，自上而下**（某一节没有内容就整节不显示）：

| 节 | 内容 |
|---|---|
| Query 参数 | 表：名 / 值。从 path 的 `?` 之后拆，做百分号解码；解码失败显示原文 |
| 请求头 | 表：名 / 值（现在是纯文本行） |
| Cookie | 从 `Cookie` 头拆，表：名 / 值 |
| 正文 | 见下 |

**「响应」页**：响应头（表）、Set-Cookie（每条一行：名、值、其余属性原样）、正文。

**正文怎么显示**（请求、响应相同）

- `application/x-www-form-urlencoded` → 表：名 / 值。
- JSON → 右上角「树 / 文本」切换，默认树。树：对象和数组可折叠，默认展开两层；每层超过 200 个子项只显示前 200 个，末尾一行「还有 N 项」；键保持原文顺序。
- Protobuf / gRPC → 见 §5。
- 其它同现在（图片预览、文本、二进制只报大小）。

每一节标题右边一个小的「复制」（`CopyButton`，已有）：表复制成多行 `名: 值`，正文复制文本。表里的值可以选中。

**实现**

- `Logic/RequestParams.swift`（纯）：`queryItems(path:)`、`cookies(header:)`、`setCookies(headers:)`、`formItems(body:contentType:)`，都返回 `[(name, value)]` 形状的值类型数组。
- `Logic/JSONNode.swift`（纯）：一个只为展示用的小 JSON 解析器，**保持键的原文顺序**（`JSONSerialization` 出来的字典没有顺序，树和文本会对不上），数字保留原文（不丢精度）。解析失败返回 nil，界面退回文本。超过 2 MB 的正文不建树，直接文本。
- 视图：`KeyValueTable`（两列，名定宽、值换行可选中）、`JSONTreeView`（递归 `DisclosureGroup`）。

## 3. 重发请求

**交互**

- 详情区右上角，「复制 cURL」旁边：`重发`、`编辑后重发…`。列表行右键也有这两项。只对解密了的请求有。
- `重发`：原样再发一次。
- `编辑后重发…` 弹一个面板：

```
┌ 编辑后重发 ───────────────────────────────────────┐
│ [POST ▾] [https://api.x.com/v1/login?debug=1    ] │
│ 请求头（每行一个，名: 值）                         │
│ ┌───────────────────────────────────────────────┐ │
│ │ content-type: application/json                │ │
│ │ authorization: Bearer …                       │ │
│ └───────────────────────────────────────────────┘ │
│ 正文                                               │
│ ┌───────────────────────────────────────────────┐ │
│ │ {"email":"a@x.com","password":"…"}            │ │
│ └───────────────────────────────────────────────┘ │
│                              [取消]  [发送]        │
└────────────────────────────────────────────────────┘
```

- 原正文不是 UTF-8 文本（图片、protobuf…）：正文框换成一行「二进制正文 N 字节，原样发送」，不可编辑。
- 发出去的请求是列表里新的一行，带一个 `重发` 小徽标，并自动选中它。
- 引擎没在跑时点重发：先只起引擎（**不动系统代理**），就绪后再发。
- 失败（URL 不合法等）：窗口顶部提示条显示原因。

**实现**

- Swift 这边先生成新 Flow 的 UUID，随指令发给引擎，引擎用它当 id —— 所以发之前就知道该选中哪一行，不用等事件回来对号。
- `CaptureCommand.replay(ReplayRequest)`；`ReplayRequest` = id、method、url、headers、body。
- 发的是**解压后的**正文；`content-length` / `content-encoding` / `transfer-encoding` 这三个头桥脚本会丢掉重算，界面的请求头框里可以不显示它们。
- `Logic/HeaderText.swift`（纯）：多行文本 ↔ `[HTTPHeader]`（按第一个 `:` 切，名去空白，空行跳过，同名保留多条）。
- `NetCaptureSession` 加一个只起引擎的入口（现有的私有 `ensureEngine` 提出来），重发和 Mock 都用。
- 重发的请求也会命中 Mock 规则（和真实请求一致）。

## 4. Mock

**是什么**：给某个接口写死一个响应。命中的请求**不再发给服务器**，引擎直接回你写的内容。

**交互**

- 列表行右键 / 详情区：`Mock…`。面板用这条请求预填 —— 匹配条件 = 方法 + 域名 + 路径（去掉 `?` 之后），响应 = 它抓到的状态码、响应头、正文（还没有响应就 200、空）。

```
┌ Mock 规则 ─────────────────────────────────────────┐
│ ☑ 启用                                             │
│ 匹配  [GET ▾] [api.x.com      ] [/v1/user/*      ] │
│       路径不含 ? 之后的部分，可以用 * 通配           │
│ 响应  状态码 [200]                                  │
│ 响应头（每行一个，名: 值）                          │
│ ┌───────────────────────────────────────────────┐  │
│ │ content-type: application/json                │  │
│ └───────────────────────────────────────────────┘  │
│ 正文                                                │
│ ┌───────────────────────────────────────────────┐  │
│ │ {"id":1,"name":"test","plan":"pro"}           │  │
│ └───────────────────────────────────────────────┘  │
│ 只对已解密的请求生效。                              │
│ [删除]                          [取消]  [保存]      │
└─────────────────────────────────────────────────────┘
```

- 工具条加一个 `Mock` 按钮，有启用的规则时写成 `Mock 2`。点开是规则列表：每行 = 开关 + 方法 + 域名路径 + 状态码；点一行进编辑；有「新建」（空白规则）。
- 被规则应答的行带 `mock` 小徽标；详情「概览」多一行「由 Mock 规则应答」。
- 方法可选「任意」。域名精确匹配。多条规则都能命中时，列表里靠上的那条生效。
- 抓到的响应正文不是 UTF-8 文本时，面板里正文框显示「二进制正文 N 字节」，可以保留原样，也可以清空重写，不能逐字节编辑。

**数据**

- `Logic/MockRule.swift`（纯，`Codable`）：`id`、`enabled`、`method`（`"*"` = 任意）、`host`、`path`、`status`、`headers`、`body: Data`。
- 存 `~/Library/Application Support/Baobox/NetCapture/mock-rules.json`，不放 UserDefaults（正文可能几百 KB）。读不出来就当空表，坏文件改名留着不删；写失败 `StorageWriteFailure.report`。
- `MockRuleStore`（`@MainActor`、`ObservableObject`）：增删改、开关、排序；每次变化把**全量**规则用 `rules` 指令发给引擎；引擎每次就绪（`running` 事件）也发一遍。

## 5. Protobuf / gRPC（顺带 msgpack）

**做到什么程度**：没有 `.proto` 文件，Protobuf 消息里只有字段编号，没有字段名。这一批按编号解出结构：

```
1: 150
2: testing
3:
  1: 42
```

**交互**：正文的 Content-Type 是 `application/grpc*`、含 `protobuf` / `application/proto`、含 `msgpack` 时，正文区显示解码后的文本，上面一行小字「已按 Protobuf 解码（没有 .proto，只有字段编号）」，旁边一个「原始」切换回现在的二进制提示。「复制正文」复制的是解码文本。解不开（标了 protobuf 但不是）就和现在一样按二进制显示。

**实现**：解码在引擎侧做完了（§6 的 `decoded` 字段）。Swift 只需要把它存进 `Flow`（请求、响应各一份：视图名 + 文本）并显示。

**不做 / 限制**（界面上不用写，文档留档）

- 导入 `.proto` 显示字段名：以后再说。
- gRPC 的流式调用：引擎要等一条流结束才给正文，长时间不结束的流看不到中间的消息；超过正文上限的不捕获。

## 6. 引擎侧已有的协议（桥脚本已实现并实测，2026-11-21）

**事件里新增的字段**

| 事件 | 字段 | 含义 |
|---|---|---|
| `request` | `replay: Bool` | 这条是重发出去的 |
| `request` / `response` | `decoded: {"view": "Protobuf" \| "gRPC" \| …, "text": String} \| null` | 结构化二进制正文的文本形式；解不开或不适用是 null |
| `response` | `mock: String \| null` | 应答它的 Mock 规则 id |
| `replay_failed`（新事件） | `id`、`message` | 重发没发出去 |

**新指令**（一行 JSON 写进标准输入）

```json
{"cmd":"replay","id":"<uuid>","method":"POST","url":"https://…","headers":[["名","值"],…],"body":"<base64 或 null>"}
{"cmd":"rules","rules":[{"id":"…","enabled":true,"method":"GET","host":"api.x.com","path":"/v1/user/*","status":200,"headers":[["名","值"]],"body":"<base64>"}]}
```

**实测过的行为**（真引擎 12.3.1）

- Mock：精确路径命中并回 418 + 自定义头 + 正文（规则里写的 `Content-Length` 被丢掉重算）；带 query 的请求照样命中；停用的规则不生效；`/anything/*` 通配命中；别的路径不受影响；发空规则表后恢复走真实服务器；规则表里的坏项被跳过。
- 重发：id 用的是指令里给的；`replay` 为 true；来源是 `127.0.0.1`；同名头保留两条；正文按新内容发、`content-length` 重算、`content-encoding` 被丢掉；没有头或没有 Host 头时自动补 Host（不补服务器回 400）；指令缺字段时回 `replay_failed`。
- 解码：`application/x-protobuf` 与 `application/grpc`（带 5 字节帧头）都解出上面那种结构；标了 protobuf 但不是 protobuf 的正文 `decoded` 为 null；JSON 不受影响。

## 7. Swift 侧要做的事（清单）

**纯逻辑（`Logic/`，都要有单元测试，`Tests/NetCapture/`）**

- `CaptureEvent`：`Request.isReplay`、`Request.decoded`、`Response.mockRuleID`、`Response.decoded`、新的 `.replayFailed(id:message:)`。字段缺失一律按「没有」，不许解不出整条事件。
- `CaptureCommand`：`.replay(ReplayRequest)`、`.rules([MockRule])`。
- 新文件：`FlowFilter`、`RequestParams`、`JSONNode`、`HeaderText`、`MockRule`。

**状态**

- `Flow`：`isReplay`、`mockRuleID`、`requestDecoded`、`responseDecoded`。
- `FlowStore`：走 `FlowFilter`；缓存可见计数。
- `MockRuleStore`（新）。`NetCaptureEngine`：就绪时让 `MockRuleStore` 发规则；`replay_failed` 交给 `NetCaptureSession` 显示。
- `NetCaptureSession`：只起引擎的公开入口；`replay(_:)`。

**界面**

- 先拆文件：把详情相关的（`FlowDetailView`、`CopyButton`、`FlowActions`、`FlowFormat`）从 `NetCaptureWindow.swift` 搬到新文件，再往上加东西。建议：`NetCaptureDetailView.swift`、`NetCaptureBodyViews.swift`（表、JSON 树、解码正文）、`NetCaptureReplaySheet.swift`、`NetCaptureMockViews.swift`。
- 左栏固定区（§1）、行右键菜单的新项、工具条 `Mock` 按钮、行上的 `重发` / `mock` 徽标。
- 详情区右上角按钮多了以后别挤：「复制 cURL」「重发」直接放，「编辑后重发…」「Mock…」收进一个「⋯」菜单。窗口最小宽度下不能换行、不能截断成看不懂的样子。
- 文案：`netcapture.*`，en + zh-Hans 都要。徽标 `mock`、`h2`、`WS` 这类不翻译。

## 8. 这一批不做的

- **TCP 抓包**：用户问了能不能支持，答复是「经过代理的连接能抓，不认代理的程序抓不到」，要不要做还没定。别动。
- 断点、改写请求（改请求头 / 转发到别的服务器）、弱网、会话存盘、`.proto` 导入。
- 真机 iPhone 的 WebSocket（见 `TECH_DESIGN.md` §1）。

## 9. 怎么算做完

每一项都要**实际跑过**，不是只编过：

1. `xcodebuild test`（`mac/` 下，`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）全过，新逻辑有用例。
2. 重发、Mock 经真实的 `NetCaptureEngine` 走通：把真实源码编进一个临时宿主程序（做法见 `TECH_DESIGN.md` §1 与下面的注意事项），起引擎 → `curl -x` 发一条 → 重发 / 加规则 → 看 `FlowStore` 里的结果。
3. 界面渲染成图片自查：请求页（Query / 头 / Cookie / JSON 树）、编辑后重发面板、Mock 面板与规则列表、左栏固定区。
4. `python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'))"` 通过，且模块里用到的每个 key 都在表里。

**注意事项（踩过的坑）**

- 用户可能正在用装好的 Baobox 抓包。**不要** `pkill mitmdump`、不要改系统代理、不要 `make install`、不要动 `/Applications/Baobox.app`。自己起的进程按 pid 结束。验证用的引擎用别的端口（194xx），`curl -x` 指过去，不经过系统代理。
- 临时编出来的 `.app`、探针一律放在名字以 `.noindex` 结尾的目录或会话的临时目录里；`xcodebuild` 的产物用完删掉（`make clean`），否则系统的 App 列表里会多出图标。
- `xcrun swiftc` 要带 `DEVELOPER_DIR`，否则用到的是 CommandLineTools 的 SDK，报一堆 `Swift.swiftinterface` 里的错。
- 渲染探针里点 SwiftUI `List` 的行：先 `NSApp.postEvent(mouseUp)` 再 `window.sendEvent(mouseDown)`，反过来会卡死在表格自己的鼠标跟踪循环里；加一个超时自杀。分段控件（`Picker(.segmented)`）用合成点击点不动，要看别的页就给视图加一个只在探针里用的初始页参数。无边框窗口要自己铺背景色，否则深色模式下字是白的、底也是白的。
- 只提交到本地分支 `feat/netcapture-mitmproxy`，不推送、不开 PR。提交信息英文、conventional commits，末尾带 `Claude-Session:` 与 `Co-Authored-By: Claude <noreply@anthropic.com>`。
