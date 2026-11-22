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
- STARTTLS 层在**看到 `<proceed/>` 那一刻**决定接不接管，接管的条件：
  1. 「解密 HTTPS」开着；
  2. 域名在解密范围内 —— 域名取客户端 stream 头里的 `to='…'`（截图里就是 `chat.coffeemeetsbagel.com`，和随后 ClientHello 的 SNI 一致）；
  3. 这台设备 + 这个域名之前没有握手失败过。
- 不接管：STARTTLS 层继续原样转发、照样记字节（就是现在看到的密文），并像 HTTP 页那样报一次「没解密」的原因（关着 / 不在范围 / 握手失败）。
- 接管后手机拒绝证书：现有的 `tls_failed_client` 把（设备，域名）记进失败表，这条连接断掉；客户端重连时第 3 条不满足，原样放行。和 HTTPS 的「握手失败自动放行」是同一张表。

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
