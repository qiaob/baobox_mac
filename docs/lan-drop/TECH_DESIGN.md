# 局域网传输 —— 技术设计

对应 `REQUIREMENTS.md`。实现照本文档。

## 1. 文件与职责

```
Sources/Modules/LanDrop/
├── LanDropTool.swift          # ToolModule 壳：菜单（开关行 / 地址 / 二维码 / 进度）、快捷键、设置 Tab、生命周期
├── LanDropEnv.swift           # UserDefaults 键与默认值、保存目录、文件名消毒与去重
├── LanDropServer.swift        # NWListener 启停、token、空闲自动关闭、@Published 状态（唯一事实源）
├── LanDropSession.swift       # 单连接 HTTP 会话：解析请求、路由、**流式落盘**
├── LanDropPage.swift          # 内嵌网页（上传 + 下载，HTML/CSS/JS 全内联，零外链）
├── LanDropAccess.swift        # 配对码与设备凭证（权威状态加锁，UI 侧只读镜像）
├── LanDropShare.swift         # Mac → 手机的分享列表（@MainActor 供 UI + 线程安全快照供会话）
├── LanDropSendPanel.swift     # 「发送到手机」浮动面板：拖放区 + 二维码 + 分享列表
├── LanDropTransfers.swift     # 传输记录 store（@Published，进度 / 完成 / 失败）
├── LanDropNotify.swift        # 系统通知封装
└── LanDropSettingsView.swift  # 设置页
```

共享基础设施复用：`NetworkInterfaces`（局域网 IP，**本次从 NetCapture 下沉到 `Sources/Core/`**）、
`QRCodeGenerator`、`ClosureMenuItem`、`L()`。

## 2. 并发模型

| 层 | 隔离 | 说明 |
|---|---|---|
| `LanDropServer` | `@MainActor` + `ObservableObject` | 唯一事实源。菜单与设置页都观察它 |
| `LanDropTransfers` | `@MainActor` + `ObservableObject` | 传输列表，只在主线程写 |
| `LanDropShare` | `@MainActor` + `ObservableObject` | 分享列表，UI 侧唯一事实源 |
| `LanDropShareSnapshot` | `@unchecked Sendable`（NSLock） | 上者的只读快照，供会话在连接队列上查句柄。照 `FlowSnapshotStore` 先例 |
| `LanDropSession` | 非 MainActor，`@unchecked Sendable` | 每连接一个实例，独占自己的串行队列 |

跨线程规则：

- 会话**不读** `@MainActor` 状态。token、保存目录、大小上限在**构造时注入**，
  避免从连接队列反向同步等待主线程。
- 会话向主线程报告统一走 `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`。
- 进度上报**节流**：≥0.2 秒或传输结束才 hop 一次主线程，否则大文件会用进度回调刷爆主线程。
- 落盘用 `FileHandle.write(contentsOf:)`，在连接队列上同步执行（该队列本就是后台）。

## 3. HTTP 协议

极简手写 HTTP/1.1，模式照 `CaptureMCPServer` 的 `MCPHTTPSession`：
`receive` 累积到 `\r\n\r\n` 解析请求行 + 头，再按 `Content-Length` 处理 body。

| 路由 | 方法 | 说明 |
|---|---|---|
| `/` | GET | `?p=<配对码>` → 消费配对码，302 到 `/?k=<凭证>`；`?k=<凭证>` 或 cookie → 返回页面 |
| `/upload` | POST | **原始字节流**上传单个文件。`?k=<凭证>&name=<URL 编码文件名>` |
| `/ping` | GET | 网页轮询探活，返回 `{"ok":true}`。用于「服务已关闭」提示 |
| `/list` | GET | 分享列表（**只有句柄 / 文件名 / 大小，没有路径**），供网页每 5 秒轮询 |
| `/file` | GET | 按句柄下发一个被分享的文件。`?k=<token>&id=<句柄>`，支持 `Range` |
| 其他 | * | 404，空体 |

凭证 / 配对码不对一律 404（不是 401）——不向扫到端口的人暴露这里跑着什么。

**只有 `/`、`/upload`、`/file` 计为「活动」**（刷新空闲计时）。`/ping` 与 `/list` 是网页的
被动轮询，若也算活动，页面开着就永远不会空闲超时，自动关闭形同虚设。

### 为什么用原始字节流而不是 multipart/form-data

网页端用 `fetch` / `XMLHttpRequest` 直接把 `File` 对象作为 body 发出，一个请求一个文件。
好处：

1. **不需要 multipart 解析器**。手写 multipart 边界扫描是经典的 bug 温床（跨 chunk 的边界、
   CRLF 处理、结尾 `--`），而原始流只需「收满 Content-Length 个字节」。
2. **流式落盘天然成立**：每个 chunk 收到即 append，内存占用与文件大小无关。
3. **逐文件进度**：`xhr.upload.onprogress` 直接给出百分比，多文件串行队列上传。

代价是不支持无 JS 的原生表单提交——目标设备是手机浏览器，可接受。

### 落盘流程

```
收到 header → 校验 token / name / Content-Length ≤ 上限
           → 目标名消毒 + 去重 → 创建 <目标>.baobox-part
           → 每个 chunk: 写 part 文件，累加已收字节，节流上报进度
           → 收满: close → rename 为最终名 → 回 200 {"ok":true,"name":"…"}
           → 中断/出错: close → **删除 part 文件** → 回 500 / 直接断开
```

`.baobox-part` 后缀保证半截文件不会被误当成完整文件，且中断后不留垃圾（验收 2）。

## 3.5 下发（Mac → 手机）

**只认句柄，不认路径。** 手机传来的是 `id`，在内存分享表里查；查不到就 404。服务端**没有任何
接受路径输入的入口**，因此这个方向上不存在目录穿越或越权读取——能取到的只有用户拖进面板的文件。

分享表的生命周期：拖入时加入 → 面板里可单项移除 / 清空 → **服务停止即整表清空**，句柄立即失效。
文件在分享期间被删除或移走时 `FileHandle(forReadingFrom:)` 失败 → 404，不 crash。

**背压式流式下发**：发完一块才读下一块（`send` 的 `.contentProcessed` 回调里泵下一块），
4 GB 文件的内存占用等于一块（256 KB）。下发期间节流 2 秒刷一次空闲计时，
否则传大文件传到一半服务会被自动关掉。

**Range**：支持单段 `bytes=a-b` / `a-` / `-suffix`，回 206 + `Content-Range`；
多段或畸形值退化为整文件 200（故不需要 416 分支）。iOS Safari 播放音视频依赖这个。

**Content-Disposition**：图片 / 音视频用 `inline`（Safari 直接打开，长按存进相册，比落到
「文件」App 顺手），其余用 `attachment`。文件名同时给 ASCII 回退与 RFC 5987 的 `filename*`。

**注入防护**：分享列表要嵌进页面的 `<script>`，文件名由用户拖入的文件决定，可能含引号或
`</script>`。序列化交给 `JSONSerialization`，再把 `<` `>` `&` 转成 `\uXXXX` 形式，
任何文件名都无法提前闭合脚本标签。

## 4. 端口与地址

- 默认端口 `8787`，设置页可改。
- **端口占用时回退到系统自动分配**（`NWEndpoint.Port.any`），从 `listener.port` 读回实际端口。
  二维码与菜单地址都基于实际端口现算，所以回退对用户完全透明。
- 绑所有接口（不设 `requiredLocalEndpoint`），手机才连得上；地址展示用
  `NetworkInterfaces.primaryIP()`（默认路由出口网卡，已排除 utun/bridge/awdl 等虚拟接口）。

## 5. 访问控制：配对制（`LanDropAccess.swift`）

### 为什么不是「二维码里放一个长期访问码」

长期码只要服务还开着就一直有效：二维码被拍照、被转发、被人瞟一眼记下，之后随时能用。
**往 URL 里多塞几个参数并不解决这件事**——参数多寡与强度无关，能防住的只有「码本身会失效」。

### 流程

```
二维码  →  http://ip:port/?p=<配对码>        配对码：一次性、120 秒内有效
         ↓ 首次访问
      校验 → 作废该码 → 颁发设备凭证 → 302 到 /?k=<凭证> + Set-Cookie → 立刻签发新的配对码
         ↓
之后所有请求  →  ?k=<凭证> 或 cookie，并（默认）校验来源 IP 与配对时一致
```

于是：

| 威胁 | 结果 |
|---|---|
| 局域网扫端口，直接访问 `http://ip:8787/` | 404（没有配对码） |
| 二维码被拍照，事后再扫 | 已被用过 → 404 |
| 拍下但没人用 | 120 秒后作废 → 404 |
| 拿到别人的设备凭证 | IP 对不上 → 404 |
| 想立刻掐断 | 「换一个配对码」/「断开所有设备」 |

**用掉即换新码**：否则第二台设备就没码可扫了。所以「一次性」不牺牲多设备。

**302 而不是直接回页面**：手机上刷新页面时浏览器会重发地址栏里的 URL，若那里还是配对码，
刷新就会 404。跳到 `/?k=<凭证>` 之后刷新才正常。cookie 与 URL 参数两份都写：
cookie 让后续请求不必带参数，URL 参数保证 cookie 被浏览器策略挡掉时页面里的链接照样能用。

**IP 绑定**（`landrop.bindDevice`，默认开）：手机换网 / DHCP 续租导致 IP 变化时需要重新扫码，
这是刻意的取舍。配对时没取到 IP 的极少数情况下不因此把用户挡在门外。

**新设备配对时发系统通知，且不受任何通知开关控制**——万一扫码的不是你，这是唯一能立刻发现的途径。

### 并发

会话要在自己的连接队列上**同步**校验，所以权威状态放在 `NSLock` 保护的 `LanDropAccessStore`
（照 `FlowSnapshotStore` 先例），`LanDropAccess` 是给 UI 的只读镜像，由服务在变化回调里刷新。
校验用逐字符全量比较（不短路），避免时序侧信道。

## 6. 自动关闭

`lastActivity` 时间戳在「新连接建立」「收到上传字节」「上传完成」时刷新。

不用 `Timer`（项目里没有先例）——开启时用 `DispatchQueue.main.asyncAfter` 排一个到期检查，
到期时比较 `now - lastActivity`：

- 已超时且**无进行中传输** → `stop()`
- 未超时 → 按剩余时间重排下一次检查

`generation` 计数器保证 stop / restart 后旧的排程失效。

系统事件（`NSWorkspace.shared.notificationCenter`）：
`willSleepNotification`、`screensDidSleepNotification` → 立即 `stop()`。
`willTerminate()` → `stop()`。

## 7. 状态机

```
stopped ──start()──▶ starting ──listener ready──▶ running(port)
   ▲                    │                              │
   └────────────────────┴──── failed(msg) ◀────────────┘
                    stop() / 空闲超时 / 睡眠 / 退出
```

`@Published private(set) var state`。菜单开关行读 `isRunning`。

## 8. 设置项（`landrop.*`）

| 键 | 默认 | 说明 |
|---|---|---|
| `landrop.port` | 8787 | 监听端口 |
| `landrop.saveDirectory` | `~/Downloads/Baobox` | 保存目录 |
| `landrop.idleTimeout` | 600 | 空闲自动关闭秒数，0 = 不自动关 |
| `landrop.stopWhenDone` | false | 全部传输完成后立即关闭 |
| `landrop.maxFileSize` | 4 GB | 单文件上限字节数，0 = 不限 |
| `landrop.notifyStart` | true | 开始接收通知 |
| `landrop.notifyDone` | true | 完成通知 |
| `landrop.notifySound` | true | 通知提示音 |
| `landrop.bindDevice` | true | 设备凭证绑定配对时的来源 IP |

## 9. 文件名消毒

```
① URL 解码 → ② 去掉所有 "/" 与 "\" → ③ 去掉控制字符
④ 去掉首尾空白与前导 "." → ⑤ 截断到 200 字节（保留扩展名）
⑥ 结果为空 → "file-<yyyyMMdd-HHmmss>"
⑦ 已存在 → 追加 "-2"、"-3"…（复用 ScreenshotResultHandler.uniqueURL 的思路，本模块内独立实现）
```

③ 之后不可能出现 `..` 作为路径成分，因为已经没有分隔符了；单独的 `..` 会在 ④ 被削成空 → 落到 ⑥。

## 10. 通知

`UNUserNotificationCenter`，模式照 `AIToolsNotify`：请求授权失败也不影响传输，全部判空不 crash。
完成通知带 `userInfo["path"]`，通知中心点击的处理不做（项目没有统一的 delegate）——
改为在菜单的「最近接收」里提供「在访达中显示」。

## 11. 本地化

命名空间 `landrop.*`，每个 key 必须有 en + zh-Hans。手机端网页文案不走 `L()`：
页面是发给手机的字符串，按请求头 `Accept-Language` 选中英文，两套文案作为常量放在
`LanDropPage.swift` 里（与 App 界面语言无关——手机和 Mac 的语言未必一样）。

## 12. 实现顺序

1. `NetworkInterfaces.swift` 从 NetCapture 移到 `Sources/Core/`，NetCapture 专属的
   `magicHost` / `certDownloadURL` / `landingPageURL` 留在模块内的 extension 里（调用点零改动）
2. `LanDropEnv` → `LanDropTransfers` → `LanDropNotify`
3. `LanDropPage`（先出静态页，浏览器直接打开验证）
4. `LanDropSession` → `LanDropServer`
5. `LanDropTool` + `LanDropSettingsView`
6. 本地化 key 入表 → `AppDelegate` 注册
7. Mac → 手机方向：`LanDropShare` → `LanDropSendPanel`（拖放）→ 会话 `/list` `/file` → 网页下载区
