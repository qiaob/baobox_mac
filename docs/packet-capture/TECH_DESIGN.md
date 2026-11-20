# 网络抓包 — 技术方案

> 版本：v2.0（2026-11-20）。配套 `REQUIREMENTS.md` v2.0。
> 取代 `TECH_DESIGN_V1.md`（自研 Network.framework 内核）。v1 里留用的部分在 §8 逐个列出。

## 0. 一句话

开始抓包时，Baobox 启动包内的 `mitmdump`，带一个自己写的 Python 插件（下称「桥」）。桥把每条请求从标准输出一行一个 JSON 推给 Baobox，Baobox 从标准输入给它发指令。界面、证书安装、系统代理、手机配置页、ADB、MCP 都在 Swift 这边。

```
Baobox（Swift）                              mitmdump（子进程）
┌────────────────────────┐   stdin：指令    ┌──────────────────────┐
│ NetCaptureEngine       │ ───────────────▶ │ baobox_bridge.py     │
│  ├ 进程管理            │ ◀─────────────── │  ├ 事件：请求/响应/WS │
│  └ 事件解码 → FlowStore│   stdout：事件   │  ├ 解密范围、自动放行 │
│ 窗口 / 菜单 / MCP      │                  │  └ 设备准入          │
└────────────────────────┘                  └──────────────────────┘
                                             ▲ 代理端口（本机或局域网）
                                   Mac / 手机 / 终端的流量
```

## 1. 已用探针确认的事实（2026-11-20，macOS 27.2.1，M3）

写进方案的每一条都实测过，脚本在当时会话的临时目录，没有进仓库。

| 确认了什么 | 结果 |
|---|---|
| 官方包 `mitmproxy-12.3.1-macos-arm64.tar.gz` | 下载 56 MB，解开 88 MB，内容是一个 `mitmproxy.app`；SHA-256 `9b7f7a8e3fd1b1544089c937c579ef1f0f503f0ea598c25bda9eab077c735b93` |
| 签名 | Developer ID（团队 `S8XHQB96PW`）、已公证、Hardened Runtime；自带权利 `allow-jit`、`allow-unsigned-executable-memory`、`disable-library-validation` |
| 嵌进 `Baobox.app/Contents/Helpers/` | 不动它的签名，只重签外层。ad-hoc 与 Apple Development 两种身份下，外层 `codesign --verify --deep --strict` 都通过，包内的 `mitmdump` 能运行 |
| 启动与占用 | 约 1 秒就绪；空载常驻 101 MB |
| 协议 | 经代理访问：HTTPS + HTTP/2、HTTPS + HTTP/1.1、明文 HTTP 都被解开并推出事件 |
| 正文 | `flow.response.content` 已自动解压（gzip 的响应拿到的是明文长度） |
| 进行中事件 | `request` 钩子先于 `response` 触发，id 相同 |
| 指令通道 | 桥在一个普通线程里读标准输入，指令即时生效；关闭标准输入或发 `shutdown`，引擎 0.13 秒内退出；`SIGTERM` 约 0.3 秒退出 |
| 按域名放行 | `tls_clienthello` 里设 `ignore_connection = True`，这个域名之后不再解密，也不再产生请求事件 |
| 握手失败 | 不信任 CA 的客户端连上来，`tls_failed_client` 触发并给出域名 |
| 只生成 CA | 带一个让桥就绪后立刻退出的选项，1.2 秒生成全套证书文件；私钥文件权限 600 |

**没有走通的一条**：用 asyncio 的 `connect_read_pipe` 读标准输入，在命名管道上收不到「对端关闭」。所以桥用线程读（上表验证过的那种），不用 asyncio 管道。

**实现后又确认的**（2026-11-21，把真实源码编进临时探针跑的）：

| 确认了什么 | 结果 |
|---|---|
| 桥脚本九个场景 | HTTP/2 解密、带正文的 POST、换解密范围后立即不解密、别的域名不受影响、局域网来源先回 403 并只报一次、允许后放行、不信任 CA 的客户端触发握手失败、同一域名再来就放行、超过上限的正文不捕获并标截断 |
| `NetCaptureEngine` 十项 | 启动 0.9–1.5 秒；重复启动被忽略；事件进 `FlowStore`；未解密的域名补一行；带局域网重启 0.4–1 秒；设备待允许与允许；停止后无进程无监听；端口被占报「端口被占用」；引擎被 `kill -9` 后状态变失败并通知场景协调；`terminateNow` 不留进程 |
| 孤儿进程 | 宿主进程被 `kill -9` 后，引擎读到标准输入结束，自己退出 |
| 端口被占时的报错 | `-q` 下引擎把原因打在**标准输出**（不是标准错误），最后才在标准错误写一句「启动出错」。所以读输出时把不带前缀的行也留作错误说明 |
| 配置页服务 | `/` 按 iOS / Android 出不同页面；`/cert` 给 iOS 描述文件（`plutil -lint` 通过）、给 Android PEM；`/proxy` 有 Wi-Fi 名时出描述文件、没有时 302 回首页；未知路径 404；非 GET 405 |
| 合并证书文件 | 系统根证书 151 张 + CA，共 152 张 |
| 系统代理开 / 还原 | 在这台 Mac 上实际走了一遍（解密范围设为空，流量只是穿过引擎）：`scutil --proxy` 显示指向引擎，认系统代理的客户端请求经过了引擎，还原后两项都关闭 |
| 嵌进真实构建 | Debug 构建里 `Helpers/mitmproxy.app`、桥脚本、许可文件齐全，外层 `codesign --verify --deep --strict` 通过，App 155 MB |

**新发现的系统限制**：这台 macOS（27.2.1）上读不到当前 Wi-Fi 名称 —— `networksetup -getairportnetwork`、`ipconfig getsummary`、`system_profiler`、CoreWLAN 都返回空或 `<redacted>`（要定位权限）。iPhone 的代理描述文件按 Wi-Fi 名匹配网络，所以手机面板里加了一个手填 Wi-Fi 名称的输入框（`netcapture.wifiName`）；不填就在手机上手动填代理。

**还没验证的**：

1. **安装并信任 CA**（`security add-trusted-cert` + 管理员密码框）：代码沿用 v1，要用户输密码，没法自动跑。这是「抓这台 Mac」的第一步。
2. iOS 的 Wi-Fi 代理描述文件在非监管设备上是否生效（v1 就标着未验证），要真机。
3. 引擎监听局域网时，系统防火墙会不会弹「是否允许传入连接」。
4. WebSocket 消息：事件解码有单元测试，界面有「消息」页，但没用真实的 WebSocket 连接跑过。
5. 真机手机经代理上网的整条链路（探针里用本机的局域网 IP 冒充了一台设备）。
6. Intel Mac 上的置灰路径（手头没有机器，靠代码审查）。
7. ad-hoc 签名的发布包（探针里验过外层校验，发布工作流没跑过）。

## 2. 引擎怎么带进包里

沿用 llama-server 的做法（`make vendor` 下载，构建时拷进包），有三处不同。

**Makefile**：`vendor` 多一个目标。固定版本号与 SHA-256，下载官方 arm64 包，解到 `Vendor/mitmproxy.noindex/mitmproxy.app`；再从 GitHub 上同一个标签取 `LICENSE`（官方包里没有这个文件），存在旁边。目录名以 `.noindex` 结尾：里面是一个完整的 `.app`，不这样 Spotlight 会把它当成一个应用列出来。升级时版本号和校验值一起改。版本不得低于 12.2.2（更早的有 CVE-2026-40606，虽然只影响用不到的 LDAP 认证）。

**project.yml**：新增构建脚本「Embed mitmproxy」。

- 用 `ditto` 把整个 `mitmproxy.app` 拷到 `Contents/Helpers/mitmproxy.app`。
- **不重新签名，也不删里面任何文件**。它的签名封住了整个包，删掉用不到的 `mitmproxy` / `mitmweb` 可执行文件会让封印失效。这和 llama-server（要用 App 的身份重签）正相反，注释里写明原因。
- `LICENSE` 拷进 `Resources/mitmproxy-LICENSE.txt`。
- 没有 `Vendor/mitmproxy.noindex` 就打一条 warning 跳过，App 照常能编。
- 同时删掉 `sources.excludes` 里的 `Modules/NetCapture`。

**只带 arm64**：Baobox 本身是通用二进制，官方引擎分架构发布，两个都带要多 176 MB。Intel 上 `NetCaptureEnv.engineUnavailable` 返回 `.needsAppleSilicon`，模块显示一行置灰说明。

**桥脚本**：`mac/Sources/Resources/NetCapture/baobox_bridge.py`，按 folder 资源拷进包（同 `Resources/PhoneTransfer` 的做法），启动引擎时用 `-s` 指过去。

**其它要跟着改的**：`release.yml` 与 `build-macos.yml` 已经会跑 `make vendor`，不用改流程，只是多一次下载；`build-macos.yml` 里 vendor 失败时的那句 warning 只提了离线翻译，补上抓包。`Info.plist` 的 `NSLocalNetworkUsageDescription` 补回「网络抓包」。`CLAUDE.md` 技术栈那句的例外从「调用系统 openssl」改成「内置 mitmproxy」，模块表去掉「暂缓」。

## 3. `NetCaptureEngine`（取代 `ProxyServer`）

`@MainActor final class NetCaptureEngine: ObservableObject`，单例（不叫 `CaptureEngine`：截图模块已经有一个同名类型）。对外形状和 `ProxyServer` 一样，界面和 MCP 只需改名：

```swift
enum State: Equatable { case stopped, starting, running(UInt16), failed(String) }
@Published private(set) var state: State
@Published private(set) var lanEnabled: Bool          // 这次运行是否监听局域网
@Published private(set) var pendingDevices: [String]  // 等用户点允许的来源 IP
func start(port: UInt16, lan: Bool)
func restart(port: UInt16, lan: Bool)   // 换端口或监听范围
func stop()
func send(_ command: CaptureCommand)    // 写一行 JSON 到引擎的标准输入
func allow(device:) / deny(device:)
```

**启动参数**：

```
mitmdump --listen-host <127.0.0.1 | 0.0.0.0> -p <端口>
         --set confdir=<支持目录>/mitmproxy
         --set stream_large_bodies=<正文上限>
         -q -s <桥脚本>
```

- `-q` 让引擎自己不往标准输出写东西；桥的每行以 `BAOBOX ` 开头，别的行一律丢弃。
- `stream_large_bodies` 让超过上限的正文直接流过去，不在引擎里攒着；这样的 Flow 标「已截断」。
- `.starting` 到 `.running` 以收到 `running` 事件为准，8 秒没收到算失败。
- 进程退出回调里：不是自己叫停的，就置 `.failed`，并让 `SystemProxyController` 还原系统代理。
- 重入：`.starting` 与 `.running` 时再调 `start` 直接返回（v1 这里有竞态，见 v1 §18.4 第 7 条）。
- 改端口或切换是否监听局域网 = 停了再起，约 1 秒。

**读输出**：`FileHandle.readabilityHandler` 在后台队列按行切，解码成 `CaptureEvent`，攒成一批回主线程写 `FlowStore`（约定 1：`@Published` 只在主线程写）。攒批不用定时器：主线程还没取走上一批时，新事件接着往同一批里放，流量大时自然合并。不带前缀的行是引擎自己的日志，留最后 4 KB 给异常退出时说明原因。

**停止**：发 `shutdown`，1 秒没退就 `terminate()`。Baobox 崩溃时管道关闭，桥读到结束自己退出，不会留孤儿进程。

## 4. 桥脚本（`baobox_bridge.py`，约 250 行）

只用 mitmproxy 官方的 addon 接口，不碰 mitmweb 的网页接口（那个没有文档，版本之间会变）。

### 4.1 事件（引擎 → Baobox）

每行 `BAOBOX <JSON>`。正文用 base64 放在事件里，不落盘。

| `event` | 时机 | 主要字段 |
|---|---|---|
| `running` | 就绪 | `version` |
| `request` | 请求头和正文到齐 | `id`、`client`（来源 IP）、`method`、`scheme`、`host`、`port`、`path`、`http`、`headers`、`body`、`truncated`、`ts` |
| `response` | 响应到齐 | `id`、`status`、`headers`、`body`（已解压）、`encoding`（原始编码，仅展示）、`truncated`、`remote`、`ts`、`bytes` |
| `error` | 请求失败 | `id`、`message` |
| `ws` | 一条 WebSocket 消息 | `id`、`from_client`、`text` 或 `size`、`ts` |
| `tls` | 一个域名改为不解密 | `host`、`client`、`reason`（`handshake_failed` / `out_of_scope`） |
| `device` | 一个新的来源 IP 在等允许 | `client` |

### 4.2 指令（Baobox → 引擎）

| `cmd` | 作用 |
|---|---|
| `scope` | 换解密范围：`mode`（`all` / `allow` / `deny`）+ `domains` |
| `allow_device` / `deny_device` | 放行或拒绝一个来源 IP |
| `shutdown` | 退出 |

第二版在这张表上加 `resume`、`kill`、`replay`、`rules`，不改通道。

### 4.3 桥里的三段逻辑

- **解密范围与自动放行**：在 `tls_clienthello` 里按 SNI 判断。不在范围内，或这个域名在本次抓包里握手失败过，就设 `ignore_connection`。`tls_failed_client` 把域名记进「失败过」的集合并发 `tls` 事件。域名按后缀匹配（`x.com` 匹配 `api.x.com`）。
- **设备准入**：回环地址直接放行。别的来源 IP 第一次出现时发 `device` 事件；被允许之前，它的请求一律回一个 403 页面（「请在 Mac 上允许这台设备」），CONNECT 直接断开。允许名单只在本次抓包里有效，不存盘。
- **读指令**：`running()` 里起一个守护线程逐行读标准输入，经 `loop.call_soon_threadsafe` 回到事件循环处理；读到结束就 `ctx.master.shutdown()`。

## 5. 证书（`CaptureCA`，取代 `MITMCertAuthority`）

- CA 由 mitmproxy 生成，放在 `~/Library/Application Support/Baobox/NetCapture/mitmproxy/`。公开证书是 `mitmproxy-ca-cert.pem`，带私钥的是 `mitmproxy-ca.pem`（600）。
- **还没抓过包就要装证书**：用 `-n` 加桥的 `baobox_oneshot` 选项跑一次引擎，就绪即退，约 1.2 秒。
- 安装并信任、查询状态、移除：沿用 v1 的实现，只换路径。
- 叶子证书的签发、openssl 子进程、p12 口令这些全部删掉，`NetCaptureEnv.opensslPath()` 一并删。
- **迁移**：启动时如果旧目录 `NetCapture/ca/` 还在，移除旧 CA（`Baobox Proxy CA`）的信任，再删 `ca/` 与 `leaf/` 两个目录。只有 2026-07 用过开发版的机器会走到。
- **已知的表面问题**：证书在设备上显示的名字是「mitmproxy」，不是 Baobox。mitmproxy 支持换成自备的 CA，这一版不做。

## 6. 五个场景各自怎么实现

`NetCaptureSession`（`@MainActor`，单例）：窗口、菜单、MCP 都从它进。「这台 Mac」和「手机」是两个开关（`macCaptureOn`、`phonePageOn`），终端和模拟器是一次性动作；每个都先确保引擎在跑。上次是否在抓这台 Mac 存 `netcapture.lastMacCapture`，窗口上的「开始」照它来（第一次默认是）。MCP 的 `start_capture` 不弹密码框：证书已受信才指系统代理，否则只起引擎。

| 场景 | 开 | 关 |
|---|---|---|
| 这台 Mac | `SystemProxyController.enable`（v1 现成，含崩溃后还原）；CA 未受信就调安装 | `restore()` |
| 终端 / 脚本 | 生成合并证书文件（系统根证书 + CA，见下），经 `TerminalLauncher.run` 开一个会话，先 `export` 再进用户的 shell | 无（关掉那个终端即可） |
| iPhone / iPad | 引擎以 `lan: true` 运行（已在跑就重启一次）；起配置页服务（§7）；显示二维码 | 停配置页服务，引擎改回只听本机 |
| Android | 同上；有 adb 设备时用 `ADBController`（v1 现成）设代理、推证书 | `ADBController` 清代理 |
| 模拟器 | iOS：`xcrun simctl keychain booted add-root-cert <pem>`，并确保「这台 Mac」开着。Android 模拟器（序列号以 `emulator-` 开头）：设代理到 `10.0.2.2:<端口>`、推证书 | Android 模拟器清代理 |

**终端的环境变量**：`HTTP_PROXY`、`HTTPS_PROXY`、`http_proxy`、`https_proxy`（都是 `http://127.0.0.1:<端口>`），`SSL_CERT_FILE`、`REQUESTS_CA_BUNDLE`、`CURL_CA_BUNDLE`、`NODE_EXTRA_CA_CERTS`（都指向合并证书文件）。

**合并证书文件**：只给 CA 一张证书的话，被放行（未解密）的域名在终端里会校验失败，所以要把系统根证书也放进去。用 `security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain` 导出，后面接上 CA，写到支持目录的 `ca-bundle.pem`。在后台队列做（约定：`Process` 不在主线程等）。

**没有 adb / 没有已启动的模拟器**：按钮置灰并给一行怎么办（约定 7）。

## 7. 手机配置页

v1 靠代理拦截 `baobox.proxy` 这个域名来给页面，手机必须先设好代理才打得开。v2 改成 Baobox 自己在局域网起一个小 HTTP 服务：

- `NWListener`，端口 = 代理端口 + 1，只在有手机场景时开。
- 四个 GET 路由，精确匹配（v1 是子串匹配）：`/`（配置页）、`/cert`、`/proxy`、`/proxy-off`。内容生成全部沿用 `MobileConfigBuilder`，只是 CA 路径换成 §5 的。
- 二维码编码 `http://<Mac 的局域网 IP>:<端口>/`。
- 这个服务只发公开证书和描述文件，不涉及抓到的内容，所以不做设备准入。

## 8. v1 的代码：删什么、留什么

| 文件 | 处理 |
|---|---|
| `ProxyServer.swift`、`ProxyConnection.swift` | 删。`NetCaptureEngine` 取代 |
| `MITMCertAuthority.swift` | 删签发部分，信任相关的搬进 `CaptureCA.swift` |
| `HTTPMessage.swift` | 整个删掉。解析器不再需要；`HTTPBodyCodec` 的解压也不再需要（引擎给的已是明文），按 Content-Type 判断怎么展示的那几行在详情视图里 |
| `FlowStore.swift` | 留。`append` 换成 `apply(_ events:)`（请求先到占一行、响应到了补全，一批只重算一次）；加 WebSocket 消息与按域名分组；`Flow` 加 `httpVersion`、`messages`、`undecryptedReason`、`responseEncoding`。`HTTPHeader` 搬到 `Logic/CaptureEvent.swift` |
| `NetCaptureWindow.swift` | 改成三栏，设备 Tab 条换成左栏；加空状态的五张卡片、待允许设备的提示条、WebSocket 消息页 |
| `NetCaptureTool.swift` | 留。二级菜单从 v1 的八九项减到「打开抓包窗口」一项，正在抓时多一行状态和「停止抓包」（需求 §5.2）；证书、二维码、ADB、MCP 那些菜单项和 `NetCaptureCertQR` 小窗删掉，功能都在主窗口里。`ProxyServer` 改 `NetCaptureEngine` |
| `NetCaptureSettingsView.swift` | 留，按需求 §5.3 调整 |
| `SystemProxyController.swift`、`ADBController.swift`、`MobileConfigBuilder.swift`、`NetworkInterfaces+NetCapture.swift` | 留，基本不动 |
| `CaptureMCPServer.swift` | 留，9 个工具不变；三处 `ProxyServer.shared` 改 `NetCaptureEngine.shared` |
| `NetCaptureEnv.swift` | 留；删 openssl 相关，加引擎路径与可用性判断 |

新增：`NetCaptureEngine.swift`、`NetCaptureSession.swift`（场景协调）、`CaptureCA.swift`、`ConfigPageServer.swift`、`Logic/CaptureEvent.swift`（事件解码、切行、`HTTPHeader`）、`Logic/CaptureCommand.swift`（指令、解密范围、终端环境变量）、`Resources/NetCapture/baobox_bridge.py`。

**测试**：`Logic/` 只依赖 Foundation，进 `BaoboxTests.sources`，`Tests/NetCapture/CaptureEventTests.swift` 15 个用例：事件解码（样本取自真引擎的输出；缺字段、类型不符只跳过，约定 5）、几 MB 的长行分段到达、指令编码、域名清洗、设置到解密范围的映射、终端环境变量的引号。域名后缀匹配在桥脚本里（Python），没有单元测试，靠 §1 那张表的九个场景。

## 9. 风险

| 风险 | 处理 |
|---|---|
| 包大了 88 MB | 用户已接受（2026-11-20 选了打进包） |
| mitmproxy 升级改了钩子名或事件字段 | 版本固定；桥只用文档里的公开钩子；升级时跑一遍冒烟 |
| 引擎常驻 100 MB，高于 v1 的目标 | 只在抓包时存在；需求 §6 已改口径 |
| 系统代理指着一个已经没了的端口，整机断网 | 引擎退出回调里还原；Baobox 启动时兜底还原（v1 现成） |
| 局域网里别人把这台 Mac 当代理用 | 默认只听本机；开了局域网也要逐台设备允许 |
| ad-hoc 发布包里嵌着别人签名的代码 | 探针里外层校验通过；发布工作流跑通后再用 `spctl` 核一次 |

## 10. 分步落地

原计划每一步一个 PR。实际上（用户 2026-11-21：「先做出来，我再看」）第 1–4 步和第 5 步的大部分在一个分支里一起做完了，下面保留原来的划分作为验收清单。

1. **引擎进包 + 能抓 Mac**：Makefile、project.yml、桥（事件 + `shutdown`）、`CaptureEngine`、`CaptureCA`、删 v1 内核、`FlowStore.upsert`。界面先沿用 v1 的两栏。验收：点开始，Safari 和 `curl` 的 HTTPS 明文进列表；停止后没有 `mitmdump` 进程、系统代理还原。
2. **三栏窗口 + 五张卡片 + 终端与模拟器场景**。
3. **手机**：局域网监听、设备准入、配置页服务、ADB。先做 iOS 描述文件的真机探针。
4. **协议与范围**：HTTP/2 标记、WebSocket 消息页、解密范围、握手失败自动放行的展示。
5. **收尾**：MCP 改接、HAR 与 cURL 核对、`docs/manual/network-capture.md`、`CLAUDE.md`、设置页。（手册页还没写，等用户看过界面再写。）

第二版（改写、断点、重发）另开文档增量。
