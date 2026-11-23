# 握手失败自动放行：按「设备 + 域名 + 客户端指纹」记（方案）

## 0. 用户要的是什么（原话，2026-11-22）

手机经手动代理打开 apple.com，第一次报「your connection is not private」，刷新后正常 —— 这是「握手失败的域名自动放行」。讨论时用户指出：

> 但是对于android设备，你不是说浏览器是默认新人用户证书，app可能默认不信任吗？如果按域名会不会出现不一致

先做了真机测试（§2），通过后用户回「按你的建议吧」。

## 1. 问题

桥现在把握手失败记成（设备，域名）：`tls_failed_client` 往 `self.failed` 里加 `(ip, sni)`，之后 `tls_clienthello` 见到同一对就 `ignore_connection`。

Android 上装了 Baobox 证书后，浏览器信任它、大多数 App 不信任。同一个域名浏览器和 App 都访问时，结果取决于谁先来：

- App 先来：App 握手失败 → 域名被记成放行 → 浏览器访问同一个域名也只能放行，本来解得开的没解。
- 浏览器先来：浏览器解得开；App 一来失败一次（App 报一次网络错误）→ 域名被记成放行 → 之后浏览器也不解了。

「按设备判断信不信任证书」也不行：证书页的检测在浏览器里跑，浏览器信任 ≠ App 信任。

## 2. 真机测试（2026-11-22，用户的 vivo V2502A，Android 17）

做法：包里的 mitmdump 起在 `127.0.0.1:19780`，插件只读 ClientHello、`ignore_connection`（不解密、不弹警告）；`adb reverse` + `settings put global http_proxy` 把手机的系统代理经 USB 指过来；adb 依次打开 Brave / Chrome / vivo 浏览器（每个地址打开两次，中间 `am force-stop`）、启动 CMB App（正式包 10.12.0）两次。测完代理恢复成未设置、删掉端口转发和记录。

指纹 = 排序后的加密套件 + 排序后的扩展类型 + ALPN，去掉 GREASE、`padding`(21)、`pre_shared_key`(41)、`early_data`(42)，取 SHA-256 前 12 位。

同一个域名 `api.prod.cmbww.io` 上：

| 谁 | 指纹 | 次数 |
|---|---|---|
| CMB App（两次启动） | `44be627b2e8a` | 6 次都一样 |
| Brave（两次） | `b427498e5ec2` | 一样 |
| vivo 浏览器（两次） | `b427498e5ec2` | 和 Brave 相同 |
| Chrome（两次） | `56a903b8f83f` | 一样 |

- 稳定：Chromium 系每条连接的扩展顺序都是随机的（Brave / vivo 浏览器 186 条连接 186 种顺序），排序后指纹不变；会话恢复（带 `pre_shared_key`）的连接指纹也不变。
- 种类少：整台手机 630 次握手（含后台流量）只有 10 种指纹。
- 限制（写进文档、不解决）：
  - 指纹对应 TLS 库，不是 App：走 Android 默认网络库的 App 共用一个（CMB 与 vivo 自带的一些 App 都是 `44be…`）；一个 App 里也可能有两种（CMB 自己的接口 `44be…`，里面 Firebase / Facebook / Braze 等 SDK 是 `1321a7c074fb`）。
  - App 里的 WebView 和浏览器共用一个指纹（vivo 自家服务、微信相关的一些域名也是 `b427…`），而 WebView 按 App 自己的信任设置走。同一个域名浏览器访问、App 内嵌网页也访问时仍会互相影响，只是范围比按域名小得多。
  - 微信不走系统代理，这次没测到（经 WireGuard 会进来；不影响结论）。
  - **iOS 上基本区分不开**（2026-11-22 装上新版后用户的 iPhone 实测，iOS 27.2.1，经手动代理）：Safari 和系统服务、大多数 App 都用系统自带的网络库，指纹相同，按指纹分开记在 iOS 上起不了多大作用。实测中，同一次 Safari 打开 apple.com 首页，`securemetrics.apple.com`、`pancake.apple.com` 都解开了，`www.apple.com` 本身却记成「这台设备拒绝了抓包证书」被放行（13:59:59.217）。原因没能分清：可能是 Safari 对 www.apple.com 有额外的校验，也可能是共用同一指纹的系统服务先连过它并失败了。Safari 打开 CMB 接口 `api.prod.cmbww.io` 照常解开（`GET 401`）。
  - 失败表只增不减（直到引擎重启）；握手中途断开（不一定是不信任证书，例如网络抖动）也会记成放行。这是原有的「握手失败自动放行」策略，这次不改（独立审查 #11）。**2026-11-23 起改了，见 §7。**

本机预检：curl（LibreSSL）与 Python（OpenSSL）访问同一个域名，指纹不同，各自两次相同。

## 3. 做法

### 3.1 指纹

- 桥里一个纯函数 `client_fingerprint(client_hello)`：按 §2 的规则算。`ClientHello` 的 `cipher_suites`、`extensions`（`(类型, 数据)` 列表）、`alpn_protocols` 在包里的 mitmproxy 12.3.1 上实测可用。
- GREASE 值：`0x0a0a, 0x1a1a, … 0xfafa`（16 个）。

### 3.2 失败表

- 键从 `(ip, sni)` 改成 `(设备, sni, 指纹)`。设备沿用现在桥里认设备的方式（多设备之后隧道设备按 WireGuard 设备 id，见 `WIREGUARD-DEVICES.md`）。
- `tls_clienthello` 算出指纹，查表；同时把指纹记在这条客户端连接上（按连接对象或其 id 存一个小字典，连接结束清掉），`tls_failed_client` 取出来写表。取不到指纹（异常情况）就退回只按（设备，域名）记，保证不比现在差。
- `report_tls` 的去重键里也带上指纹：同一个域名，浏览器那类解开了、App 那类失败了，失败的原因照样报一次。
- 界面、事件格式、MCP 不变。

### 3.3 STARTTLS 跟着改

`STARTTLS.md` §3.1 原写「在看到 `<proceed/>` 那一刻决定接不接管」，那时还没有握手包、算不出指纹。改成：

- 看到 `<proceed/>` 后，前两个条件（解密开关、解密范围）不满足 → 照旧不接管、继续原样转发并记字节。
- 满足 → 先缓存客户端接下来的数据，直到凑齐一个完整的 ClientHello（用 mitmproxy 自带的 ClientHello 解析：数据不完整就继续等，不是 TLS 就按不接管处理），算指纹、查失败表：
  - 没失败过 → 把缓存的数据连同连接交给 `NextLayer`（接管）；
  - 失败过 → 把缓存的数据原样发给服务器，继续原样转发并记字节（不接管）。
- 失败表和 HTTPS 共用一张、同一个键。

### 3.4 文档

- `STARTTLS.md` §3.1 改成上面的做法；`CONTROL.md` 里讲「握手失败自动放行」的地方补一句按指纹记和 §2 的限制。

## 4. 做完的标准

1. 本机真引擎 + 真桥脚本（端口 196xx）：
   - HTTPS：同一个域名，先让「不信任 Baobox CA 的客户端」（如不带 CA 的 curl）失败一次，再让「信任的客户端」（如带 `cafile` 的 Python）访问 → 后者仍被解密；不信任的那个第二次访问被原样放行。反过来的顺序也测一遍。
   - STARTTLS：用 `STARTTLS.md` §2 的假服务器，两种客户端同样各测一遍（信任的仍解密、不信任的第二次原样转发且照样记字节）。
2. 指纹函数在桥脚本里有自检（固定的 ClientHello 字节 → 固定指纹；同一组扩展换顺序 → 指纹不变；加 GREASE / padding / pre_shared_key → 指纹不变）。桥脚本没有现成的测试框架，就写成一个能单独跑的小脚本放在 `mac/Tests/NetCapture/` 旁边并在汇报里贴运行输出。
3. 测试、`make build`、xcstrings 全过；只做本地提交。

## 5. 实现时和方案不一样的地方（2026-11-22）

用户看得见的行为照上面做了；下面是方案没写到、或者写法和实际做法不一样的地方。

| # | 方案原写法 | 实际做法 | 为什么 |
|---|---|---|---|
| 1 | `report_tls` 的去重键里带上指纹 | 只有「握手失败」这一种原因带指纹；「关了解密」「不在范围」照旧按（设备，域名，原因）去重 | 后两种和客户端是谁无关，带上指纹只会让同一个域名多出几行一样的「没解密」 |
| 2 | 取不到指纹就退回按（设备，域名）记 | 记成（设备，域名，`None`），查表时这种条目对这台设备这个域名的所有指纹都算数 | 同方案，记一下怎么落地的 |
| 3 | STARTTLS 等到完整的 ClientHello | 攒超过 64 KB 还不是完整的 ClientHello、或者第一个字节就不是 TLS 握手（`0x16`），按不接管处理，攒着的数据原样发出、照样记字节；这种情况不发 `tcp_tls`（不是 TLS，没有「解没解密」可说） | 防止一直攒着不放 |
| 4 | 指纹自检「写成一个能单独跑的小脚本」 | `mac/Tests/NetCapture/bridge_fingerprint_selftest.py`：在包里的 mitmdump 里跑（`mitmdump -q --set server=false -s …`），直接载入真的桥脚本、用引擎自己的 ClientHello 解析，10 项检查，打印 `SELFTEST OK` | 桥脚本只在引擎里跑，系统的 Python 没有 mitmproxy |
| 5 | 没写 | 指纹按连接记在桥里一个小字典（键是客户端连接的 id），`client_disconnected` 时清掉；STARTTLS 的指纹记在那条连接自己的状态上 | 同方案的「按连接对象或其 id 存一个小字典」 |

## 6. 验证记录（2026-11-22）

**指纹自检**（`bridge_fingerprint_selftest.py`，包里的 mitmproxy 12.3.1）：

```
PASS fixed ClientHello bytes -> fixed fingerprint  c30b9fb4aff8 / by hand c30b9fb4aff8 / pinned c30b9fb4aff8
PASS same extensions in another order -> same fingerprint
PASS same cipher suites in another order -> same fingerprint
PASS GREASE, padding, early_data, pre_shared_key added -> same fingerprint
PASS another server name -> same fingerprint (the library, not the host)
PASS without ALPN -> different
PASS other ALPN -> different
PASS other cipher suites -> different
PASS one more extension type -> different
PASS incomplete record -> parser asks for more
SELFTEST OK (10 checks)
```

**真引擎 + 真桥脚本**（同 `WIREGUARD-DEVICES.md` §11 的宿主程序，代理 19640；两种客户端用同一个 Python、ClientHello 不同 —— 一个带 ALPN、一个不带 —— 代表同一台手机上的两个 TLS 库；「不信任 Baobox」的那个只信任源站自己的证书），16 项全过：

| 场景 | 结果 |
|---|---|
| HTTPS 顺序一：不信任的先来 | 第一次握手失败；随后信任的那个访问同一个域名**照样解密**（HTTP 页里是解开的请求）；不信任的第二次原样放行到源站（看到的是源站自己的证书），列表里不多一行 |
| HTTPS 顺序二：信任的先来 | 解密；不信任的失败一次、第二次放行；信任的那个之后**仍然解密** |
| HTTP 页的「没解密」行 | 每个域名只有一行「握手失败」（不信任的那个客户端的） |
| STARTTLS 顺序一（假 XMPP 服务器） | 不信任的：被接管、拒绝证书、这一行「未解密」；信任的同一个域名：**照样解密**；不信任的再来：原样放行，ClientHello 和之后的密文都记在线后（2010 字节，首字节 `0x16`） |
| STARTTLS 顺序二（另一个域名） | 信任的先来解密；不信任的失败一次、再来放行并记字节；信任的仍解密 |
| 关「解密 HTTPS」 | `<proceed/>` 那一刻就不接管（`decrypt_off`），不等 ClientHello |

另外把 `STARTTLS.md` §7 的整套场景（含模拟器经 WireGuard）在改过的桥上重跑一遍，22 项全过（同一个客户端失败后重连照样放行；本机失败不影响模拟器）。

**没验证的**：用户真机上浏览器和 App 同时访问同一个域名（方案 §2 的数据是只读 ClientHello 的探针，不是这一版的桥）。

## 7. 放行记录什么时候作废（2026-11-23）

### 7.1 用户遇到的事

iPhone 先连上 WireGuard、后装证书：装好之前 CMB App 连 `api.prod.cmbww.io` 握手失败，（这台设备，这个域名，CMB 那类连接的指纹）被记成放行。证书装好、信任之后：

- 重启 App 多少次都还是放行 —— 失败表在引擎里，只有引擎重启才清；
- 列表里连「没解密」那一行都没有 —— 那一行在一次引擎运行里只报一次，用户中途清空过列表，之后这个域名就什么都不显示，看起来像「完全抓不到」；
- 最后是 Baobox 里一次开关（引擎重启，14:07:01）把表清了才好。

佐证（抓包记录）：14:04 起同一台的 XMPP 已经解开，14:06:30 同一个 App 的 `cdn.prod.cmbww.io` 也解开了，只有 `api.prod.cmbww.io` 一直没有任何一行。

### 7.2 改法

1. **第一次握手成功，作废之前的失败**：同一台设备、同一个客户端指纹第一次和引擎握手成功（`tls_established_client`，含 STARTTLS 接管），说明这类客户端现在信任 Baobox 证书了：失败表里这台设备、这个指纹的条目全部删掉（连同「已报告」里对应的「握手失败」，之后再失败会重新出一行）。**每次引擎运行、每个（设备，指纹）只做一次** —— iOS 上 Safari、系统服务、大多数 App 共用一个指纹，iCloud 这类本来就不接受抓包证书的系统服务如果每次有人握手成功都被重新拦一次，会反复断；只做一次，它们最多再失败一次、重新记上，之后不再动。指纹取不到（`None`）的条目不动。
2. **清空列表 = 重新报告**：清空 HTTP 列表（工具条按钮、MCP `clear_flows`）时桥的「已报告」整个清掉；「清空这台设备的包」只清这台的。之后被放行的域名再来流量，会重新出一行「没解密」。失败表不动（清空列表不等于证书变了）。
3. **手动重试**：「没解密 · 握手失败」那一行右键、或详情里，「重新尝试解密」：删掉这台设备、这个域名在失败表里的所有条目（不分指纹）和「已报告」里这个域名的记录。下一条连接重新接管；还是不信任就再失败一次、重新记上并出一行。
4. 新增两条桥指令：`{"cmd":"forget_reported","device":<设备键或省略>}`、`{"cmd":"retry_decrypt","device":<设备键>,"host":<域名>}`。

### 7.3 引擎停了，进行中的行跟着结束

同一次用户还看到：14:06:10 那条 XMPP 连接一直显示「进行中」。它建在 14:07:01 引擎重启之前 —— 旧引擎被结束时来不及发 `tcp_close`，Baobox 这边就一直当它开着。

改成：引擎停止、换监听重启、意外退出时，TCP 页里还开着的连接一律标成「已关闭」，结束时间是那一刻，错误一栏写「抓包引擎停了（重启或关闭），这条连接随之断开」；HTTP 页里还没等到响应的请求同样补上结束时间和这句说明。手机那边的连接确实也断了（隧道里的另一端没了），会自己重连成新的一行。

### 7.4 验证（2026-11-23）

- **真引擎 + 改过的桥**：`mac/Tests/NetCapture/bridge_passthrough_e2e.py`（包里的 mitmproxy 12.3.1，本机假 HTTPS 源站在 19661、代理 19660；两个客户端 ClientHello 相同、只差信不信任 Baobox 证书），19 项全过：不信任的先失败、被放行 → 信任的在别的域名第一次解开 → 原来那个域名重新解开；之后才失败的（像 iCloud）不再被清；`forget_reported` 全部 / 按设备 / 别的设备各一遍；`retry_decrypt` 本设备生效、别的设备不生效、仍不信任时再失败一次并重新出一行。**同一个脚本换成 main 上旧的桥：6 项失败**（正是 §7.1 的现象）。
- 原有的指纹自检 `bridge_fingerprint_selftest.py`：19 项全过。
- 单元测试 684 个全过（新增：`TCPLog.endOpen`、两条新指令的 JSON）。
- **没验证的**：用户 iPhone 上按 §7.1 的顺序重走一遍；「重新尝试解密」按钮、引擎重启后 TCP 行变「已关闭」在真窗口里点一遍。
