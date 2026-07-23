# 网络抓包工具 — 技术方案

> 版本：v1.0（2026-07-23）· 设计者：Fable · 实现者：Opus 4.8
> 对应需求：同目录 `REQUIREMENTS.md`。模块 `id: "netcapture"`，名称「网络抓包」，symbol `network`。
> 实现约定：Swift 5.9 · macOS 14+ · SwiftUI + AppKit 混合 · **不打包第三方运行时**（证书签发借助系统自带 `/usr/bin/openssl`）· 遵循仓库并发风格（UI/状态 `@MainActor`；网络与重 IO 在后台队列 / Network.framework 自身队列）· 文案 `L("netcapture.*")` 双语入 `Localizable.xcstrings`。

## 0. 硬约束（实现者必读）

- **无法本地编译**（Linux 开发环境，CI 只在 main 构建）。写法保守，只用项目已出现或 Apple 稳定公开 API：`Network`（`NWListener`/`NWConnection`/`NWProtocolTLS`/`sec_protocol_*`）、`Security`（`SecPKCS12Import`/`SecItem*`/`SecTrustSettings`）、`Compression`（gzip/deflate 解压）、`Process`（openssl / networksetup / adb / security / osascript）、`CoreImage`（二维码，复用 QRCode 模块思路）。不使用 SwiftNIO 等第三方。
- Network.framework 的连接回调在各自的 `DispatchQueue` 上执行；所有要发布到 UI 的状态（flow 增删）必须 `DispatchQueue.main.async` 回主线程写 `@Published`。
- 代理必须**故障透传**：任何 MITM 失败（无证书信任、握手失败、Pinning、h2-only）都要退化为**字节透传**（TCP 直连隧道），保证被代理设备照常上网；透传的 HTTPS 只记录 CONNECT 元数据（host:port、字节数），不解明文。
- 关闭 = 彻底停：`NWListener.cancel()`、取消所有连接、还原系统代理、清空/释放 flow 缓冲、停 MCP。关闭后无任何后台线程/监听存活。
- CA 私钥文件 `chmod 600`；抓包内容默认只在内存。

## 1. 文件划分（全部新增，位于 `Sources/Modules/NetCapture/`）

| 文件 | 职责 | 规模 |
|---|---|---|
| `NetCaptureTool.swift` | ToolModule 壳：菜单、快捷键（出厂不绑定）、activate/willTerminate | ~220 |
| `ProxyServer.swift` | `NWListener` 代理主体：接收连接、分流 CONNECT/明文、生命周期 | ~300 |
| `ProxyConnection.swift` | 单连接状态机：HTTP 解析、MITM 或透传、上下游中继、产出 Flow | ~450 |
| `MITMCertAuthority.swift` | CA 生成、按 host 签发叶子证书、SecIdentity 缓存、信任状态查询/安装/移除 | ~350 |
| `HTTPMessage.swift` | HTTP/1.1 请求/响应增量解析（头、chunked、Content-Length）、gzip 解压 | ~350 |
| `FlowStore.swift` | flow 环形缓冲（上限淘汰）、过滤/搜索、`@Published`、.har / cURL 导出 | ~300 |
| `SystemProxyController.swift` | `networksetup` 读/设/还原当前网络服务的 web/secure 代理 | ~180 |
| `NetworkInterfaces.swift` | `getifaddrs` 枚举局域网 IPv4；magic 域名常量 | ~80 |
| `ADBController.swift` | adb 探测、设备枚举、设/清代理、推证书、拉起安装 | ~180 |
| `CaptureMCPServer.swift` | 本地 HTTP MCP（Streamable HTTP）服务：暴露 flow 查询工具；注册进 Claude/Codex | ~350 |
| `NetCaptureWindow.swift` | 中心窗口（列表 + 详情 + 顶部工具条 + 二维码）+ 控制器 | ~650 |
| `NetCaptureSettingsView.swift` | 设置 Tab：端口、上限、隐私、证书、MCP、ADB 指引 | ~350 |

接入点：`AppDelegate.swift` 在 `AIToolsTool()` 之后 `registry.register(NetCaptureTool())`；`docs/REQUIREMENTS.md` 第 6 节加一行；README 双语加模块。

## 2. 代理服务器（`ProxyServer.swift`）

### 2.1 监听

```swift
@MainActor final class ProxyServer: ObservableObject {
    static let shared = ProxyServer()
    @Published private(set) var state: State = .stopped   // stopped / starting / running(port) / failed(msg)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.baobox.netcapture.proxy")
    func start(port: UInt16) { ... }
    func stop() { ... }
}
```

- `NWParameters.tcp`，`allowLocalEndpointReuse = true`，`requiredLocalEndpoint` 不设（绑所有接口，便于手机连）。`NWListener(using:on: NWEndpoint.Port(port))`。
- `newConnectionHandler`：每个连接构造一个 `ProxyConnection(nwConnection:, ca:, store:)`，`start(queue:)`。
- `stateUpdateHandler`：`.ready` → `state = .running(port)` 并（若开启 Mac 本地抓包）调 `SystemProxyController.enable(port:)`；`.failed` → `.failed`（端口占用等，弹提示）。
- `start` 前若 `state == running` 忽略。`stop`：`listener?.cancel()`、遍历取消活动连接（持弱引用集合）、`SystemProxyController.restore()`、`state = .stopped`。

### 2.2 端口与接口

- 默认端口 `9090`（UserDefaults `netcapture.port`，范围 1024–65535）。占用则 `.failed`，提示改端口。
- 监听 `0.0.0.0`（Network.framework 默认绑所有接口），手机用局域网 IP 直连。

## 3. 单连接处理（`ProxyConnection.swift`）——核心

客户端连上代理后，先读第一段数据判定形态：

### 3.1 CONNECT（HTTPS 隧道 → MITM 或透传）

客户端发 `CONNECT example.com:443 HTTP/1.1\r\n\r\n`：

1. 解析出 `host:port`。回写 `HTTP/1.1 200 Connection Established\r\n\r\n` 给客户端。
2. **尝试 MITM**：
   - 用 `MITMCertAuthority.identity(forHost: host)` 拿到该域名的 `sec_identity_t`（叶子证书由本地 CA 签发）。
   - 对**客户端侧**：把当前已建立的明文 TCP 连接「升级」为 TLS 服务端——因为 Network.framework 不能对已有 `NWConnection` 原地加 TLS，需换用**下述隧道法**：新建一对内部通道。实现方式二选一（推荐 A）：
     - **A（推荐，纯 Network.framework 双 NWConnection）**：把客户端 socket 的后续字节视为 TLS 记录，用一个「TLS 服务端」`NWConnection`/`NWProtocolTLS` 处理有难度（NW 无「用现有 fd 建 server 连接」的公开 API）。故采用 **`NWListener` 内部回环**：为每个 MITM 会话临时在 `127.0.0.1:0` 起一个单连接 TLS 监听（`NWProtocolTLS.Options` 设 `sec_protocol_options_set_local_identity(identity)`、ALPN 仅 `http/1.1`），把客户端明文字节 pump 进这个回环 TLS 连接，握手后得到明文 HTTP。**缺点**：每会话一个回环 listener，开销略高。
     - **B（更省，用 POSIX socket + `Network` 的 `NWConnection(connection:)` 不可用）**：改用底层 `SSLCreateContext`/`Security` 的已弃用 API——**不采用**（已废弃）。
   - 结论：采用 **A 回环 TLS 终止**，但优化为**一个共享的内部 TLS `NWListener`**（见 §4.3），不是每会话一个，降低开销。
   - 客户端 TLS 握手成功后：解析其中的 HTTP/1.1 请求（可能多个，keep-alive），对每个请求：建到真实服务器的**上游** TLS `NWConnection`（`NWProtocolTLS` 客户端，ALPN `http/1.1`，SNI = host，验证真实服务器证书——用系统信任，失败则整条透传并标注），转发请求、读响应、回写给客户端 TLS，同时把明文请求/响应交给 `HTTPMessage` 解析产出 `Flow`。
3. **透传兜底**：若拿不到 identity、客户端不肯用我们的证书（TLS 握手失败）、或上游握手失败/疑似 Pinning → 放弃 MITM，退化为**盲隧道**：客户端原始 TCP ↔ 上游 `NWConnection(host:port, .tcp)` 直接双向 `receive`/`send` 中继，只记录 CONNECT 元数据（host、端口、上下行字节、时间）到一条「未解密」Flow。**任何 MITM 异常都走这里，绝不断开设备**。

> 判定「是否 MITM」的开关：设置里可「仅对白名单域名解密」或「对全部域名解密」（默认全部）；不解密的域名直接盲隧道。为性能与隐私，提供域名过滤（allow/deny 列表，可选）。

### 3.2 明文 HTTP（绝对形式请求）

客户端发 `GET http://host/path HTTP/1.1`（代理请求是绝对 URI）：

- 解析绝对 URL → host/port（默认 80）、重写为 origin-form（`GET /path`）转发到上游明文 `NWConnection`；读响应回写客户端；`HTTPMessage` 解析产出 Flow。keep-alive 循环处理同一连接的后续请求。

### 3.3 数据中继与解析

- 用 `NWConnection.receive(minimumIncompleteLength:1, maximumLength: 64KB)` 循环读；把字节喂给 `HTTPMessage` 的增量解析器；边转发边解析（不必等整包，body 边收边转发；解析器只截取受上限约束的副本用于展示，超上限停止缓存但继续转发并标 truncated）。
- 一个 Flow 的生命周期：请求头完 → 建/复用上游 → 请求体流式转发 → 响应头 → 响应体流式回写 → 完成（记录 endTime、sizes、status）。完成时 `FlowStore.shared.append(flow)`（主线程）。

## 4. 证书 CA（`MITMCertAuthority.swift`）

### 4.1 根 CA 生成（首次开启或首次装证书时，一次性）

用 `/usr/bin/openssl` 子进程生成，存 `supportDir`：

```
supportDir/ca/            # ~/Library/Application Support/Baobox/NetCapture/ca/
  baobox-ca.key           # 私钥（chmod 600）
  baobox-ca.pem           # 根证书（PEM，供设备下载/信任）
  baobox-ca.srl           # 序列号
```

命令（后台线程 `Process`）：

```sh
openssl genrsa -out baobox-ca.key 2048
openssl req -x509 -new -nodes -key baobox-ca.key -sha256 -days 3650 \
  -subj "/CN=Baobox Proxy CA/O=Baobox" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -out baobox-ca.pem
```

- CA 有效期 10 年。`CN` 固定「Baobox Proxy CA」。生成幂等：已存在且可解析则复用。

### 4.2 叶子证书按 host 签发（懒加载 + 缓存）

首次遇到某 host 时签发，缓存到内存（`[host: sec_identity_t]`）+ 磁盘（`supportDir/leaf/<host>.p12`）：

```sh
# key 可全局共用一把 leaf.key（省时），证书按 host 签
openssl req -new -key leaf.key -subj "/CN=<host>" -out /tmp/x.csr
openssl x509 -req -in /tmp/x.csr -CA baobox-ca.pem -CAkey baobox-ca.key -CAcreateserial \
  -sha256 -days 825 \
  -extfile <(printf "subjectAltName=DNS:%s\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth" "<host>") \
  -out leaf-<host>.crt
openssl pkcs12 -export -inkey leaf.key -in leaf-<host>.crt -certfile baobox-ca.pem \
  -passout pass:baobox -out <host>.p12
```

- 叶子有效期 ≤825 天（Apple 对服务器证书的最大接受期）。SAN 必须含该 host（现代客户端忽略 CN）。通配符域名可按需签 `*.example.com` 以复用。
- **`.p12` → `SecIdentity`**：`SecPKCS12Import(p12Data, [kSecImportExportPassphrase: "baobox"])` 取 `kSecImportItemIdentity` → `SecIdentity`；再 `sec_identity_create(secIdentity)` 得 `sec_identity_t` 供 `NWProtocolTLS`。
- 首次签发 ~30–80ms（openssl 冷启），之后命中缓存 0 开销。签发失败 → 该 host 透传。
- 为降低对 openssl 每 host 的依赖，可选优化：**纯 Security.framework 签发**（`SecKeyCreateRandomKey` + 手写 X.509 DER + `SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA256)`）。作为 P1 备选，MVP 用 openssl（稳、可推理正确）。

### 4.3 内部 TLS 终止 listener（共享回环）

- 起一个内部 `NWListener`（`127.0.0.1:0`，`NWProtocolTLS` 服务端，`sec_protocol_options_set_challenge_block` 里按 SNI 动态返回对应 host 的 identity——`sec_protocol_metadata_get_server_name` 取 SNI，查/签发 identity，`sec_protocol_options_set_local_identity`）。ALPN 仅 `http/1.1`。
- 每个 CONNECT 会话：把客户端明文字节 forward 到本内部 listener 的一个新连接，握手后拿到明文流。**SNI 动态选证书**是关键，使一个 listener 服务所有 host。
- 若 `challenge_block` 内联签发不可行（需同步返回 identity），改为：每 host 预签发后放入 `[sni: identity]` 表，challenge 时同步查表（未命中则同步阻塞签发一次，openssl 调用放该连接队列，可接受）。

> 该回环方案是 Network.framework 做 TLS MITM 的公认可行路径（NW 无「就地升级现有连接为 TLS 服务端」的 API）。实现者若发现更简洁的 `sec_protocol` 直连方式可替换，但必须保持 SNI 动态选证书 + 故障透传。

### 4.4 信任状态与安装/移除

- **查询是否受信**：`SecTrustSettingsCopyCertificates(.admin/.user)` 找我们的 CA，或用 `SecTrustEvaluateWithError` 对一个自签叶子测试。简化：记录已安装标记 + 提供「重新检测」。
- **Mac 一键安装并信任**（需管理员）：`osascript -e 'do shell script "security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <caPath>" with administrator privileges'`（写系统钥匙串需管理员，弹系统授权框）。或装用户级 `-k ~/Library/Keychains/login.keychain-db` 免管理员但仍需用户在钥匙串里手动改信任——**优先系统级一键**（体验最好）。
- **移除**：`security remove-trusted-cert -d <caPath>` + 从钥匙串删（管理员）。
- **证书下载页**（供手机）：见 §6 magic 域名。

## 5. HTTP 消息解析（`HTTPMessage.swift`）

- 增量解析器 `HTTPParser`（分别用于请求/响应）：状态机 `startLine → headers → body(byLength | chunked | untilClose) → done`。
- 请求行：`METHOD SP target SP HTTP/1.1`；响应行：`HTTP/1.1 SP code SP reason`。头：`Key: Value`，大小写不敏感存原样 + 归一化查询。
- Body：按 `Content-Length` 或 `Transfer-Encoding: chunked`（解 chunk）或（响应无长度时）读到连接关闭。捕获副本受 `netcapture.bodyCap`（默认 5MB）限制，超出停缓存标 `truncated`，但转发不截断。
- 解压展示：`Content-Encoding: gzip|deflate` → `Compression` 框架（`COMPRESSION_ZLIB`）解压后按 Content-Type 渲染；`br`（brotli）无系统解压，标「brotli，未解压」显示原始大小。
- 产出 `Flow`（见下）。解析失败（非法报文）→ 丢弃该 flow 的解析结果，连接仍尽量透传。

```swift
struct Flow: Identifiable {
    let id: UUID
    var method: String; var scheme: String; var host: String; var port: Int; var path: String
    var requestHeaders: [(String,String)]; var requestBody: Data?; var requestTruncated: Bool
    var statusCode: Int?; var responseHeaders: [(String,String)]; var responseBody: Data?; var responseTruncated: Bool
    var startedAt: Date; var endedAt: Date?
    var requestBytes: Int; var responseBytes: Int
    var remoteIP: String?
    var decrypted: Bool          // false = 透传未解密（仅元数据）
    var note: String?            // 如「brotli 未解压」「h2 透传」「TLS 握手失败透传」
    var url: String { "\(scheme)://\(host)\(port == defaultPort ? "" : ":\(port)")\(path)" }
    var durationMs: Int? { endedAt.map { Int($0.timeIntervalSince(startedAt)*1000) } }
}
```

## 6. 局域网 IP 与 magic 域名（`NetworkInterfaces.swift`）

- `getifaddrs` 枚举 `AF_INET`、非 `lo0`、`up & running` 的接口，返回 `[(iface, ip)]`（如 `[("en0","192.168.1.23")]`）。窗口顶部展示全部，菜单取首个。
- **magic 域名**：当被代理设备访问 `http://baobox.proxy/` 或 `http://baobox.proxy/cert`（明文，代理能拦到该 Host），`ProxyConnection` 不转发上游，直接**本地应答**：
  - `/` → 一个简单 HTML 引导页（含「下载证书」链接、设置步骤）。
  - `/cert` 或 `/baobox-ca.pem` → 返回 `baobox-ca.pem`，`Content-Type: application/x-x509-ca-cert`，`Content-Disposition: attachment`（iOS 会引导安装描述文件；Android 触发证书安装）。
- 窗口显示该 URL + **二维码**（复用 QRCode 模块的 `CIQRCodeGenerator` 生成，前景用 accent 色），手机扫码直达下载。也可二维码直接编码「代理设置串」不同平台不一，MVP 二维码编码证书下载 URL（最实用）。

## 7. 系统代理（`SystemProxyController.swift`）

- 取当前活跃网络服务名：`networksetup -listnetworkserviceorder` / `-listallnetworkservices`，取第一个「已启用且有 IP」的（通常 `Wi-Fi`）。允许设置里手动指定服务名。
- **启用**（Mac 本地抓包，开启代理且设置开关为开时）：
  ```sh
  networksetup -setwebproxy "<svc>" 127.0.0.1 <port>
  networksetup -setsecurewebproxy "<svc>" 127.0.0.1 <port>
  networksetup -setwebproxystate "<svc>" on
  networksetup -setsecurewebproxystate "<svc>" on
  ```
- **还原**：开启前先 `-getwebproxy` / `-getsecurewebproxy` 读并保存原状态（enabled/host/port），停止时写回（原本关就关、原本有别的代理就还原成那个）。保存到内存 + UserDefaults（防崩溃后残留：`willTerminate` 与下次启动都尝试还原）。
- `networksetup` 是用户级命令，无需管理员。可能弹一次网络配置授权（系统行为）。

## 8. Flow 存储（`FlowStore.swift`）

```swift
@MainActor final class FlowStore: ObservableObject {
    static let shared = FlowStore()
    @Published private(set) var flows: [Flow] = []       // 追加序；UI 倒序展示
    var maxFlows: Int                                     // netcapture.maxFlows 默认 1000
    func append(_ flow: Flow)                             // 超上限淘汰最旧
    func clear()
    func filtered(query:, methods:, statusClasses:) -> [Flow]
    // 导出
    func harData() -> Data                                // HAR 1.2
    func curl(for: Flow) -> String
    func markdown(for: Flow) -> String
}
```

- 上限淘汰：超 `maxFlows` 移除数组头部。`clear()` 释放所有 body Data。
- HAR 导出：标准 HAR 1.2 JSON（entries 含 request/response/timings），供导入其它工具。
- cURL：`curl -X M 'url' -H 'k: v' --data-binary $'body'`（转义单引号）。
- Markdown：请求行 + 关键头 + body 摘要 + 响应状态 + body 摘要（截断），供「发送到 Claude Code」与复制。

## 9. ADB（`ADBController.swift`，P1）

- 探测 `adb`：`~/Library/Android/sdk/platform-tools/adb`、`/opt/homebrew/bin/adb`、`/usr/local/bin/adb`、PATH `adb`。缓存。
- 设备枚举：`adb devices -l` 解析。多设备时让用户选（窗口/菜单二级）。
- **一键设代理**：`adb -s <serial> shell settings put global http_proxy <lanIP>:<port>`；清除：`... settings put global http_proxy :0`（或 `settings delete global http_proxy`）。
- **推证书 + 拉起安装**：`adb push baobox-ca.pem /sdcard/Download/baobox-ca.crt`；Android 用户 CA 安装需用户在系统设置里手动确认，尝试 `adb shell am start -a android.settings.SECURITY_SETTINGS` 或直接打开证书文件的安装 intent（`am start -a android.intent.action.VIEW -d file:///sdcard/Download/baobox-ca.crt -t application/x-x509-ca-cert`，不同 ROM 行为不一）。UI 明确说明「需在弹出的系统界面点确认；Android 7+ 用户证书仅对声明信任用户 CA 的 App 生效」。
- 无 adb / 无设备 → 展示安装 adb 指引与手动设代理步骤（配合 §6 二维码）。

## 10. 本地 MCP（`CaptureMCPServer.swift`，P1）——结合 AI

**目标**：单独开关启动一个本地 MCP，AI（Claude Code / Codex）可查询抓包结果。

- **传输**：MCP **Streamable HTTP**，本地 `127.0.0.1:<mcpPort>`（UserDefaults `netcapture.mcpPort` 默认 9191），用 `NWListener` 起一个极简 HTTP 服务（复用代理里已有的 HTTP 收发能力），实现 MCP JSON-RPC over HTTP（`initialize` / `tools/list` / `tools/call`）。只处理本机来源，无鉴权（仅监听 loopback）。
- **暴露的工具**（tools/list）：
  - `list_flows(limit?, host?, method?, status?)` → 近期 flow 摘要（id/method/url/status/duration/size/time）。
  - `get_flow(id)` → 单条完整详情（头、body 文本，body 过大则截断并注明）。
  - `search_flows(query, limit?)` → URL/body 关键字匹配摘要。
  - `latest_flows(n)` → 最近 n 条摘要。
  - `clear_flows()` → 清空（返回清了多少条）。
  - 数据直接读 `FlowStore.shared`（跨线程：MCP 连接队列 → `DispatchQueue.main.sync` 快照或维护一份线程安全快照）。body 返回做大小上限与二进制/敏感头（Authorization/Cookie）脱敏可选（设置项「MCP 返回时脱敏鉴权头」默认开）。
- **一键注册进 Claude Code / Codex**（复用既有 MCP 写入基础设施）：
  - Claude Code：写 `~/.claude.json` 顶层 `mcpServers`（复用 `ClaudeCode` 模块的 `mcpServers` 写工具——可把该工具函数提到共享层，或本模块平行实现同样的安全读改写）。条目：`{"type":"http","url":"http://127.0.0.1:9191/mcp"}`，name 如 `baobox-netcapture`。
  - Codex：写 `~/.codex/config.toml` 的 `[mcp_servers.baobox-netcapture]`（Codex 支持 http 型 MCP；用 `docs/codex-assistant/DESIGN.md §5.1` 的块级增删）。
  - 一键移除同理。UI 显示是否已注册到各工具。
- **开关语义**：MCP 开 = 起 HTTP 服务（可独立于抓包代理开关——但查询到的 flow 只有代理开着时才有新数据；UI 说明）。MCP 关 = 停服务、释放端口。注册进 AI 配置是另一个独立动作（写文件），不随开关自动改，避免污染用户配置——提供显式「注册 / 移除」按钮。
- **发送给 AI（`一键发送给ui`）**：窗口/右键「发送到 Claude Code」= 取该 flow 的 Markdown（§8），经 `TerminalLauncher`（复用 ClaudeCode 模块的终端启动器思路）在 flow 所属无关目录起 `claude`，把 Markdown 作为首条提示词（写临时文件 `claude -p "$(cat file)"` 或 `claude < file`，按 CLI 支持选）。或最简：复制 Markdown 到剪贴板并提示「已复制，可粘进 AI」。MVP 至少做「复制为 cURL / Markdown」，「发送到 Claude Code」作增强。

## 11. ToolModule 壳（`NetCaptureTool.swift`）

```swift
@MainActor final class NetCaptureTool: ToolModule {
    let id = "netcapture"; let name = L("netcapture.name"); let symbolName = "network"
    func activate() { /* 不自动开代理；只做轻量准备。崩溃残留的系统代理在此尝试还原一次 */ 
        SystemProxyController.restoreIfLeftover()
    }
    func willTerminate() { ProxyServer.shared.stop(); CaptureMCPServer.shared.stop() }  // 兜底还原系统代理
    func submenuItems() -> [NSMenuItem] { /* §4.1 菜单 */ }
    func hotkeys() -> [HotkeyDefinition] { [ /* netcapture.toggle 出厂不绑定；netcapture.window 出厂不绑定 */ ] }
    func settingsTab() -> AnyView { AnyView(NetCaptureSettingsView()) }
}
```

- `activate()` **不**自动开代理（关闭态零开销原则）；仅还原可能的崩溃残留系统代理。
- 快捷键出厂不绑定（同取色器/ClaudeCode 惯例），设置页可绑「切换抓包」「打开窗口」。
- 菜单主开关点击 → `ProxyServer.shared.start(port:)` / `stop()`；状态行读 `ProxyServer.state` + `FlowStore.flows.count`。
- MCP 开关 = custom view switch 行（仿 `NotifyToggleMenuRow`），`tint` 显式 accent。

## 12. 设置 Tab（`NetCaptureSettingsView.swift`）

segmented / DisclosureGroup 分节：

1. **代理**：端口（TextField + 校验）、「开启时自动设置 Mac 系统代理」Toggle（默认开）、指定网络服务名（默认自动）、flow 上限（Stepper 200–5000）、单条 body 上限（Picker 1/5/20MB）。
2. **HTTPS 证书**：CA 状态（已生成 / 未生成 + 生成按钮）、Mac 信任状态 + 「安装并信任（需管理员）」/「移除信任」、「显示证书下载二维码」（弹 sheet 大二维码 + URL）、说明文字（iOS/Android 安装步骤）。
3. **解密范围**：全部域名（默认）/ 白名单；allow / deny 域名列表增删。
4. **MCP**：开关（起停本地 MCP）、端口、「注册到 Claude Code」/「注册到 Codex」/ 对应「移除」、「MCP 返回脱敏鉴权头」Toggle（默认开）。
5. **ADB**：adb 状态与路径、设备列表、「设为代理 / 清除代理 / 推送证书」按钮、无 adb 指引。
6. **隐私**：「关闭时清空已抓内容」Toggle（默认开）、导出 .har 按钮、一句隐私声明。

## 13. 本地化（`netcapture.*`，约 70 词条）

菜单/窗口/详情 Tab/设置/证书说明/ADB 指引/MCP。示例：`netcapture.name`「网络抓包」/「Network Capture」；`netcapture.menu.start`「开始抓包」；`netcapture.menu.stop`「停止抓包」；`netcapture.menu.status %@ %lld`「抓包中 · %@ · %lld 条」；`netcapture.proxyAddr %@ %lld`「代理地址 %@:%lld」；`netcapture.cert.install`「安装并信任（需管理员）」；`netcapture.mcp.toggle`「本地 MCP」等。费用无关；大小用 `%.1fKB/%.1fMB`，耗时 `%lldms`。

## 14. 风险与取舍（已决策）

- **Network.framework TLS MITM 无「就地升级」API** → 用共享内部回环 TLS listener + SNI 动态选证书（§4.3）。这是最大工程风险点，实现者优先打通此路径的最小可用版本，再接 HTTP 解析。
- **HTTP/2**：只协商 h1（ALPN），强制 h2 的站点透传不解析（UI 标注）。本期不做 h2 解析。
- **证书 Pinning**：Pin 的 App 会拒绝我们的证书 → 该连接透传，属预期，UI 说明。
- **openssl 依赖**：系统自带 LibreSSL，`Process` 调用；若缺失（极罕见）→ 提示无法 MITM，明文抓包仍可用。P1 可切纯 Security.framework 签发去掉此依赖。
- **系统代理残留**：崩溃可能留下指向本机的系统代理导致断网 → `activate()` 与 `willTerminate()` 双重还原 + UserDefaults 保存原状态兜底。
- **隐私**：工具能解密 HTTPS，UI 与文档明确「仅本机调试用途」；默认不落盘、关闭清空、MCP 脱敏鉴权头。
- **无法本地编译** → 实现者自查：每个 `L()` key 入 catalog；`@Published` 只主线程写；`Process`/`NWConnection` 回调不阻塞主线程；连接失败路径都有透传兜底。

## 15. 实现顺序（建议给 Opus 的落地路径）

1. 骨架：`NetCaptureTool` 注册 + 空菜单 + 空窗口 + 设置壳（可编译先行）。
2. `ProxyServer` + `ProxyConnection` 明文 HTTP 代理 + `FlowStore` + 窗口列表/详情（先只抓 HTTP，验证链路）。
3. `SystemProxyController` + 局域网 IP 展示 + magic 域名证书下载页。
4. `MITMCertAuthority`（CA + 叶子 + SecPKCS12Import）+ 内部回环 TLS listener → HTTPS 解密。
5. 证书一键信任、二维码、搜索/过滤/清空、cURL/Markdown/HAR 导出。
6. P1：ADB、本地 MCP、发送到 Claude Code。

每步都是可用增量；HTTPS（步骤 4）是核心难点，前置步骤先把非 TLS 链路和 UI 跑通。

## 16. v1.1 增量：MCP 抓包控制 + 扫码自动配置代理

> 设计者：Fable（2026-07-23 追加）。对应用户诉求：MCP 也能开始/结束抓包并与 UI 互相驱动；代理配置也能扫码自动完成。

### 16.1 MCP 抓包控制工具（新增 3 个）

`CaptureMCPServer` 的 `toolSchemas` 与 `MCPTools.call` 新增：

- `start_capture()` —— 开始抓包（等价 UI 主开关开）。返回 `"starting on 0.0.0.0:<port>, LAN <ip>:<port>"`。
- `stop_capture()` —— 停止抓包。返回 `"stopped"`。
- `capture_status()` —— 返回当前状态：`running <ip>:<port> · <flowCount> flows` / `stopped` / `starting` / `failed`。

已有 `list_flows`（含 host/method/status/limit 过滤）、`get_flow(id)`、`search_flows`、`latest_flows`、`clear_flows` 不变。

**与 UI 互相驱动（关键）**：`ProxyServer.shared` 是**唯一事实源**（`@MainActor`、`@Published var state`），UI 菜单与窗口工具条都观察它。故：

- **MCP → UI**：MCP 工具处理在连接后台队列，`start_capture`/`stop_capture` 必须 `DispatchQueue.main.async { MainActor.assumeIsolated { ProxyServer.shared.start(port:) / .stop() } }`；因 UI 观察同一 `state`，菜单/窗口即时反映。**MCP 不得自持抓包状态**，只转发调用。
- **UI → MCP**：`capture_status` 每次调用**实时读** `ProxyServer.shared.state`（用 `DispatchQueue.main.sync` 从连接队列取一次快照——主线程不会反向等待该队列，无死锁），故 UI 手动开关的结果对 AI 立即可见。
- 维护一个线程安全的运行态镜像（仿 `FlowSnapshotStore`：`ProxyStateSnapshot.shared`，主线程在 `ProxyServer.state` 变化时写、MCP 连接队列读），避免 `main.sync` 亦可，二选一；`main.sync` 更简单且够用。
- **注意**：`start_capture` 要求本机 MCP 服务已开（MCP 开关是另一路）；AI 经 MCP 开抓包 → 代理起 → 若 `autoSystemProxy` 开则同时设 Mac 系统代理。窗口/菜单的开关与 MCP 的开关是两个独立 toggle，但**抓包这一动作**经同一个 `ProxyServer` 单例，天然同步。
- flow 列表/详情已支持过滤（§10 既有）；`get_flow` 保持鉴权头脱敏（默认开）。

### 16.2 扫码自动配置代理（iOS 描述文件；Android 保持 ADB/手动）

**事实约束**：相机扫普通二维码**无法**在 iOS/Android 上设置 HTTP 代理（Wi-Fi 二维码标准 `WIFI:S:...;P:...;;` 只含 SSID/密码，无代理字段）。因此「扫码自动配代理」只能经**平台配置机制**：

- **iOS —— 配置描述文件（`.mobileconfig`）**：二维码指向 `http://baobox.proxy/profile`，代理本地生成并返回一个**未签名** plist 描述文件（`Content-Type: application/x-apple-aspen-config`），内含两个 payload：
  1. **CA 证书**（`PayloadType = com.apple.security.root`，DER base64）——安装即导入根证书（iOS 仍需用户到「设置 › 通用 › 关于本机 › 证书信任设置」手动开启完全信任，描述文件无法免除这一步，UI 文案要说明）。
  2. **Wi-Fi**（`PayloadType = com.apple.wifi.managed`）：`SSID_STR` = 当前 Wi-Fi 名（Mac 侧 `networksetup -getairportnetwork <iface>` 读取，假定手机同网），`ProxyType = Manual`、`ProxyServer = <Mac LAN IP>`、`ProxyServerPort = <port>`。安装后该 SSID 自动走代理。
     - 若拿不到 SSID → 降级为**仅 CA** 的描述文件（仍比裸 `.crt` 方便）；代理仍需手动填（窗口显示 IP:端口）。
     - **系统级全局代理**（`com.apple.proxy.http.global`）仅**监督（supervised/MDM）**设备生效，普通手机不用；故用「按 SSID 的 Wi-Fi payload」。
  - 生成：纯字符串拼 plist（UUID 用固定命名空间派生或随机；`PayloadIdentifier` 用 `com.baobox.netcapture.*`）。无需签名即可安装（显示「未验证」属正常）。
- **Android —— 无描述文件机制**：代理只能经**系统设置手动**或**ADB 一键**（§9 已实现）。二维码对 Android 仅用于**下证书**（`/cert`）。Android 侧 UI 引导：扫码装证书 + 手动填代理，或用 ADB 一键。

**UI**：证书二维码面板（`NetCaptureCertQR`）与窗口的二维码区改为**分平台两个页签/两个二维码**：
- 「iOS：扫码装证书 + 设代理」→ 二维码编码 `http://baobox.proxy/profile`（含上述 caveat 文案：装后去信任设置开启）。
- 「Android / 其它：扫码下证书」→ 二维码编码 `http://baobox.proxy/cert`（现状），下方附代理 `IP:端口`（可复制）与「用 ADB 一键设置」入口。

**magic 域名新增路由**（`ProxyConnection` 本地应答，明文可拦到）：
- `GET /profile` → 生成并返回 iOS `.mobileconfig`（`application/x-apple-aspen-config`，`Content-Disposition: attachment; filename="baobox.mobileconfig"`）。
- `/` 引导页加两个链接：`/profile`（iOS）与 `/cert`（证书原始文件）。
- 新增 `MobileConfigBuilder.swift`（~120 行）：读 `baobox-ca.pem` → DER base64、读当前 SSID、拼 plist。SSID 读取失败或非 Wi-Fi → 只出 CA payload。

**本地化**：新增 `netcapture.qr.ios.*` / `netcapture.qr.android.*` / `netcapture.profile.*`（含 iOS 信任开启提示、Android 手动/ADB 提示）与 3 个 MCP 工具无用户可见文案（工具 description 为英文，面向 AI，不入 catalog）。

### 16.3 验收增量

1. AI 经 MCP 调 `start_capture` → 菜单主开关与窗口即时变「停止抓包」、状态行显示运行；`stop_capture` 反之；`capture_status` 与 UI 手动开关结果一致（双向驱动）。
2. `list_flows`/`get_flow` 经 MCP 返回带过滤的列表与单包详情，鉴权头脱敏。
3. iOS 手机扫「iOS」二维码 → Safari 下描述文件 → 安装后 CA 导入且该 Wi-Fi 代理自动指向 Mac（信任开启按文案手动一步）；拿不到 SSID 时降级为仅 CA 且不报错。
4. Android 扫码仅下证书；代理经 ADB 一键或手动，UI 文案清晰。
