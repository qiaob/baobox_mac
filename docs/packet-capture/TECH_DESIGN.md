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

**Android 模拟器上的端到端验证**（2026-11-21，Android 15 `google_apis_playstore` arm64 镜像，新建的 AVD `baobox_capture_test`，无 root；引擎由一个用真实源码编的小宿主程序拉起）：

| 步骤 | 结果 |
|---|---|
| `ADBController` 找 adb、列设备 | adb 不在 PATH 里也找到了（`~/Library/Android/sdk/platform-tools`），列出 `emulator-5554` |
| 设代理 `10.0.2.2:<端口>` | `settings get global http_proxy` 读回一致；清除后读回 `:0` |
| 推证书 | 文件进了 `/sdcard/Download/baobox-ca.crt` |
| v1 的「拉起安装界面」 | **失败**：VIEW + `file://` 提示「无法读取证书文件」；从系统证书安装器里选文件则提示「CA 证书必须在设置里安装」。已改成推完直接打开「更多安全和隐私」页（见 `ADBController.pushAndInstallCert` 的注释） |
| 在设置里装证书 | 更多安全和隐私 → 加密与凭据 → 安装证书 → CA 证书 → 仍然安装 → 选文件：装上了，出现在「信任的凭据 → 用户」里，名字是 mitmproxy。不需要先设锁屏密码 |
| Chrome 的 HTTPS | 解开了，HTTP/2，正文可见；Chrome 地址栏显示「连接是安全的」 |
| WebSocket | Chrome 打开一个 WebSocket 回显页：101 握手进列表，收发的文本消息逐条记到那条 Flow 上 |
| 不信任用户证书的 App | 系统自带的 Google 服务（29 个域名）握手失败 → 自动放行 → 列表里标「未解密」，模拟器照常联网 |
| 来源 | 模拟器经 `10.0.2.2` 连过来，引擎看到的来源是 `127.0.0.1`：它的流量显示在「本机」下，不单独成一台设备，也不走设备准入 |

**iOS 模拟器上的端到端验证**（2026-11-21，iOS 18.3.1 运行时，iPhone 16，无界面启动；同一个宿主程序）：

| 步骤 | 结果 |
|---|---|
| 装证书之前，Safari 打开一个 HTTPS 页 | 握手失败 → 自动放行 → 标「未解密」 |
| `CaptureCA.installIntoBootedSimulators()` | 成功 |
| 系统代理指向引擎（`SystemProxyController`），Safari 打开 HTTPS 页 | 解开了，HTTP/2，UA 是 iPhone，正文可见 |
| 还原系统代理 | `scutil --proxy` 两项都关，直连正常 |
| 来源 | 和 Android 模拟器一样显示在「本机」下（模拟器用的就是这台 Mac 的网络和系统代理） |
| **WebSocket** | 只设 HTTP 代理时**没抓到**；补了 SOCKS 之后抓到了，见下 |

**苹果平台的 WebSocket 不走 HTTP 代理，只走 SOCKS 代理**（2026-11-21 实测）。只设系统的 HTTP / HTTPS 代理时，模拟器里 Safari 的 WebSocket 页面照常工作（页面上收发了十几条消息），但没有一条经过引擎，是直连出去的。做了对照实验：引擎加一个 `--mode socks5@<端口>` 的监听，系统只设 SOCKS 代理（HTTP 代理关着），同一个页面的 101 握手和 17 条消息全部抓到。Android 的 Chrome 没有这个问题（上表：经 HTTP 代理就抓到了）。

**已补上 Mac 和模拟器这部分**（用户 2026-11-21：「把 Mac 和模拟器的 WebSocket 补上吧」）：

- 引擎多开一个 SOCKS5 监听，端口 = 代理端口 + 2，**永远只听本机**（`--mode socks5@127.0.0.1:<端口>`）。
- 「这台 Mac」场景把系统的 SOCKS 代理也指过去，停止时和 HTTP / HTTPS 一起还原（`SystemProxyController` 现在管三项；早先存下的状态里没有 SOCKS 那几项，还原时就不碰它）。
- **控制影响面**：系统的 SOCKS 代理一开，所有认它的 App 的 TCP 流量都会进来（邮件、聊天…）。桥脚本对经 SOCKS 进来的连接**只解密 443 端口**，别的端口的 TLS 原样放行、不解密、不进列表。实测：经 SOCKS 访问 `imap.gmail.com:993`，客户端看到的证书仍是 Google 的。
- 端口被占的提示现在说的是实际被占的那个端口（引擎开了两个）。

实测（产品代码，同一个宿主程序）：一个用系统 WebSocket 接口的 Mac 程序连回显服务，101 握手 + 3 条消息（带方向）进了列表；iOS 模拟器里 Safari 的 WebSocket 页面，握手 + 13 条消息进了列表；还原后 `scutil --proxy` 的 HTTP、HTTPS、SOCKS 三项都是关。

**还没做的**：真机 iPhone。它的 Wi-Fi 代理界面只有 HTTP 代理，没有 SOCKS；要走 SOCKS 得用「自动」代理配置（PAC 文件里写 `SOCKS5 …`，描述文件的 `ProxyType` 换成 `Auto`），而且 SOCKS 监听得开到局域网上。没有真机，没验证，所以没动。

**正文压缩**（2026-11-21，用户：「http 流量还有一些是压缩的，我看你没有自动解压」）。头里声明了的 `Content-Encoding`（gzip、deflate、br 实测都解开了）由引擎处理。漏掉的是**正文是压缩的、头里却没声明**的情况 —— 不少 App 和 SDK 把正文 gzip 之后按 `application/octet-stream` 发。现在桥脚本按内容特征认：gzip（`1f 8b`）、zlib（`78 01/5e/9c/da`）、zstd（`28 b5 2f fd`），认出来就解开，事件里带上名字（`sniffed`），详情里标一句「头里没有声明，已自动解压」。解压输出按正文上限封顶（30 MB 的 gzip 炸弹实测只展开到 5 MB 并标截断）；只有魔数对、实际解不开的数据原样不动。brotli 没有魔数，认不出来；头里声明 zstd 的情况没找到会这么回的服务器，没实测。

**新发现的系统限制**：这台 macOS（27.2.1）上读不到当前 Wi-Fi 名称 —— `networksetup -getairportnetwork`、`ipconfig getsummary`、`system_profiler`、CoreWLAN 都返回空或 `<redacted>`（要定位权限）。iPhone 的代理描述文件按 Wi-Fi 名匹配网络，所以手机面板里加了一个手填 Wi-Fi 名称的输入框（`netcapture.wifiName`）；不填就在手机上手动填代理。

**还没验证的**：

1. **安装并信任 CA**：要用户本人验证，没法自动跑。这是「抓这台 Mac」的第一步。v1 的做法（见 §5）在用户第一次试用时就失败了，现在换成用户域，**换完之后还没有成功装上过一次**。
2. iOS 的 Wi-Fi 代理描述文件在非监管设备上是否生效（v1 就标着未验证），要真机。
3. 引擎监听局域网时，系统防火墙会不会弹「是否允许传入连接」。
4. 真机手机经代理上网的整条链路（局域网监听 + 设备准入只用本机的局域网 IP 冒充过一台设备；模拟器走的是回环）。
5. 厂商定制的 Android（MIUI、ColorOS…）上「更多安全和隐私」那个 action 在不在、证书安装的路径叫什么。
6. Intel Mac 上的置灰路径（手头没有机器，靠代码审查）。
7. ad-hoc 签名的发布包（探针里验过外层校验，发布工作流没跑过）。

**第二批（`TOOLS.md`：筛噪音 / 参数分栏 / 重发 / Mock / Protobuf）的验证**（2026-11-21，Swift 侧实现之后）

真引擎：把真实的 `NetCaptureSession`、`NetCaptureEngine`、`FlowStore`、`MockRuleStore`、`NetCaptureEnv`、`NetCaptureReplaySheet` 与 `Logic/` 全部源码编进一个临时宿主程序（假 `.app` 放在 `*.noindex` 目录里，包内引擎是软链接）。唯一改动的是 `NetCaptureEnv.supportDir` 指到会话临时目录（证书、引擎配置、`mock-rules.json` 都不碰用户的支持目录）；`SystemProxyController` 换成只记录调用的桩，全程只用「只起引擎」的路径，**没有改系统代理**（桩的记录为空）。引擎听 19611，源站是本机 19620 上的一个小 Python 服务，`curl -x` 走引擎。

| 场景 | 结果 |
|---|---|
| 引擎没在跑时点重发 | `replay` 后引擎进入 starting，0.87 秒就绪后发出；新行的 id 就是 Swift 先定的那个，`isReplay`，来源 127.0.0.1 |
| 重发的内容 | 同名头 `x-dup` 两条都到了源站；`content-length` 由 999 重算成 17；`content-encoding` 被丢掉；补了 `host`；正文原样 |
| 编辑后重发（经真实的 `ReplayDraft`） | 文本框里不出现长度 / 压缩头；改成 PUT、URL 加参数、加一个头、换正文，源站收到的全是改过的，长度重算 |
| 二进制正文的编辑后重发 | protobuf 请求体（12 字节）不进文本框，原样发出，源站收到 12 字节；重发的请求同样被解码 |
| 解码 | `application/x-protobuf` → 视图 `Protobuf`，文本 `1: 150  # !sint: 75`、`2: testing`、`3:` 下 `1: 42`；`application/grpc`（带 5 字节帧头）→ `gRPC`，同样的结构；`application/msgpack` → `MsgPack`，`a: 1`、`b: x`；JSON 不解码；标了 protobuf 但不是的为 null；protobuf 请求体也解出来了 |
| JSON | 真实响应 `{"z":1,"a":[…],"big":12345678901234567890}` 经 `JSONNode` 键序为 z、a、big，大数原样 |
| Mock（经真实的 `MockRuleStore`） | `GET 127.0.0.1 /v1/user/*` → 418：curl 收到 418 + `x-mock` 头 + 正文；规则里写的 `content-length: 1` 被重算成 15；带 query 的请求照样命中；`mockRuleID` 读出来是规则 id；别的路径、别的方法走真实源站；规则存进了 `mock-rules.json` 且读回一致 |
| 重发命中 Mock | 重发 `/v1/user/9`：`isReplay` 且 `mockRuleID` 是规则 id、418 |
| 停用规则 | 停用后同一请求由真实源站应答，`mockRuleID` 为空 |
| 重发失败 | URL 写成 `not a url`：引擎回 `replay_failed`（`No hostname given`），窗口顶部提示条显示，列表里没有这一行 |
| 引擎重启后规则还在 | 停止（进程确认退出）后再点重发：引擎重新起来时先收到全量规则、再发重发，重发命中了 Mock |
| HTTPS 原请求的重发 | curl 经引擎访问 `https://httpbin.org/anything`（HTTP/2，请求头里没有 Host）；照窗口「重发」的方式用 Flow 原样构造重发：200，重发出去是 HTTP/1.1 |
| 收尾 | 每轮结束 `pgrep` 查不到听 19611 的引擎；源站按记下的 pid 结束 |

界面：把真实的视图源码（窗口、三栏、详情、正文、重发面板、Mock 面板）加桩编进渲染探针，窗口放屏幕外，`cacheDisplay` 出图后逐张看过，中英文各一套。只为探针改了三处 `@State` 的初始值（详情页签、JSON 树 / 文本、列表选中），因为分段控件点不动。看过的：带两个过滤输入框和脚注的整窗、被过滤滤空的空状态、请求页（Query / 请求头 / Cookie）、表单正文、JSON 树与文本、gRPC / MsgPack 解码、详情最窄时的两行头部、编辑后重发（文本 / 二进制）、Mock 规则列表（有 / 无规则）、Mock 编辑（文本 / 二进制正文）、刚开始抓 0 条时的三栏（经 `startMac()` 真起了引擎，系统代理是桩）、停止后回到卡片页。三栏宽度量的是各栏滚动视图的实际宽度：1080 → 200 / 360 / 518，新开 1600 → 200 / 360 / 1038，从 1080 拉到 1600 → 200 / 360 / 1038，900 → 198 / 280 / 420。看图时发现并改掉的：JSON 树嵌套层没有缩进、短的子项一列被居中；900 宽时工具条的方法标签被挤成两行；gRPC 请求体碰巧是合法 UTF-8，在重发面板里显示成可编辑的「*」（改成带控制字符的一律按二进制）；重发面板的文本框被撑得过高；解码文本末尾多一个空行。

**这一批没验证的**

- 右键菜单、工具条的下拉菜单渲染不出来，菜单项只核对了代码；分隔线拖动、`onHover` 光标、Mock 列表的拖动排序、「原始」「清除过滤」这些按钮没有用合成点击点过（输入框打字的实时过滤由单元测试覆盖逻辑，界面上没敲过字）。
- 真实 App 里的完整路径（菜单栏 → 窗口 → 右键 → 重发）没跑：按约定不安装、不碰 `/Applications`，由用户装上后看。
- 手机 / 模拟器来源的请求做重发、Mock：没测（重发总是从 Mac 本机发出，来源是 127.0.0.1，这是设计如此）。
- gRPC 流式调用、超过正文上限的正文：没测（TOOLS.md §5 已写明限制）。
- 请求正文被截断（超过上限）时点重发，发出去的是截断后的正文 —— 没有拦，界面上也没提示。

### 1.x 按真机的走法在模拟器上跑（2026-11-21）

起因：用户拿真 iPhone 试，相机扫码进了 Chrome（他的默认浏览器），下到一个打不开的 `.mobileconfig`；换到 Safari 手输地址后 Mac 上弹了「允许这台设备」，点了允许页面没反应，刷新几次后 502。

复现（自己起的引擎，端口 19711）：在浏览器里直接打开**代理地址**（不是配置页地址）→ 放行前回 403 页面 → 放行后引擎把这个请求转发给自己，自己连自己，循环了 16103 次，直到本机端口耗尽回 `502 [Errno 49] Can't assign requested address`。手机面板上代理地址比配置页地址显眼、还带复制按钮，手输时很容易输成它。

改了什么：

| 问题 | 改法 |
|---|---|
| 发给代理自己的请求会死循环 | 桥在 `request` / `http_connect` 最前面认出「目的地就是这个引擎」（端口是监听端口，且主机是回环名 / 本机名 / 客户端连进来用的那个地址）：不转发、不出事件、不要求放行。配置页开着（`baobox_page_port`）就 302 到配置页，否则回一页说明「这是代理地址，不是网页」；CONNECT 回 403 |
| 手机已设代理后再开配置页，会进抓包列表、还要先放行 | 目的地是「本机 + 配置页端口」的请求照常转发，但不出事件、不要求放行 |
| 点了允许页面没反应 | 403 页面加了 `<meta http-equiv=refresh content=3>`，放行后自己变成原来要开的页面 |
| iOS 上用 Chrome 等打开配置页 | `PhoneBrowser.isIOSSafari` 认不出是 Safari 就不给安装按钮，只显示「请用 Safari 打开」和一个可复制的配置页地址 |
| Android Chrome 下载证书时提示「无法安全下载」 | 页面加一句「选保留」 |
| 菜单里的「手机与平板（局域网）」勾选项 | 去掉。点「设置 iPhone / iPad…」或「设置 Android 设备…」就开始听局域网并记住（`netcapture.phoneEnabled`），以后每次开始抓包都连手机一起；关在设置页「允许手机和平板连接」 |

验证（真实的 Session / Engine / FlowStore / ConfigPageServer / MobileConfigBuilder / CaptureCA 编进一个宿主程序，端口 19611 / 19612，系统代理是桩、全程没被调用）：

| 项 | 结果 |
|---|---|
| 发给代理自己（直连局域网地址 / 经代理 / 127.0.0.1 / localhost） | 都是 302 到配置页，引擎里 0 条事件；CONNECT 到自己被拒；正常代理请求照常 200 |
| 没开配置页时发给代理自己 | 200，一页中英文说明 |
| **Android 15 模拟器，按真机走**：Chrome 开 `http://192.168.0.9:19612/` | 页面正常（Android 分支）。模拟器经 NAT 出来，Mac 看到的来源是 192.168.0.9（不是回环），所以走的是和真机一样的设备准入 |
| 点「下载证书」 | Chrome 提示 File can't be downloaded securely，点 Keep 后 `baobox-ca.crt`（1172 字节）进了 Download；随后 Chrome 自己弹「Install CA certificates in Settings」 |
| 按页面写的路径装证书 | More security & privacy › Encryption & credentials › Install a certificate › CA certificate › Install anyway › 选文件：装上了，Trusted credentials › User 里有 |
| 代理设成 `192.168.0.9:19611`（用 `adb shell settings put global http_proxy`，等价于在 Wi-Fi 里手填） | 第一个页面是 403「请在 Mac 上允许这台设备」，宿主收到待放行设备 192.168.0.9 |
| Mac 上放行 | **没有再点手机**，9 秒内页面自己变成了 neverssl.com |
| HTTPS | Chrome 开 `https://example.com/` 显示 Connection is secure，列表里是解密后的 `GET https://example.com/`，来源 192.168.0.9 |
| 手机上直接开代理地址 `http://192.168.0.9:19611/` | 跳到了配置页，列表里没有多出请求 |
| 设了代理后再开配置页 | 能开，列表里没有多出请求 |
| **iOS 18.3 模拟器**：Safari 开配置页 | 页面正常（iOS Safari 分支：装证书 / 一键配置代理 / 关代理） |
| Safari 开 `/cert` | 弹出「此网站正尝试下载一个配置描述文件。你要允许吗？」—— 系统认它是描述文件 |
| `/proxy` 描述文件的内容 | `com.apple.wifi.managed`、`ProxyType` Manual、主机和端口是 Mac 的局域网地址和代理端口、`SSID_STR` 是填的 Wi-Fi 名 |
| 别的浏览器在 iOS 上拿到的页面（用 Chrome for iOS 的 UA 取回，在模拟器 Safari 里渲染） | 只有「请用 Safari 打开这个页面」和可复制的地址，没有安装按钮 |
| `x-safari-http://` 能不能从别的浏览器跳到 Safari | **不能**：iOS 18.3 上没有 App 接这个地址（`simctl openurl` 报 -10814）；`x-safari-https://` 有，但配置页是 http 的，用不上。所以页面只给复制地址 |

**这一轮没验证的**

- iOS 模拟器里点不了屏幕：系统自动化没权限；`xcodebuild test` 的界面测试连不上 iOS 18.3 模拟器（Xcode 16.2 报 `DTServiceHubClient failed to bless service hub`）。所以「允许 → 设置里安装描述文件 → 证书信任设置里打开开关」这三下**没走**，要在真 iPhone 上看。
- Wi-Fi 代理描述文件在模拟器上装不了（模拟器没有 Wi-Fi 设置，走的是 Mac 的系统代理），真机上是否生效没验证。
- 真 iPhone 上的 Chrome 实际显示那一页（UA 是按 Chrome for iOS 的格式写的，没拿真机的 UA 对过）。
- Android 的代理是用 adb 设的，没有在 Wi-Fi 设置界面里手填。
- 菜单去掉勾选项、设置页的新开关：只编译过，没点过。

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
mitmdump --mode regular@<127.0.0.1 | 0.0.0.0>:<端口>
         --mode socks5@127.0.0.1:<端口 + 2>
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
| `request` | 请求头和正文到齐 | `id`、`client`（来源 IP）、`method`、`scheme`、`host`、`port`、`path`、`http`、`headers`、`body`、`truncated`、`sniffed`（头里没声明、按内容认出来的压缩方式）、`ts` |
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
- **设备准入**：回环地址直接放行。别的来源 IP 第一次出现时发 `device` 事件；被允许之前，它的请求一律回一个 403 页面（「请在 Mac 上允许这台设备」），CONNECT 直接断开。允许名单只在本次抓包里有效，不存盘。403 页面每 3 秒自己刷新一次，放行后不用再点。
- **发给引擎自己的请求**（有人在浏览器里打开了代理地址）：不转发（转发就是自己连自己，死循环到端口耗尽）、不出事件、不要求放行；配置页开着就 302 过去，否则回一页说明。发给配置页的请求照常转发，同样不出事件、不要求放行。见 §1.x。
- **读指令**：`running()` 里起一个守护线程逐行读标准输入，经 `loop.call_soon_threadsafe` 回到事件循环处理；读到结束就 `ctx.master.shutdown()`。

## 5. 证书（`CaptureCA`，取代 `MITMCertAuthority`）

- CA 由 mitmproxy 生成，放在 `~/Library/Application Support/Baobox/NetCapture/mitmproxy/`。公开证书是 `mitmproxy-ca-cert.pem`，带私钥的是 `mitmproxy-ca.pem`（600）。
- **还没抓过包就要装证书**：用 `-n` 加桥的 `baobox_oneshot` 选项跑一次引擎，就绪即退，约 1.2 秒。
- **安装并信任**：以当前用户身份跑 `security add-trusted-cert -r trustRoot -k <登录钥匙串> <证书>`（用户域），系统自己弹验证框（密码 / Touch ID）。用户域的信任对这个用户的所有 App 生效，够用；这台机器上 OrbStack、Charles 的根证书也都是这么装的。
- **不能沿用 v1 的做法**（`osascript … with administrator privileges` 以 root 跑 `add-trusted-cert -d`，管理员域）。2026-11-21 用户在 macOS 27.2.1 上试了三次，每次都输了密码：证书进了系统钥匙串，但信任设置没写进去（`security dump-trust-settings -d` 里没有它，`verify-cert` 报 `CSSMERR_TP_NOT_TRUSTED`）。root 的 shell 不在用户的图形会话里，系统要的那次「用户交互」做不了。
- **查询状态**：对 CA 自己做一次 `SecTrustEvaluateWithError`。**移除**：`remove-trusted-cert` 撤信任，再按 SHA-1 从登录钥匙串删证书；系统钥匙串里要是留着上面那种没装成的残留，顺手删掉（这一步才要管理员密码）。
- **验证框关掉以后要把窗口拿回来**：前台会回到之前那个 App，把我们的窗口盖住，而 Baobox 没有 Dock 图标，用户看到的是窗口「没了」（用户原话：「抓包的窗口 crash 了」）。每次弹过验证框都 `NSApp.activate` + 把发起操作的窗口 `makeKeyAndOrderFront`。抓包窗口也和别的模块的主窗口一样经 `DesktopSpaceWindow.make` 建，不然从全屏 App 里打开会被塞进那个全屏空间。
- 装不成时把 `security` 给的原因原样显示在提示条里；用户自己点了取消就什么也不说。
- 叶子证书的签发、openssl 子进程、p12 口令这些全部删掉，`NetCaptureEnv.opensslPath()` 一并删。
- **旧证书**：机器上还留着 v1 的 `NetCapture/ca/` 目录时，设置页的证书一栏多一行「旧版证书 · 移除」。用户点了才做：撤掉对 `Baobox Proxy CA` 的信任、从钥匙串删掉、再删 `ca/` 与 `leaf/` 两个目录（里面有旧 CA 的私钥）。不在启动时自动做 —— 那样一启动就弹验证框。只有 2026-07 用过开发版的机器会走到。
- **已知的表面问题**：证书在设备上显示的名字是「mitmproxy」，不是 Baobox。mitmproxy 支持换成自备的 CA，这一版不做。

## 6. 五个场景各自怎么实现

`NetCaptureSession`（`@MainActor`，单例）：窗口、菜单、MCP 都从它进。「这台 Mac」和「手机」是两个开关（`macCaptureOn`、`phonePageOn`），终端和模拟器是一次性动作；每个都先确保引擎在跑。上次是否在抓这台 Mac 存 `netcapture.lastMacCapture`，窗口上的「开始」照它来（第一次默认是）。MCP 的 `start_capture` 不弹密码框：证书已受信才指系统代理，否则只起引擎。

| 场景 | 开 | 关 |
|---|---|---|
| 这台 Mac | `SystemProxyController.enable`：HTTP / HTTPS 代理指向代理端口，SOCKS 代理指向 SOCKS 端口（含崩溃后还原）；CA 未受信就调安装 | `restore()` |
| 终端 / 脚本 | 生成合并证书文件（系统根证书 + CA，见下），经 `TerminalLauncher.run` 开一个会话，先 `export` 再进用户的 shell | 无（关掉那个终端即可） |
| iPhone / iPad | 引擎以 `lan: true` 运行（已在跑就重启一次）；起配置页服务（§7）；显示二维码 | 停配置页服务，引擎改回只听本机 |
| Android | 同上；有 adb 设备时用 `ADBController`（v1 现成）设代理、推证书 | `ADBController` 清代理 |
| 模拟器 | iOS：`xcrun simctl keychain booted add-root-cert <pem>`，并确保「这台 Mac」开着。Android 模拟器（序列号以 `emulator-` 开头）：设代理到 `10.0.2.2:<端口>`、推证书 | Android 模拟器清代理 |

**终端的环境变量**：`HTTP_PROXY`、`HTTPS_PROXY`、`http_proxy`、`https_proxy`（都是 `http://127.0.0.1:<端口>`），`SSL_CERT_FILE`、`REQUESTS_CA_BUNDLE`、`CURL_CA_BUNDLE`、`NODE_EXTRA_CA_CERTS`（都指向合并证书文件）。

**合并证书文件**：只给 CA 一张证书的话，被放行（未解密）的域名在终端里会校验失败，所以要把系统根证书也放进去。用 `security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain` 导出，后面接上 CA，写到支持目录的 `ca-bundle.pem`。在后台队列做（约定：`Process` 不在主线程等）。

**没有 adb / 没有已启动的模拟器**：按钮置灰并给一行怎么办（约定 7）。

## 7. 手机配置页

v1 靠代理拦截 `baobox.proxy` 这个域名来给页面，手机必须先设好代理才打得开。v2 改成 Baobox 自己在局域网起一个小 HTTP 服务：

- `NWListener`，端口 = 代理端口 + 1，只在听局域网时开（用过一次手机配置之后，每次开始抓包都开，设置页能关）。
- 四个 GET 路由，精确匹配（v1 是子串匹配）：`/`（配置页）、`/cert`、`/proxy`、`/proxy-off`。内容生成全部沿用 `MobileConfigBuilder`，只是 CA 路径换成 §5 的。
- 二维码编码 `http://<Mac 的局域网 IP>:<端口>/`。
- 这个服务只发公开证书和描述文件，不涉及抓到的内容，所以不做设备准入。
- **iOS 上只有 Safari 能装描述文件**，而相机扫码开的是默认浏览器。`PhoneBrowser.isIOSSafari(userAgent:)` 认不出是 Safari 时（Chrome、Firefox、Edge、微信等），`/` 不给安装按钮，只请他把配置页地址复制到 Safari 打开。
- **页面是 http 的局域网地址，不是「安全上下文」**：`navigator.clipboard` 在这里不存在。2026-11-21 用户在 Android 上点「复制」没反应就是这个原因（在 Chromium 里对同一个地址实测：`isSecureContext` 为 false、`navigator.clipboard` 为 undefined）。复制改用临时文本框 + `document.execCommand('copy')`，实测可用；再不行按钮提示长按，数值设了 `user-select: all`。
- **Android 页没法「自动配置」**：系统没有让网页设置 Wi-Fi 代理的机制（iOS 靠描述文件，Android 没有对应物）。页面能做的是把手填做到最省事：主机名、端口分开各一个复制按钮（系统的代理表单就是这两个框），外加一个 `intent:` 链接直达 Wi-Fi 设置（只有 Chrome 系浏览器认，**没在真机上验证**）。真正不用手填的两条路：连 USB 用 ADB 一键（已有），或 WireGuard 模式（见下）。

**WireGuard 模式（没做，已确认内核支持）**：2026-11-21 用包内的引擎实测，`--mode regular@端口 --mode wireguard@端口` 可以同时开，启动时打印一份 WireGuard 客户端配置。手机装官方的 WireGuard App 扫码导入后，全部流量经引擎，不用设代理，不认系统代理的 App 也能抓。证书仍要手动装。要做的话：手机面板多一个二维码，引擎多一个监听端口（UDP），设备准入要换一种认法（来源地址都是隧道里的 10.0.0.x）。

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
