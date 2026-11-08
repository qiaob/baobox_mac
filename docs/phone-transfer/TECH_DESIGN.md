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

- `NWListener(using: .tcp)` 不指定端口（系统分配），`.ready` 后读 `listener.port`。
- 地址用 `NetworkInterfaces.primaryIP()`（抓包模块已有，默认路由出口的私有地址）；拿不到私有地址时提示「未连接局域网」。
- 二维码：`http://<ip>:<port>/?t=<token>`，token 为 16 字节随机数的 base64url。
- 每个连接只处理一个请求，响应都带 `Connection: close`。请求头上限 64KB；只认 `Content-Length`，拒绝 chunked。

### 3.2 接口

静态文件 `/`、`/index.html`、`/phone.js`、`/rtc.js` 不需要令牌（白名单，读包内副本）。
`/api/*` 都要 `t=<token>` 和 `c=<clientID>`（手机随机生成，存 localStorage），令牌不对返回 403。

| 方法 路径 | 说明 |
|---|---|
| `GET /api/hello?name=` | 首次调用登记设备并触发 Mac 端「允许 / 拒绝」；返回 `{state: pending/approved/denied, mac}`。手机每秒轮询直到有结果 |
| `GET /api/poll?since=<seq>` | 已允许才可用。返回 `{state, files:[{id,name,size}], texts:[{seq,text}], seq}`：Mac 共享的文件全量 + `seq` 之后 Mac 发的文字。手机每 1.5 秒轮询 |
| `GET /api/file?id=` | 下载 Mac 共享的文件，流式发送（256KB 一块，前一块发完再读下一块），`Content-Disposition: attachment; filename*=UTF-8''…` |
| `POST /api/upload?name=` | 手机上传，body 是文件原始字节。边收边写 `<接收文件夹>/.<uuid>.part`，收完改名为去重后的文件名 |
| `POST /api/text` | 手机发文字，body UTF-8，≤ 1MB |

服务在自己的串行队列上跑；设备表、共享文件表、文字表放在加锁的状态对象里。上传进度、设备请求等事件按项目惯例
`DispatchQueue.main.async { MainActor.assumeIsolated { … } }` 回主线程更新 `@Published`。上传进度每 256KB 或 0.2 秒报一次。

## 4. 公网模式

### 4.1 二维码与房间

`<pageURL>#s=<sid>&k=<key>`：sid 16 字节、key 32 字节，都是 base64url。
信令房间 topic = `bbx` + `hex(SHA-256("baobox-pt:" + sid))` 的前 40 位，服务器只看得到这个哈希。

### 4.2 加密信令

明文 JSON：`{v:1, t:"offer"|"answer"|"deny", from:"p"|"m", id, ts, re?, sdp?, name?, nat?, z?}`。

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

- 文本帧是 JSON 控制消息：`{t:"hello",name}`、`{t:"file",id,name,size,mime}`、`{t:"end",id}`、`{t:"cancel",id}`、`{t:"text",text}`。
- 二进制帧是「当前正在收的那个文件」的数据块，每块 16KB（Safari 兼容的安全值）。
- 每个方向同一时间只发一个文件（排队），两个方向可以同时进行；DataChannel 有序可靠，所以不需要块号。
- 背压：`bufferedAmount` 超过 4MB 暂停，`bufferedamountlow`（阈值 1MB）时继续。
- 手机收到的文件拼成 `Blob`，给出「保存」链接（`<a download>`）。

### 4.7 Mac 宿主（WKWebView）

- `host.html` 与 `rtc.js` 由 Swift 读出拼成一个页面，`loadHTMLString(_, baseURL: https://baobox-host.invalid/)`：
  文档 origin 是 https，属于安全上下文，`crypto.subtle` 可用；页面不加载任何外部资源。ntfy 支持 CORS。
- WebView 以 1×1 尺寸挂在传输窗口里（不挂在视图层级里的 WebView 可能被 WebKit 挂起）；关窗即会话结束，不影响。
- JS → Swift：`webkit.messageHandlers.pt.postMessage({type,…})`：`signal`、`offer`、`state`、`rx-begin`、`rx-chunk`（base64，JS 先攒到 256KB 再发）、
  `rx-end`、`rx-cancel`、`text`、`log`。
- Swift → JS：`callAsyncJavaScript` 调 `ptHost.start(cfg)`、`approve(bool)`、`beginFile(...)`、`sendChunk(b64)`（Promise 在缓冲回落后才 resolve，
  形成背压）、`endFile(id)`、`sendText(text)`、`stop()`。Swift 每次读 256KB 交给 JS，JS 再切成 16KB 发。

## 5. 风险与待验证

1. WKWebView 中 `RTCPeerConnection` 是否默认可用：宿主页启动时检测，不可用就把公网模式标记为「此系统不支持」。
2. JS ↔ Swift 用 base64 过桥的吞吐：公网链路一般是瓶颈，预计足够；实测不够再改 `WKURLSchemeHandler`。
3. iOS Safari 切后台会断：手机页在 `visibilitychange` 时提示保持前台。
4. 公共信令服务没有 SLA：三个后端任一可用即可；全部不可达时提示「信令服务不可用」。
5. GitHub Pages 需要在仓库 Settings → Pages 里把 Source 设为 GitHub Actions，且只在 `main` 上发布。
