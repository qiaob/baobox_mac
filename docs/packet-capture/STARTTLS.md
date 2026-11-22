# XMPP 的 STARTTLS 解密（方案）

## 0. 用户要的是什么（原话，2026-11-22）

> 这里 我再抓取xmpp协议，前几个包是明文，后边就加密了，我如果有私钥能解析吗？能做个私钥配置的入口吗？
>
> 或者 直接 使用 baobox自己的证书

截图里是手机经 WireGuard 连 `139.95.11.88:5222`：开头的 `<stream:features>`、`<starttls/>`、`<proceed/>` 是明文，之后是 TLS（ClientHello 里的域名 `chat.coffeemeetsbagel.com`），TCP 页里只剩密文。

## 1. 结论

- **已经抓下来的密文，有私钥也解不开**：TLS 1.3 和 TLS 1.2 的 ECDHE 都有前向保密，会话密钥不由服务器私钥决定。只有老式 RSA 密钥交换能拿私钥事后解，现在的服务器基本不用。
- **能做的是引擎在 `<proceed/>` 之后接管 TLS**（中间人）：跟手机那段用 Baobox 自己的证书握手，跟服务器另握一次，中间就是明文 XMPP。**不需要私钥入口**，按用户第二句话用 Baobox 自己的证书。
- 手机得信任 Baobox 证书。查过 CMB 客户端：
  - Android：`debug` 包（`debug-overrides`）和 `stagingRelease` 包（`base-config` 里有 `user`）信任用户装的证书；XMPP 用 Smack，`SecurityMode.required`，没有自定义 TrustManager，走系统信任。**装了 Baobox 证书就能解**。正式包不信任用户证书 → 握手失败 → 自动放行，和现在一样看到密文。
  - iOS：XMPPFramework，`startTLSPolicy = .required`，没有自己评估证书（没实现 `didReceiveTrust`），走系统信任：装了 Baobox 描述文件并在「证书信任设置」里打开就能解。
- 私钥入口（mitmproxy 的 `certs` 选项：按域名出示真证书 + 私钥，证书固定的 App 也能过）**这次不做**：只有正式包才需要，而且得把生产私钥放到笔记本上。以后要做，HTTPS 也能一起用。

## 2. 已验证（2026-11-22，包里的 mitmproxy 12.3.1）

本机假 XMPP 服务器（明文 stream → `<starttls/>` → `<proceed/>` → TLS，自签证书）+ 客户端经 HTTP 代理 `CONNECT` 进来 + 插件里一个自定义层：

- 插件的 `next_layer` 看到客户端头几个字节是 `<?xml … <stream`，换上自定义层；自定义层原样转发明文，看到服务器发 `<proceed` 并转发后，把连接交给新的 `NextLayer`。
- 之后引擎自己认出 ClientHello，压上 `ServerTLSLayer` → `ClientTLSLayer` → TCP 层：客户端拿到的是 mitmproxy CA 签的证书（TLSv1.3），服务器那边也是 TLSv1.3；`<message>secret-from-client</message>` / `secret-from-server` 以明文进了 `tcp_message`。
- 引擎的 `ssl_insecure` 在探针里开着（假服务器是自签证书）；真服务器有正规证书，不用开。

**没验证**：经 WireGuard 进来的连接（层栈是透明代理，逻辑相同）、真的 Smack / XMPPFramework 客户端、手机不信任证书时的失败路径。

## 3. 做法

### 3.1 桥：什么时候接管

- `next_layer`：一条连接的客户端头几个字节是 XMPP 流开头（`<?xml` 后跟 `<stream`，或直接 `<stream:stream`，和 `TCPProtocol` 认 XMPP 的规则一致），就换上 STARTTLS 层。不看端口。
- 经 SOCKS 进来的不接管（现有规则：SOCKS 上非 443 的一律不动，避免碰 Mac 上的邮件、聊天 App）。
- STARTTLS 层在看到 `<proceed/>` 之后决定接不接管（2026-11-22 按 `TLS-FINGERPRINT.md` §3.3 改过）：
  1. 「解密 HTTPS」关着 → 不接管（原因 `decrypt_off`），`<proceed/>` 那一刻就定；
  2. 域名不在解密范围内 → 不接管（`out_of_scope`），也是那一刻就定 —— 域名取客户端 stream 头里的 `to='…'`（截图里就是 `chat.coffeemeetsbagel.com`，和随后 ClientHello 的 SNI 一致）；
  3. 前两条都满足 → 先把客户端接下来的数据攒着，直到凑齐一个完整的 ClientHello（用引擎自带的解析；不完整就接着等，不是 TLS 就不接管），算客户端指纹，查失败表：这台设备 + 这个域名 + 这个指纹之前握手失败过 → 不接管（`handshake_failed`），攒着的数据原样发给服务器、照样记字节；没失败过 → 攒着的数据连同连接交给 `NextLayer`，接管。
- 不接管：STARTTLS 层继续原样转发、照样记字节（就是现在看到的密文），并像 HTTP 页那样报一次「没解密」的原因（关着 / 不在范围 / 握手失败）。
- 接管后手机拒绝证书：`tls_failed_client` 把（设备，域名，指纹）记进失败表，这条连接断掉；客户端重连时第 3 条命中，原样放行。和 HTTPS 的「握手失败自动放行」是同一张表、同一个键。

### 3.2 桥：一条连接一行

- STARTTLS 层自己发 `tcp_open` / `tcp_data`（明文阶段），连接 id 用层创建时生成的那个。
- 接管后引擎里的 TCP 层会建一个新的 TCP flow；桥按客户端连接把它对回原来的 id，之后的 `tcp_data` / `tcp_close` 都记在同一行上。
- 新事件 `{"event": "tcp_tls", "id": …, "state": "decrypted" | "failed", "sni": …}`：接管握手成功发 `decrypted`，失败发 `failed`。

### 3.3 界面

界面以示意图为准：`mockups/wireguard-devices-starttls.html` 图 5、图 6（2026-11-22 用户确认）。

- TCP 详情：明文和解密后的内容之间插一条分隔行「以下是 TLS 解密后的内容 · <域名> · TLS 1.3」；没接管的连接在密文前也插一条「以下是 TLS 密文（没解密）」，顶部一条提示说明原因：握手失败 =「没解密：手机不信任 Baobox 证书。debug / staging 包装上证书（配置页「给其他设备装证书」）就能解；正式包不信任用户装的证书，解不了。」；「解密 HTTPS」关着、不在解密范围各一句，放同一个位置。
- TCP 列表：协议标签旁多一个小标签「已解密」（没接管的是「未解密」）。只对 STARTTLS 接管过的连接显示，别的连接不加标签。
- 协议识别不变（明文开头就认出 XMPP）。
- MCP `get_tcp_connection` / `list_tcp_connections` 多一个字段 `tls`：`decrypted` / `failed` / 没有。

### 3.4 用户要做的

手机装 Baobox 证书（配置页「给其他设备装证书」）；用 debug / staging 包。配置页不加新开关：跟着现有的「解密 HTTPS」和解密范围走。

## 4. 这一次不做

- 私钥 / 自定义证书入口（见 §1）。
- 其他协议的 STARTTLS（SMTP、IMAP、POP3 是同一个机制，换个触发词就行，没人要先不做）。
- XMPP 消息拆分 / 结构化显示（仍按连续的流显示，见 `CONTROL.md` §7）。

## 5. 做完的标准

1. 真引擎 + 真桥脚本重跑 §2 的探针：经 `CONNECT` 和经 WireGuard（模拟器上 `nc` 或小脚本连本机假服务器）各一次，一条连接一行、明文在前、解密内容在后；客户端不信任 CA 的一次 → 失败表生效，重连原样放行且照样记字节；「解密 HTTPS」关着 / 不在范围时不接管。
2. 单元测试：`TCPLog` 处理 `tcp_tls`（分隔位置、失败状态）、事件解析。
3. 界面渲染探针：解密成功 / 失败 / 没接管三种连接的列表行和详情，中英文。
4. xcstrings 校验、`make build`、测试全过；只做本地提交。
5. 要用户在真机上试的：CMB staging 包经 WireGuard 连 `chat.coffeemeetsbagel.com:5222`，TCP 页能看到解密后的 XMPP；iPhone 同样一遍。

## 6. 实现时和方案不一样的地方（2026-11-22）

用户看得见的行为照 §3 做了；下面是方案没写到、或者写法和实际做法不一样的地方。

| # | 方案原写法 | 实际做法 | 为什么 |
|---|---|---|---|
| 1 | `tcp_tls` 的 `state` 只有 `decrypted` / `failed`，接管握手成功 / 失败时发 | 没接管的连接也在 `<proceed/>` 那一刻发一条 `failed`；另带 `reason`（`handshake_failed` / `decrypt_off` / `out_of_scope` / `server_handshake_failed`）和解开时的 `version`（`TLSv1.3`） | 详情顶上的说明要知道是哪种原因，分隔线上要写 TLS 版本；列表的「未解密」标签也靠它 |
| 2 | 客户端头几个字节是 XMPP 流开头才换上 STARTTLS 层 | 只有 `<?xml` 也先换上，层里看到 `<stream` 才算 XMPP、才会在 `<proceed/>` 时接管；不是 XMPP 的就一直原样转发、照样记成一条 TCP 连接（没有 TLS 标签） | iOS 的 XMPPFramework 把 `<?xml version='1.0'?>` 和 `<stream:stream …>` 分两次写，Nagle 下常常分两次到；等引擎自己决定就成了普通 TCP 层，再也接不了。实测：客户端分两次写（21 字节 + 122 字节）照样接管 |
| 3 | 域名取 stream 头里的 `to` | 没有 `to` 时用服务器的 IP | 极少见，但范围判断总得有个东西比 |
| 4 | 失败只写了「手机拒绝证书」 | Baobox 和服务器握手失败（服务器证书没通过检查）也记进失败表、`reason: server_handshake_failed`，详情顶上一句「没解密：Baobox 和服务器的 TLS 握手失败。服务器的证书没通过检查，App 下次连接时原样放行。」 | 不记的话每次重连都被接管、每次都断，App 一直连不上 |
| 5 | 没写 | 连接结束：解开了的由引擎的 TCP 流结束时发 `tcp_close`；没接管、接管时被拒、连不上服务器的，在引擎的 `client_disconnected` 钩子里发（只发一次） | 后几种没有引擎的 TCP 流，不这样就一直是「进行中」 |
| 6 | 「解密 HTTPS」关着、不在解密范围「各一句」 | 「没解密：「解密 HTTPS」关着。在配置页打开它，App 下次连接时就会解密。」「没解密：这个域名不在解密范围里。把它加进解密范围（配置页「解密 HTTPS」旁的「范围…」），App 下次连接时就会解密。」 | 方案没给原文 |
| 7 | 没写 | 详情概览的「协议」写成「XMPP · 已解密 / 未解密」；「复制全部」里分隔线也是一行；合块不跨过分隔线（线两边同方向的段不合在一起，偏移照样按方向累计） | 复制出去也看得出从哪里开始是 TLS；跨线合块会把明文和密文糊成一块 |
| 8 | MCP 多一个字段 `tls` | `list_tcp_connections` 每行 `tls=decrypted` 或 `tls=failed(<reason>)`；`get_tcp_connection` 多一行 `TLS: decrypted · chat.example.test · TLS 1.3`，数据里分隔处一行 `-- TLS taken over at <proceed/>: decrypted data below (…) --` / `-- TLS not decrypted: ciphertext below --` | MCP 的输出是文本，不是 JSON |
| 9 | 没写 | 接管时被拒的那一条，分隔线放在数据最后（线后没有数据），连接以出错结束，错误原文写在概览里 | 那条连接在 TLS 握手时就断了 |
| 10 | 「客户端头几个字节是 XMPP 流开头就换上 STARTTLS 层」 | 层栈只有 HTTP 代理层（还没 `CONNECT`，有人直接往代理端口写 XML）时不换；换之前先看这个来源能不能用引擎（本机、隧道设备、已允许且「手动代理」开着的局域网设备），不能的不接管、不记录（独立审查 #2） | 原来局域网设备直接往代理端口写 XML，能绕过「允许 / 屏蔽」在 TCP 页刷出行 |
| 11 | 只看到 `<?xml` 就先换上（本节 #2） | 第一段比 `<?xml` / `<stream:stream` 还短、但是它们的开头（例如 `<?x`）时也先换上，看到完整的 stream 头才算 XMPP（审查 #8）；攒 ClientHello 时客户端半关或连接断开，已经攒下的照样发出去、记进字节；空的一次读不算数 | 引擎自己的判断不会等，交给它就成了普通 TCP、再也接不了；审查用的测试程序复现过：`<?x` 原来装不上层，半关时攒下的 20 字节原来没发也没记 |

> 2026-11-22 追加的 `TLS-FINGERPRINT.md` 把 §3.1「在 `<proceed/>` 那一刻决定」改成等第一个 ClientHello 到齐再决定（失败表多一个客户端 TLS 指纹），§3.1 已按它改写；验证见那份文档 §6。

## 7. 验证记录（2026-11-22）

**真引擎 + 真桥脚本**（同 `WIREGUARD-DEVICES.md` §11 的宿主程序；本机一个假 XMPP 服务器 19680：明文 stream → `<starttls/>` → `<proceed/>` → TLS，自签证书 `chat.example.test`；客户端把 XML 声明和 stream 头分两次写；宿主里引擎多开了 `ssl_insecure`，因为假服务器的证书是自签的，真服务器不用），22 项全过：

| 场景 | 结果 |
|---|---|
| A. 本机经 HTTP 代理 `CONNECT`，客户端信任 Baobox 的 CA | 客户端拿到 `Baobox Capture CA` 签的证书、对话完整；TCP 页**一条**连接、XMPP、「已解密 · chat.example.test · TLS 1.2」；8 段：线前 5 段明文（`<?xml…>` 21B、stream 头 122B、features、`<starttls/>`、`<proceed/>`），线后 3 段解密后的 XMPP（`secret-from-client` / `secret-from-server` 都在）；HTTP 页没有这个域名的行 |
| E1. 模拟器经 WireGuard（`app_process` 跑一个 Java 客户端，连 `192.168.0.9:19680`），信任 Baobox 的 CA | 客户端 TLSv1.3、证书是 Baobox 的；这一行「已解密」，设备是模拟器那台 WireGuard 设备、来源 `10.0.0.1` |
| C. 关「解密 HTTPS」 | 不接管，客户端和真服务器握手成功；「未解密」`decrypt_off`，线后是密文（首字节 `0x16`） |
| D. 解密范围只有 `other.test` | 不接管，`out_of_scope` |
| B. 本机客户端只信任服务器自己的证书（模拟不信任 Baobox 的手机） | 第一次：被接管、客户端拒绝证书，这一行「未解密」`handshake_failed`、以出错结束、线在最后；第二次：原样放行，客户端和真服务器握手成功，这一行 `handshake_failed`、线后的密文照样记了字节 |
| E2. 本机刚对这个域名失败过，模拟器再连（信任 Baobox） | 照样解密（失败表按设备记） |
| E3. 模拟器只信任服务器证书 | 第一次失败、第二次放行，和 B 一样 |
| F. 本机经 SOCKS 连 | 不接管（普通 TCP 行，没有 TLS 标签），客户端直接和服务器握手 |
| MCP | `list_tcp_connections protocol=xmpp` 每行带 `tls=decrypted` / `tls=failed(decrypt_off)` / `tls=failed(out_of_scope)` / `tls=failed(handshake_failed)`，经 SOCKS 那条没有；`get_tcp_connection` 有 `TLS: decrypted · chat.example.test · TLS 1.2` 和 `-- TLS taken over at <proceed/>: decrypted data below (chat.example.test · TLS 1.2) --`，线前 4 块、线后 3 块 |

（本机的 Python 只会 TLS 1.2，所以本机那几条写的是 TLS 1.2；模拟器的客户端是 1.3。）

**单元测试**（`StartTLSTests` 9 个）：`tcp_tls` 解析（解开、四种原因、缺字段跳过、认不出的原因当没有）；`TCPLog`：明文 4 段 + 解密 3 段是一行、线在第 4 段后、XMPP 照样认得出；放行的连接线后照样记密文字节；被拒的那条线在最后；别的连接没有标记；合块不跨线、偏移照样累计；TLS 版本显示。

**界面**（渲染探针，中英文各 6 张）：列表里「已解密」「未解密」标签（只在 XMPP STARTTLS 连接上）；解开的详情（线前明文、分隔线「以下是 TLS 解密后的内容 · chat.coffeemeetsbagel.com · TLS 1.3」、线后解密内容）；手机不信任证书后放行的那条（顶上提示 + 「以下是 TLS 密文（没解密）」+ 密文）；被拒的那次（出错、线在最后、错误原文）；「解密 HTTPS」关着；不在范围；900 宽。

**没验证的**：真的 Smack（CMB Android staging 包）和 XMPPFramework（iPhone）；真服务器 `chat.coffeemeetsbagel.com:5222`（这台 Mac 不能替用户连生产聊天服务）。
