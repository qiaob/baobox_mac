# 手机互传 —— 技术设计

需求见 [REQUIREMENTS.md](REQUIREMENTS.md)。模块 id `phonetransfer`，代码在 `mac/Sources/Modules/PhoneTransfer/`，
网页在 `mac/Sources/Resources/PhoneTransfer/`（**同一份文件**：Mac 局域网服务直接读包内副本，
GitHub Pages 工作流把它发布到 `/transfer/`）。

## 1. 文件

| 文件 | 职责 |
|---|---|
| `PhoneTransferTool.swift` | `ToolModule` 壳：菜单、快捷键、设置 Tab |
| `PhoneTransferSettings.swift` | 设置键、接收文件夹、文件名去重 |
| `PhoneTransferSession.swift` | 会话（`@MainActor ObservableObject`）：模式切换、设备请求、传输列表、文字；协调下面两个后端 |
| `LANTransferServer.swift` | 局域网模式：`NWListener` 上的极简 HTTP/1.1 服务 |
| `RTCTransferHost.swift` | 公网模式：`WKWebView` 里跑 `rtc.js`，Swift ↔ JS 桥 |
| `PhoneTransferWindow.swift` | 窗口与 SwiftUI 视图 |
| `PhoneTransferSettingsView.swift` | 设置页 |
| `PhoneTransferNetwork.swift` | 局域网模式可选的网卡（§3.1） |
| `PhoneTransferImage.swift` | 图片判断、按方向转正的解码、复制到剪贴板；时刻 / 用时格式（§5.1） |
| `Resources/PhoneTransfer/index.html` + `phone.js` | 手机网页（两种模式共用，按 URL 判断模式） |
| `Resources/PhoneTransfer/rtc.js` | 公网模式共享层：加密、信令、WebRTC、分块协议（手机和 Mac 宿主页共用） |
| `Resources/PhoneTransfer/host.html` | Mac 宿主页（不发布到 Pages） |

`Resources/PhoneTransfer` 在 `project.yml` 里和 `Pets` 一样按 folder 引用整体拷进 `Contents/Resources/PhoneTransfer/`。

新用到的系统框架：`WebKit`（公网模式必须有浏览器级 WebRTC 栈，macOS 没有其他公开的 WebRTC API）。

## 2. 会话生命周期

窗口打开 → `PhoneTransferSession.start(mode)`；关窗 → `stop()`：停 HTTP 服务 / 销毁 WebView、清空令牌和密钥。
切换模式 = 停掉当前后端再起另一个；「刷新二维码」= 用新令牌 / 密钥重启当前后端。
二维码 10 分钟内没有设备请求就标记过期（界面盖一层「已过期，点击刷新」）。

## 3. 局域网模式

### 3.1 服务

- 网卡选择存在设置 `phonetransfer.lanInterface`：`""` 自动、`"*"` 所有网卡、其他是 BSD 名（存名字不存 IP，换网络 IP 会变）。
  窗口左栏（局域网模式）一个菜单：自动（显示当前是哪块）/ 各网卡 / 所有网卡；换了就用新令牌重开服务。
- 可选网卡：`getifaddrs` 枚举 up 的 IPv4 网卡（排除回环和 169.254，**保留** VPN、网桥 —— 用户自己选）；
  类型（Wi-Fi / 有线）来自 `NWPathMonitor` 的 `availableInterfaces`（Network 框架，不引 SystemConfiguration），认不出的显示 BSD 名。
  窗口开着期间监视网络变化，刷新列表；选过的网卡不在了，菜单里留一项「（现在不可用）」占位，起服务时提示换网卡。
- 先定地址再起服务：自动 = `NetworkInterfaces.primaryIP()`（抓包模块已有，默认路由出口的私有地址），拿不到私有地址时提示
  「未连接局域网」；选了网卡 = 它的地址；所有网卡 = 二维码用自动的地址、不限制监听。
- 选了网卡（含自动）时 `NWListener` 只绑这个地址：`parameters.requiredLocalEndpoint = .hostPort(host: <ip>, port: .any)`，
  端口由系统分配，`.ready` 后读 `listener.port`。别的网卡、IPv6、127.0.0.1 上都连不进来（2026-11-08 探针实测：`lsof` 显示
  `192.168.x.x:<port>`，经 127.0.0.1 访问被拒）。地址变了（换 Wi-Fi）监听会失败，提示后刷新二维码即可。
- 二维码：`http://<ip>:<port>/#t=<token>`，token 为 16 字节随机数的 base64url。令牌在 `#` 后面，浏览器不会把它发给服务端；
  网页读到后从地址栏抹掉（`history.replaceState`），存进 `sessionStorage`，刷新时接着用（§3.4）。
- 自动 = `NetworkInterfaces.primaryIP()`：原在抓包模块里，抓包暂缓（#103）后挪到 `Core/NetworkInterfaces.swift`。
- 每个连接只处理一个请求，响应都带 `Connection: close`。请求头上限 64KB；只认 `Content-Length`，拒绝 chunked。

### 3.2 接口

静态文件 `/`、`/index.html`、`/phone.js`、`/rtc.js` 不需要令牌（白名单，读包内副本）。
`/api/*` 都要 `c=<clientID>`（手机随机生成，存 localStorage）和签名（§3.4）：签名不对 / 重放 401 `{error:"auth"}`，
时间戳差太多 401 `{error:"clock", now}`，没批准或已作废 403 `{error:"approval"}`。

| 方法 路径 | 说明 |
|---|---|
| `GET /api/hello?name=` | 首次调用登记设备并触发 Mac 端「允许 / 拒绝」；返回 `{state: pending/approved/denied, mac}`。手机每秒轮询直到有结果。没答复的请求每个 IP 最多 1 个、总共最多 4 个，超了返回 429、不登记也不弹审批框（§3.3） |
| `GET /api/poll?since=<seq>` | 已允许才可用。返回 `{state, files:[{id,name,size,ts}], texts:[{seq,text,ts}], seq, limits:{file,room}}`：Mac 共享的文件全量 + `seq` 之后 Mac 发的文字；`ts` 是共享 / 发送的时刻（毫秒时间戳）；`limits` 是单个文件上限和这次会话还能收多少字节（§3.3）。手机每 1.5 秒轮询 |
| `GET /api/file?id=` | 下载 Mac 共享的文件，流式发送（256KB 一块，前一块发完再读下一块），`Content-Disposition: attachment; filename*=UTF-8''…`。`Content-Type` 按扩展名取（`UTType.preferredMIMEType`，取不到用 `application/octet-stream`）：响应带 `nosniff`，图片要有正确的类型手机网页才能用 `<img>` 显示。发完报 `downloadFinished(fileID, started, finished)`，Mac 据此显示最近一次下载的用时 |
| `POST /api/upload?name=` | 手机上传，body 是文件原始字节。边收边写 `<接收文件夹>/.<uuid>.part`，收完改名为去重后的文件名。超过上限返回 413 `{error:"size"/"room", limit}`，同时进行的上传超过 3 个返回 429（§3.3） |
| `POST /api/text` | 手机发文字，body UTF-8，≤ 1MB；算进这次会话的合计 |

### 3.3 上限（#99）

防一台已经允许的设备把磁盘塞满、防乱发的请求刷出一串审批框。两种模式共用 `PhoneTransferLimits`：

| 上限 | 值 | 超了 |
|---|---|---|
| 单个文件 | 10 GB（手机拍的 4K 视频十来分钟就有几个 GB） | 拒收 `size` |
| 这次会话合计（一个二维码，文字也算） | 20 GB | 拒收 `room` |
| 收完之后磁盘要剩 | 2 GB（`volumeAvailableCapacityForImportantUsage`） | 拒收 `room` |
| 同时进行的上传 | 3 个（手机网页本来就一个一个传） | 429 |
| 同时的连接 | 24 个（网页平时 1～3 个） | 新连接直接断开 |
| 没答复的设备请求 | 每个 IP 1 个、总共 4 个 | hello 返回 429 |

- 上传按 `Content-Length` 先占额度，没收成（断开、写盘失败）再还回去。拒收时请求体一个字节都不读，直接回 413 并断开。
- 传到一半被断开的话浏览器只会报「网络错误」，所以 `poll` 带上 `limits`，手机发之前先比一下，超了直接在手机上写原因
  （「超过单个文件上限 10 GB，电脑没收」「电脑这次最多还能收 1.2 GB，没收」）。服务端的检查照做，不信手机。
- Mac 的传输列表记一行「已拒收：超过单个文件上限 10 GB」（`Transfer.note`）。

### 3.4 请求签名（#98）

页面是 http，文件内容是明文（要加密只能上自签证书 TLS，手机端体验太差，用户定了不做）。能做到的是**令牌不上网、请求伪造不了**，
防的是同一个局域网里抓包的人：

- **令牌不上网**：二维码里的令牌在 `#` 后面（§3.1），任何请求里都没有它，只当 HMAC 密钥用。
- **签名**：每个接口请求带 `c`、`ts`（毫秒时间戳）、`n`（16 字节随机数的十六进制），最后一个参数是
  `sig` = HMAC-SHA256(密钥, `方法 \n 路径 \n 去掉 sig 的原始查询串`) 的十六进制。服务端按收到的原始字节验，不重新编码。
  `ts` 与本机差 10 分钟以内；`n` 在 25 分钟内见过就当重放。手机时钟偏了：回 401 `clock` + `now`，网页按它校准后重发一次。
- **下载链接**（`<img>` / `<a download>` 自己发请求，加不了随机数）：用 `exp`（过期时刻）代替 `ts` + `n`，只允许 `GET /api/file`，
  最长 24 小时；网页给 6 小时。重放下载链接只能拿到同一个文件——那个文件本来就是明文传的，不多暴露什么。
- **文字**：查询串带 `bh` = 正文的 SHA-256，服务端比对，内容被改了回 400。上传的文件太大，不签正文（主动篡改防不住，被动抓包够不着令牌）。
- **设备密钥**：批准前用令牌签；批准时服务端给这台设备生成 32 字节密钥 dk，`hello` 的回复里带
  `dk` = dk ⊕ HMAC(令牌, `"dk:" + clientID`)，没有令牌解不出来。之后这台设备的请求只认 dk（`hello` 两把都认）。
  只知道 clientID 的人冒充不了它。
- **换令牌**：批准一台设备后令牌就换，二维码跟着变（`tokenRotated`）。旧二维码被拍走也连不上；还在等审批的设备用它登记时的令牌，不受影响。
- **空闲作废**：已批准的设备 30 分钟没有请求就作废（网页开着时每 1.5 秒轮询，不会误作废），要重新扫码、重新允许。
  服务端每分钟扫一遍，作废了通知会话，从「已连接」列表里去掉。
- **设备码**：审批框和手机等待页都显示 4 位设备码 = HMAC(令牌, `"fp:" + clientID`) 前两字节 mod 10000，两边一致再点允许
  ——防拿到二维码的人抢在你的手机前面登记。
- 网页这边：页面是 http，浏览器不给 `crypto.subtle`，SHA-256 / HMAC 在 `phone.js` 里自己实现（与 OpenSSL 的结果逐字节对过，含分块边界和 1 MB）。

服务在自己的串行队列上跑；设备表、共享文件表、文字表放在加锁的状态对象里。上传进度、设备请求等事件按项目惯例
`DispatchQueue.main.async { MainActor.assumeIsolated { … } }` 回主线程更新 `@Published`。上传进度每 256KB 或 0.2 秒报一次。

## 4. 公网模式

### 4.1 二维码与房间

`<pageURL>#s=<sid>&k=<key>`：sid 16 字节、key 32 字节，都是 base64url。
信令房间 topic = `bbx` + `hex(SHA-256("baobox-pt:" + sid))` 的前 40 位，服务器只看得到这个哈希。

### 4.2 加密信令

明文 JSON：`{v:1, t:"offer"|"answer"|"deny", from:"p"|"m", id, ts, re?, sdp?, name?, nat?, z?, why?}`。
`deny` 的 `why`：`busy`（已经连着别的设备）、`error`（Mac 点了允许，但建连接时宿主页出错，#102：手机立刻显示「电脑那边出错了」，不用等满三分钟）。

线上格式：`B1.` + base64url(iv(12) ‖ AES-GCM-256 密文)，附加数据（AAD）为 topic。
压缩：浏览器支持 `CompressionStream` 时先 `deflate-raw` 再加密，前缀改为 `B1z.`；手机在 offer 里用 `z:1` 声明自己能解压，
Mac 的 answer 才压缩。

接收方丢弃：解密失败、`from` 是自己、`ts` 早于 10 分钟前或晚于 2 分钟后、`id` 重复。answer 的 `re` 必须等于自己 offer 的 `id`。
信令被 AES-GCM 认证，SDP 里的 DTLS 指纹因此不可篡改，中间人无从下手，二维码里不需要再放指纹。

### 4.3 信令后端（同时用，先到先得）

| 后端 | 发 | 收 |
|---|---|---|
| ntfy.sh | `POST https://ntfy.sh/<topic>`（单条 ≤ 4000 字符，超出则不走 ntfy） | `wss://ntfy.sh/<topic>/ws?since=<会话开始秒>` |
| broker.emqx.io | MQTT 3.1.1 over WebSocket `wss://broker.emqx.io:8084/mqtt`，topic `baobox/pt/<topic>`，QoS 0 | 同 |
| broker.hivemq.com | `wss://broker.hivemq.com:8884/mqtt`，同上 | 同 |

MQTT 客户端在 `rtc.js` 里手写（CONNECT / SUBSCRIBE / PUBLISH QoS0 / PINGREQ，约 150 行），不引第三方库。
发送时所有已连上的后端各发一份，接收按 `id` 去重。任一后端可用即可。

### 4.4 建连

1. Mac：订阅房间，等待。
2. 手机（offerer）：订阅房间 → 建 `RTCPeerConnection`、`createDataChannel("pt", {ordered:true})` → 收集候选地址
   （等 `iceGatheringState == complete`，最多 4 秒）→ 把完整 SDP 放进 `offer` 发出（不做 trickle，全程两条消息）。
3. Mac：收到 offer → Swift 弹「允许 / 拒绝」→ 允许则 `setRemoteDescription` + `createAnswer` + 收集完毕后发 `answer`；拒绝发 `deny`。
4. ICE 连通检查，DataChannel `open` 即连上；20 秒没连上判失败。

STUN：`stun.cloudflare.com:3478`、`stun.miwifi.com:3478`、`stun.chat.bilibili.com:3478`、`stun.l.google.com:19302`。不配 TURN。

### 4.5 连接方式与失败诊断

- 连上后 `getStats()` 取选中的候选对：两端都是 `host` → 「局域网直连」，否则 → 「公网直连（打洞）」。
- NAT 判断（双方各自算，手机的结果放进 offer 的 `nat` 字段）：看收集到的 `srflx` 候选。没有 srflx →「UDP 被拦截或 STUN 不可达」；
  同一公网 IP 出现多个不同端口 →「对称型 NAT（可能）」；否则「正常」。
- 失败时界面显示双方 NAT 判断和建议：手机连同一个 Wi-Fi 并切回局域网模式、电脑连手机热点、换个网络。

### 4.6 DataChannel 上的协议

- 文本帧是 JSON 控制消息：`{t:"hello",name}`、`{t:"file",id,name,size,mime}`、`{t:"end",id}`、`{t:"cancel",id}`、`{t:"text",text}`；
  Mac → 手机另有 `{t:"limits",file,room}`（连上时、每收完一个文件后，手机发之前先比）和 `{t:"reject",id,why,limit}`
  （拒收正在发的文件，手机停下并显示原因；上限同 §3.3）。
- Mac 只认开头 `file` 里报的大小：收到的字节比它多，整个文件作废并回 `reject`。
- 二进制帧是「当前正在收的那个文件」的数据块，每块 16KB（Safari 兼容的安全值）。
- 每个方向同一时间只发一个文件（排队），两个方向可以同时进行；DataChannel 有序可靠，所以不需要块号。
- 背压：`bufferedAmount` 超过 4MB 暂停，`bufferedamountlow`（阈值 1MB）时继续。
- 手机收到的文件拼成 `Blob`，给出「保存」链接（`<a download>`）；图片给「查看」，用 Blob URL 显示（见 §5.2）。

### 4.7 Mac 宿主（WKWebView）

- `host.html` 与 `rtc.js` 由 Swift 读出拼成一个页面，`loadHTMLString(_, baseURL: https://baobox-host.invalid/)`：
  文档 origin 是 https，属于安全上下文，`crypto.subtle` 可用；页面不加载任何外部资源。ntfy 支持 CORS。
- WebView 以 1×1 尺寸挂在传输窗口里（不挂在视图层级里的 WebView 可能被 WebKit 挂起）；关窗即会话结束，不影响。
- JS → Swift：`webkit.messageHandlers.pt.postMessage({type,…})`：`signal`、`offer`、`state`、`rx-begin`、`rx-chunk`（base64，JS 先攒到 256KB 再发）、
  `rx-end`、`rx-cancel`、`text`、`log`。
- Swift → JS：`callAsyncJavaScript` 调 `ptHost.start(cfg)`、`approve(bool)`、`beginFile(...)`、`sendChunk(b64)`（Promise 在缓冲回落后才 resolve，
  形成背压）、`endFile(id)`、`sendText(text)`、`limits(file, room)`、`reject(id, why, limit)`、`stop()`。Swift 每次读 256KB 交给 JS，JS 再切成 16KB 发。
- `start`、`approve` 的失败要接住（#102）：`start` 失败马上显示「连不上信令服务」，不再干等 15 秒；`approve` 失败显示「Mac 这边出错了」。
  宿主页里建连接抛异常时发 `state: failed, reason: "error"`（不是打洞失败，不显示 NAT 诊断），并给手机发 `deny`（`why:"error"`）。

## 5. 图片与传输时间

### 5.1 Mac 端

- `PhoneTransferImage.swift`：按扩展名判断图片（`UTType.conforms(to: .image)`）；ImageIO 读图，
  `kCGImageSourceCreateThumbnailWithTransform` 按 EXIF 方向转正（手机照片多数带方向）。缩略图最长边 128 像素；
  复制时按原尺寸解码，在后台编码 PNG + TIFF，回主线程写剪贴板（写法同截图模块）。
- `Transfer` 增加 `createdAt / startedAt / finishedAt / thumbnail`；图片传完（收到的）或加入列表时（发出的）在后台生成缩略图。
  时刻显示 `finishedAt ?? startedAt ?? createdAt`（`Date.formatted(date: .omitted, time: .standard)`），
  用时 = `finishedAt - startedAt`，只在传完时显示；不到 60 秒保留一位小数，否则用 `DateComponentsFormatter`。
- 预览是窗口里的 sheet（不引 QuickLook 框架）：大图在后台按最长边 2400 像素解码；按钮：复制、用「预览」打开、在 Finder 中显示、关闭（Esc）。

### 5.2 手机网页

- 一个隐藏的 `<input type=file multiple>` + 一组类型按钮（`phone.js` 的 `TYPES` 表，界面见 REQUIREMENTS §3.3）：
  点按钮时先设 `accept`（「全部文件」去掉 accept）再 `click()`，在同一个点击事件里，算用户手势，iOS 也会弹选择器。
  accept 同时写扩展名和 MIME：安卓 Chrome 把扩展名换成 MIME 交给系统选择器，iOS 两种都认。WPS 自有格式额外写上
  `application/kswps` 这类 MIME（WPS 在部分系统上注册的类型），写多了不影响。
- 发出的每行：开始发送记时刻，成功后显示 `已发送 · 时刻 · 用时`。
- 收到的图片（按扩展名判断）：按钮「查看」，打开全屏浮层 `<img>`：局域网直接用 `/api/file?...` 地址
  （`<img>` 不理会 `Content-Disposition`），公网用 Blob URL。浮层里有「长按图片可存到相册」提示、下载 / 保存、关闭；
  图片加载失败（浏览器不支持该格式）时改成提示用下载。浮层不能禁用 `-webkit-touch-callout`，否则长按菜单出不来。
- 局域网收到的文件和文字用服务端给的 `ts` 显示时刻；公网收到的文件从 `file` 控制消息到 `end` 记用时。

## 6. 风险与待验证

1. WKWebView 中 `RTCPeerConnection` 是否默认可用：宿主页启动时检测，不可用就把公网模式标记为「此系统不支持」。
2. JS ↔ Swift 用 base64 过桥的吞吐：公网链路一般是瓶颈，预计足够；实测不够再改 `WKURLSchemeHandler`。
3. iOS Safari 切后台会断：手机页在 `visibilitychange` 时提示保持前台。
4. 公共信令服务没有 SLA：三个后端任一可用即可；全部不可达时提示「信令服务不可用」。
5. GitHub Pages 需要在仓库 Settings → Pages 里把 Source 设为 GitHub Actions，且只在 `main` 上发布。
