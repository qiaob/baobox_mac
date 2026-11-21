# 网络抓包 — 第二批功能方案（筛噪音 / 参数分栏 / 重发 / Mock / Protobuf）

> 版本：2026-11-21。设计：Fable；实现：Opus 5.5（用户指定）。本文已按实际实现就地改过（实现时用户又追加了几项：两个过滤输入框、三栏宽度、开始抓包立刻切三栏、去掉「发送到 Claude Code」，都写在对应的节里）。
> 前置：`REQUIREMENTS.md`、`TECH_DESIGN.md`（v2，已实现）。本文只写增量。
> 来由：用户看过第一版后点的五项 ——「按域名筛掉噪音 可以，请求参数分栏，可以，重发请求 可以，我觉得再加个 mock 功能，protobuf / gRPC 解码我建议也支持一下」。
> TCP 抓包用户只是问了能不能支持，**不在这一批里**，见 §8。（后来做了，见 `CONTROL.md` §4。）

## 0. 现状（实现者先读）

代码在 `mac/Sources/Modules/NetCapture/`：

| 文件 | 是什么 |
|---|---|
| `NetCaptureEngine.swift` | 起停包内的 `mitmdump`，读它标准输出的事件、往标准输入写指令 |
| `Resources/NetCapture/baobox_bridge.py` | 引擎里的插件（桥脚本）。**本批需要的引擎侧能力已经写好并测过，见 §6，不用再改** |
| `Logic/CaptureEvent.swift`、`Logic/CaptureCommand.swift` | 事件解码、指令编码。纯 Foundation，进 `BaoboxTests` |
| `Logic/FlowFilter.swift`、`RequestParams.swift`、`JSONNode.swift`、`HeaderText.swift`、`MockRule.swift`、`ColumnLayout.swift` | 这一批新加的纯逻辑（筛选、参数拆表、JSON 树、头文本、Mock 规则、三栏宽度），都有单元测试 |
| `FlowStore.swift` | `Flow` 模型 + 内存里的列表（`apply(_ events:)`、筛选条件 `filter` 与左栏数字 `sidebarCounts`、`filtered(query:)`、cURL / HAR） |
| `MockRuleStore.swift` | Mock 规则表：存盘、发给引擎 |
| `NetCaptureSession.swift` | 场景协调（这台 Mac / 手机 / 终端 / 模拟器），窗口和菜单都从它进；`replay(_:)` |
| `NetCaptureWindow.swift` | 窗口：工具条、提示条、左栏（来源 + 域名）、请求列表（新增的过滤、右键、空状态也在这里；拆完约 850 行，原来 1180） |
| `NetCaptureCards.swift` | 五张场景卡片、手机配置面板（原样从窗口文件搬出） |
| `NetCaptureColumns.swift` | 三栏的布局与分隔线拖动（宽度算法在 `Logic/ColumnLayout.swift`） |
| `NetCaptureDetailView.swift` | 右栏详情（概览 / 请求 / 响应 / 消息 / 原始）、`CopyButton`、`FlowActions`、`FlowFormat` |
| `NetCaptureBodyViews.swift` | 两列表 `KeyValueTable`、`SetCookieList`、`JSONTreeView`、正文 `BodySection`（含解码文本） |
| `NetCaptureReplaySheet.swift`、`NetCaptureMockViews.swift` | 编辑后重发面板；Mock 规则列表与编辑面板 |

约定见仓库根的 `CLAUDE.md`「约定」一节，尤其：`@Published` 只在主线程写；用户可见文案走 `L()` / `Text("key")` 且每个 key 在 `Localizable.xcstrings` 里有 en + zh-Hans（紧凑单行 JSON）；解析全程容错、无 force-unwrap；写盘失败调 `StorageWriteFailure.report`。

## 1. 按域名筛掉噪音

**要解决的**：一开抓，系统服务的域名（Android 模拟器开机就 29 个）和「未解密」的行把列表刷满，现在只能在左栏一个个点。

**交互**

- 列表行右键加两项：`只看这个域名`（= 现有的域名筛选）、`隐藏这个域名`。正看着的那条请求的域名被隐藏时，详情回到未选中。
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
- 隐藏只影响显示：照常抓、照常存，取消隐藏就回来；导出 HAR 导的是当前显示的（也就是叠加了下面两个输入框之后的列表）。

**两个过滤输入框**（用户实现时追加）

- 左栏顶部「过滤域名」、请求列表顶部「过滤 URL」：都固定不随列表滚动，在同一条水平线上、同样高（`NetCaptureFilterField`，一行 34pt）；有内容时右边一个 ×。
- 语法相同（`Logic/FlowFilter.swift` 的 `TermFilter(text:)` + `matches(_:)`，两处各传自己的被匹配串）：按空格、英文逗号、中文逗号分词，不分大小写，做「包含」匹配；普通词之间是「或」；`-` 开头的词是排除，排除优先；只有排除词 = 除了被排除的都显示；空词和单独的 `-` 忽略；整框为空 = 不过滤。例：`example -static`、`api cdn`、`-google -apple`；URL：`/api/ -/api/log`、`.png .jpg`、`-.js -.css`。
- 「过滤域名」匹配域名（不含端口和路径），同时作用于左栏的域名列表、左栏的数字和请求列表；左栏当前选中的域名被它（或隐藏名单）藏掉时，取消选中回到「全部」。
- 「过滤 URL」匹配完整 URL（`flow.url`），**只**过滤请求列表，左栏有哪些域名、各是多少条都不随它变。
- 和其他条件都是「与」：隐藏名单、「隐藏未解密」、来源、左栏选中的域名、工具条的全文搜索、方法 / 状态码筛选照常叠加。工具条原来的搜索框不动（搜 URL、正文、WebSocket 消息），占位文字改成「全文搜索」以和「过滤 URL」区分。
- **纯界面过滤**：只决定列表显示哪些行。不向引擎发任何指令、不改解密范围、不改 `FlowStore.flows` 里存的数据；被滤掉的请求照常抓、照常存、照常计入状态条的总数，MCP 服务、「停止时清空」都不受影响。
- **实时**：输入框直接绑定筛选条件，每敲 / 删一个字列表立刻重算（没有防抖、没有回车或「应用」）；删掉内容后被滤掉的行（包括过滤期间新抓到的）立刻全部回来；过滤期间新来的请求，命中的实时出现，不命中的只进存储。
- 记住文字：`netcapture.hostFilterText`、`netcapture.urlFilterText`（String，UserDefaults）。
- **空状态**：有抓到的请求、但被两个输入框 / 隐藏名单 /「隐藏未解密」滤空了时，列表区显示「N 条请求被过滤条件隐藏」，输入框里有字时下面一个「清除过滤」（清两个输入框；隐藏名单仍在脚注菜单里恢复）。N 只数被这四样藏掉的（方法 / 状态码 / 全文搜索滤掉的不算，那几种为空沿用原来的空列表）。一条都还没抓到时是另一个空状态，见 §7。

**数据**

- `netcapture.hiddenHosts`：`[String]`，精确域名，UserDefaults，持久（噪音域名每次都是那些）。
- `netcapture.hideUndecrypted`：`Bool`，默认 `false`。
- `netcapture.hostFilterText`、`netcapture.urlFilterText`：两个输入框的文字。

**实现**

- `Logic/FlowFilter.swift`（纯）：`FlowFilter` 一个值类型装下全部筛选条件（来源、域名、方法、状态码类别、隐藏名单、是否藏未解密、两个输入框的 `TermFilter`），`func includes(host:url:method:statusClass:decrypted:device:) -> Bool`（比原方案多一个 `url`，给「过滤 URL」用）。分两类：`passesNoise`（隐藏名单、「隐藏未解密」、「过滤域名」—— 左栏数字只看它和来源）和 `selects`（来源、选中的域名、方法、状态码）。`visible(_:)` 取子集、`hiddenCount(_:where:)` 数被藏掉的、`selectedHostIsHidden`。`Flow` 经协议 `FilterableFlow` 接进来，测试里用一个小结构体。文本搜索要读正文，留在 `FlowStore`。
- `FlowStore` 持有 `filter`（只经 `updateFilter { }` 改：存盘、取消被藏掉的选中域名、需要时重算数字），`filtered(query:)` 走它；原来的 `hosts(device:)` 删了，左栏的「全部」、每个来源、每个域名的数字是 `SidebarCounts.compute` 一次遍历算出来的 `@Published sidebarCounts`，只在 `apply` / 清空 / 影响数字的条件变化时重算。窗口一次重绘只调一次 `filtered(query:)`，列表和状态条共用。

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

每一节标题右边一个小的「复制」（`CopyButton`，已有；正文那一节也叫「复制」，不再单独叫「复制正文」）：表复制成多行 `名: 值`，Set-Cookie 复制成 `名=值; 属性` 一行一条，正文复制看到的文本（解码过的复制解码文本，JSON 复制原文）。表里的名和值都可以选中。

**什么算文本**（`BodyText.text`）：UTF-8，并且除了换行 / 回车 / 制表 / 换页之外没有控制字符。Protobuf / gRPC 常常碰巧是合法 UTF-8（`00 00 00 00 02 08 2A` 就是），只看编码会把它当文本显示、放进文本框编辑、发出去就变了 —— 所以带控制字符的一律按二进制。正文显示、「编辑后重发」和 Mock 面板都用这一条。

**实现**

- `Logic/RequestParams.swift`（纯）：`queryItems(path:)`、`cookies(header:)`、`setCookies(headers:)`、`formItems(body:contentType:)`，返回值类型数组 `[NameValue]` / `[SetCookie]`（`名、值、其余属性`）。多出来的：`cookies(headers:)` 把所有 `Cookie` 头合起来拆（HTTP/2 会把 Cookie 拆成好几个头发）；`formItems` 不是表单或不是 UTF-8 时返回 nil（界面按别的方式显示）；`copyText(_:)` 生成复制用的文本。Query 与表单的 `+` 当空格再做百分号解码；Cookie 的值不解码（没有统一编码）。
- `Logic/JSONNode.swift`（纯）：一个只为展示用的小 JSON 解析器，**保持键的原文顺序**（`JSONSerialization` 出来的字典没有顺序，树和文本会对不上），数字保留原文（不丢精度）。严格按 RFC 8259（不认注释、尾逗号；嵌套超过 512 层算解不开）。解析失败返回 nil，界面退回文本。超过 2 MB 的正文不建树，直接文本。`prettyText()` 是「文本」那一面（缩进两格、键序和数字写法与原文一致），`children(limit:)` 给树每层前 200 项。
- 视图：`KeyValueTable`（两列，名定宽 150pt、在列内换行，值换行可选中）、`JSONTreeView`（递归 `DisclosureGroup`；macOS 的 `DisclosureGroup` 不给内容缩进，每层自己缩 14pt）。正文的解析结果（建树、拆表单）按「这条请求 + 请求或响应 + 长度」缓存最近 16 份（`BodyPresentationCache`），详情视图重绘时不重新解。

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
- 发出去的请求是列表里新的一行，带一个 `重发` 小徽标，并自动选中它。为了让它看得见：正看着别的设备时左栏回到「全部」（重发的来源是本机）；编辑时改了域名、而左栏选着原来的域名时，取消左栏选中的域名。
- 引擎没在跑时点重发：先只起引擎（**不动系统代理**），就绪后再发。
- 失败（URL 不合法等）：窗口顶部提示条显示原因。

**实现**

- Swift 这边先生成新 Flow 的 UUID，随指令发给引擎，引擎用它当 id —— 所以发之前就知道该选中哪一行，不用等事件回来对号。
- `CaptureCommand.replay(ReplayRequest)`；`ReplayRequest` = id、method、url、headers、body。
- 发的是**解压后的**正文；`content-length` / `content-encoding` / `transfer-encoding` 这三个头桥脚本会丢掉重算，界面的请求头框里可以不显示它们。
- `Logic/HeaderText.swift`（纯）：多行文本 ↔ `[HTTPHeader]`（按第一个 `:` 切，名去空白，空行跳过，同名保留多条）。
- `NetCaptureSession` 的 `ensureEngine(lan:then:)` 从私有改成模块内可调（就是「只起引擎、不动系统代理」的入口），`replay(_:)` 用它。Mock 不用它：规则在引擎每次就绪时都会发一遍，引擎没在跑时保存规则只是存盘，下次开始抓时生效 —— 为了存一条规则去起引擎反而让人意外。
- 重发的请求也会命中 Mock 规则（和真实请求一致）。引擎就绪时先发规则、再跑排队等就绪的重发，所以「引擎没在跑时点重发」也会命中规则（实测，见 `TECH_DESIGN.md` §1）。
- 原请求是 HTTP/2 的，重发出去是 HTTP/1.1（引擎的 `replay.client` 这么发），服务器照常应答。
- 「编辑后重发」的方法菜单是 GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS，原请求是别的方法就把它也放进去。

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

- 工具条加一个 `Mock` 按钮，有启用的规则时写成 `Mock 2`。点开是规则列表：每行 = 开关 + 方法 + 域名路径 + 状态码；点一行进编辑（就在同一个面板里换成编辑面板，不再叠一层）；有「新建」（空白规则）；可以拖动排序；列表下一行小字「多条规则都能命中时，靠上的生效；拖动可以调整顺序。只对已解密的请求生效」。没有规则时是一句「还没有 Mock 规则。在请求上右键选「Mock…」，或新建一条空白规则」。
- 新建的规则（包括从请求预填的）放在列表最后。从请求点「Mock…」直接弹编辑面板，保存后就生效。
- 被规则应答的行带 `mock` 小徽标；详情「概览」多一行「由 Mock 规则应答」。
- 方法可选「任意」。域名精确匹配。多条规则都能命中时，列表里靠上的那条生效。
- 抓到的响应正文不是 UTF-8 文本时，面板里正文框显示「二进制正文 N 字节」，可以保留原样，也可以清空重写，不能逐字节编辑。

**数据**

- `Logic/MockRule.swift`（纯，`Codable`）：`id`、`enabled`、`method`（`"*"` = 任意）、`host`、`path`、`status`、`headers`、`body: Data`。
- 存 `~/Library/Application Support/Baobox/NetCapture/mock-rules.json`，不放 UserDefaults（正文可能几百 KB）。文件是 `[MockRule]` 的 JSON，正文 base64、头 `[[名, 值]]`（和 `rules` 指令同一个形状）。读不出来就当空表，坏文件改名成 `mock-rules.broken-<时间>.json` 留着不删；数组里单条坏掉的跳过、缺的字段用默认值（只有 `host` 必需）；写失败 `StorageWriteFailure.report`。
- `MockRuleStore`（`@MainActor`、`ObservableObject`）：增删改、开关、排序；每次变化把**全量**规则（停用的也带上，引擎自己跳过）用 `rules` 指令发给引擎；引擎每次就绪（`running` 事件）也发一遍。模块 `activate()` 时在后台读一次文件，读完也发一遍。保存前整理（`MockRule.normalized()`）：域名转小写、路径去掉 `?` 之后并补开头的 `/`、方法转大写（空着 = 任意）；域名为空或状态码不在 100–599 时「保存」是灰的。

## 5. Protobuf / gRPC（顺带 msgpack）

**做到什么程度**：没有 `.proto` 文件，Protobuf 消息里只有字段编号，没有字段名。这一批按编号解出结构：

```
1: 150
2: testing
3:
  1: 42
```

**交互**：正文的 Content-Type 是 `application/grpc*`、含 `protobuf` / `application/proto`、含 `msgpack` 时，正文区显示解码后的文本，上面一行小字「已按 Protobuf 解码（没有 .proto，只有字段编号）」，旁边一个「原始」切换回现在的二进制提示。「复制」复制的是解码文本。解不开（标了 protobuf 但不是）就和现在一样按二进制显示。

实际：小字里的名字用引擎给的视图名（实测是 `Protobuf`、`gRPC`、`MsgPack`）；Protobuf / gRPC 写「已按 X 解码（没有 .proto，只有字段编号）」，MsgPack 只写「已按 MsgPack 解码」。引擎的文本原样显示，它会在整数字段后面带一句 `# !sint: 75`（同一个数按 zigzag 解的值），不删；末尾的空行去掉。请求和响应都有，「原始」是一个按下 / 弹起的按钮。

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

- 先拆文件：把详情相关的（`FlowDetailView`、`CopyButton`、`FlowActions`、`FlowFormat`）从 `NetCaptureWindow.swift` 搬到新文件，再往上加东西：`NetCaptureDetailView.swift`、`NetCaptureBodyViews.swift`（表、JSON 树、解码正文）、`NetCaptureReplaySheet.swift`、`NetCaptureMockViews.swift`，外加三栏布局 `NetCaptureColumns.swift`；卡片和手机面板也搬去了 `NetCaptureCards.swift`。
- 左栏固定区（§1）、行右键菜单的新项、工具条 `Mock` 按钮、行上的 `重发` / `mock` 徽标。
- 列表行右键（最终）：只看这个域名、隐藏这个域名 ｜ 重发、编辑后重发…、Mock… ｜ 复制 cURL、复制为 Markdown ｜ 复制地址。中间两组只对解密了的请求有。原来的「发送到 Claude Code」按用户要求去掉了（界面上不再有这个入口；本地 MCP 服务是另一个功能，不动）。
- 详情区右上角按钮多了以后别挤：「复制 cURL」「重发」直接放，「编辑后重发…」「Mock…」收进一个「⋯」菜单。放不下一行时（英文界面、详情区在最小宽度 420 附近）页签一行、按钮挪到第二行靠右（`ViewThatFits`），按钮文字不截断。
- 工具条在窗口最小宽度 900 下不换行：方法 / 状态码小标签不折行（`fixedSize`），全文搜索框先缩（最窄 70），证书那一项放不下文字时只留图标（悬停仍有说明）。
- 文案：`netcapture.*`，en + zh-Hans 都要。徽标 `mock`、`h2`、`WS` 这类不翻译。

**三栏宽度**（用户实现时追加）：详情最宽。左栏默认 200（可拖 160–280），请求列表默认 360（可拖 280–560），详情占其余、最少 420；窗口拉宽时多出来的全给详情，左栏和列表不变；窗口变窄、详情不够 420 时先缩列表、再缩左栏。窗口默认 1080×660 → 200 / 360 / 518，最小 900（三栏最小合计 862）。实现：SwiftUI 的 `HSplitView` 不认 `idealWidth`（按 HStack 的规则分：不给优先级时详情停在最小宽度，给详情 `layoutPriority` 时列表停在最小宽度），实测给不出「默认 200、又能拖到 280」，所以换成自己算：`Logic/ColumnLayout.swift`（纯，有单元测试）+ `NetCaptureColumns`（1pt 分隔线，两边各多 3.5pt 的拖动区域，悬停显示左右箭头光标）。拖出来的宽度只在这次打开期间记着。

**开始抓包后立刻切到三栏**（用户实现时追加）：卡片页只在「引擎没在跑（不在 starting / running）且列表为空」时出现；其余情况都是三栏 —— 一开始抓（这台 Mac、手机、只起引擎给终端用、模拟器，引擎一进入 starting）就切过去，不等第一条请求；停止后列表里还有数据也留在三栏；停止且列表为空、或没在抓时清空了列表，回到卡片页；启动失败（`failed`）且列表为空留在卡片页，原因照旧在提示条里。正在抓、一条都还没有时，请求列表区居中「正在抓包，等待请求…」，下面一行小字是工具条「抓：…」那一句（只起了引擎、没开任何来源时不写这一行），详情区是原来的未选中占位。卡片上的操作在三栏里都能找到 —— 「抓：…」菜单按来源分组：这台 Mac（开关）｜ 手机与平板（开关）、手机配置二维码…（开着时）、设置 Android 设备… ｜ 打开抓包终端、复制环境变量 ｜ 给 iOS 模拟器装证书、设置 Android 模拟器…。其中「设置 Android 设备…」「设置 Android 模拟器…」是这次补的（用卡片上的文案 key，两项做的事一样：开局域网监听并打开 Android 面板，面板里会列出模拟器）。

## 8. 这一批不做的

- **TCP 抓包**：用户问了能不能支持，答复是「经过代理的连接能抓，不认代理的程序抓不到」，要不要做还没定。别动。（2026-11-21 定了、做了：「TCP 包」标签页，见 `CONTROL.md` §4。）
- 断点、改写请求（改请求头 / 转发到别的服务器）、弱网、会话存盘、`.proto` 导入。
- 真机 iPhone 的 WebSocket（见 `TECH_DESIGN.md` §1）。

## 9. 怎么算做完

每一项都要**实际跑过**，不是只编过（这一批实际跑了什么、没跑什么记在 `TECH_DESIGN.md` §1 的「第二批验证」）：

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
