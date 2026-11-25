# 网络检测（NetCheck）—— IP 检测的需求与技术设计

2026-11-25。模块 id `netcheck`，菜单顺序在「网络抓包」之后。工具叫「网络检测」（原名「网络泄露检测」），窗口顶部分段切换
「IP 检测」|「测速」：这一页讲 IP 检测的请求与结构；这一页**怎么呈现、怎么比**见 [COMPARE.md](COMPARE.md)，
测速与菜单栏实时网速见 [SPEED.md](SPEED.md)。

## 1. 这一页做什么

用户开着代理 / VPN / Tailscale 出口节点时，单看「出口 IP 是哪」不够：DNS 查询、IPv6、WebRTC 的 UDP 都可能走另一条路。
所以测五项，把每条路查到的 IP、国家、归属列成一张表；四样东西（国家、归属、地址、时区）各自比，**对不上就给结论「不一致」**，
并把对不上的格子标红（按多数，并列时全红）。程序不知道哪一行是「正确值」，所以不下「泄露 / 没泄露」的结论，
也不回答「运营商能不能看到」「App 能不能看出位置」这类问题（2026-11-25 用户在真机上看过第一版后改的，原因见 COMPARE.md 背景）。

| 检测 | 看什么 |
|---|---|
| IPv4 | 当前公网 IPv4、国家、归属（ASN），以及机房 / VPN / 代理 / Tor 小标签 |
| IPv6 | 有没有 IPv6 出口；有的话同上 |
| DNS | 实际替你查 DNS 的服务器：按「国家 + 归属」分组、各几台 |
| WebRTC | 网页经 STUN 拿到的公网地址；和 IPv4 / IPv6 那一行都不同的另查一次归属（最多 3 个） |
| 时区 | 系统时区与 IP 所在时区（取 IPv4 的，没有就取 IPv6 的） |

窗口底部写明：这里测的是网络层，App 有定位权限时会直接用 GPS / Wi-Fi 定位，与代理无关。

## 2. 隐私

每次检测都会把出口 IP 告诉 ipapi.is、bash.ws、ipify 与 STUN 服务器，这是检测本身绕不开的；网页经 WebRTC 拿到的地址
和 IPv4 / IPv6 那一行都不同时，还会把那个地址交给 ipapi.is 查归属（最多 3 个）。
所以**只在用户点「立即检测」时测**，启动时不测、不定时测。结果只在内存里，不落盘。
ipapi.is 的 key（可选）存钥匙串。

测速（SPEED.md §1.5）同理：会把出口 IP 告诉 Cloudflare（speed.cloudflare.com），一次用掉几十到几百 MB 流量，
所以只在用户点了才测，不自动、不定时，结果不落盘。菜单栏实时网速只读本机网卡计数，不联网，默认关。

## 3. 规格来源

回包解析、ICE 候选解析、地址分类、「同一家云厂商」的判断与 baobox_shared 的 `baobox-core/src/netcheck.rs` 是同一套。
**从 2026-11-25 这一版起，Mac 端的呈现（列表 + 一致 / 不一致，见 COMPARE.md）不再跟那份规格走**：Rust 版仍是
「判泄露 + 两个问题的总结 + 真实网络」。Windows / Linux 要不要跟着改另行决定，这一步没动别的仓库。

## 4. 结构

```
Modules/NetCheck/
├── Logic/NetCheckLogic.swift   纯 Foundation（进 BaoboxTests）：回包解析、ICE 候选、地址分类、同一家云厂商
├── Logic/NetCheckCompare.swift 纯 Foundation（进 BaoboxTests）：建表、四样各自比、按多数标红、结论、纯文本报告的行
├── NetCheckEngine.swift        URLSession 请求、系统解析器探测、系统时区
├── NetCheckWebRTC.swift        隐藏的 1×1 WKWebView 跑 RTCPeerConnection，收集 ICE 候选
├── NetCheckSession.swift       @MainActor 状态：跑一次检测（含 WebRTC 地址的另查）、上次结果（一张表）
├── NetCheckWindow.swift        窗口（DesktopSpaceWindow）：分段切换、IP 检测页、测速页，也承载那个 WebView
├── NetCheckText.swift          表里的值 → 文案、纯文本报告（测速的文案也在这里）
├── NetCheckSettings.swift      设置键 + 钥匙串
├── NetCheckSettingsView.swift  设置页
├── NetCheckTool.swift          ToolModule 壳（二级菜单、快速入口命令）
│   —— 测速与菜单栏实时网速（SPEED.md §3）——
├── Logic/NetSpeedLogic.swift   纯 Foundation（进 BaoboxTests）：速率格式化、定宽候选、测速窗口、延迟、网卡筛选、计数差值、/meta
├── NetSpeedTest.swift          测速：URLSession 的三个阶段、取消、进度回调
├── NetSpeedTestSession.swift   @MainActor 状态：进行中的阶段与速度、上次结果
├── NetTrafficSampler.swift     每秒读网卡计数（后台），发布速度
└── NetSpeedStatusItem.swift    菜单栏状态项（定宽模板图）与它的小菜单
```

### 4.1 请求顺序（`NetCheckEngine`、`NetCheckSession.run`）

1. `GET https://api.ipapi.is/[?key=]` → IPv4。认两种回包：不带 key 的（2026-09-01 起
   没有 `is_datacenter` 等判定，`asn` 是 `"AS15169 Google LLC"` 字符串）与带 key 的（`asn` / `location` 是对象）。
   没有机房判定时退回内置的云厂商 ASN 表（只用来打「机房」小标签和判断「同一家」）
2. `GET https://api6.ipify.org`：只有 AAAA 记录。连不上 = 没有 IPv6（两者在客户端分不开）；连上了再 `?q=<v6>` 查归属
3. DNS：`GET https://bash.ws/id` 拿 id（只收字母数字）→ 后台线程 `getaddrinfo("<i>.<id>.bash.ws")` × N
   （走系统解析器，正是要测的那条路）→ `GET https://bash.ws/dnsleak/test/<id>?json=2`，只收 `dns` 与 `error` 记录。
   回 `error`（一台解析器都没来）那一行写「没测出来」
4. WebRTC（见 4.2）；拿到的公网地址和 IPv4 / IPv6 那一行都不同时，`?q=<地址>` 另查归属，最多 3 个，查不到就只显示地址
5. `TimeZone.current.identifier`

1–3 并行，WebRTC 收集完、IPv4 / IPv6 回来后再另查，最后建表。
请求用 `URLSession(configuration: .ephemeral)`（走系统代理设置 —— 要测的就是普通 App 看到的那条路），
超时 10 秒，不缓存、不带 cookie。全部 async，不在主线程等。

### 4.2 WebRTC（`NetCheckWebRTC`）

macOS 没有公开的 WebRTC API，借 WebKit 的浏览器实现，做法照搬手机互传的 `RTCTransferHost`：

- 一个 1×1 的 `WKWebView`，加载一页空 HTML，baseURL `https://baobox-netcheck.invalid/`（安全上下文）
- 由检测窗口把它挂进视图层级（不在视图层级里的 WebView 可能被 WebKit 挂起）。所以**检测总是在窗口里跑**：
  菜单「立即检测」会先开窗口
- 等页面 `didFinish` 后 `callAsyncJavaScript`：建 `RTCPeerConnection({iceServers:[{urls: STUN}]})`，
  开一个 DataChannel、`createOffer` + `setLocalDescription` 触发收集；`onicecandidate` 收 `candidate:…` 原文，
  收集完成（`null` 候选或 `iceGatheringState == complete`）或 5 秒超时就返回
- 表里只列公网地址（`srflx` / `prflx` / 公网 `host`，按字节去重）；mDNS 名字（`….local`）、`relay`、
  内网地址（含 `100.64.0.0/10`，Tailscale 的地址在这里）不列，也不另外提示。一个公网地址都没有时写「网页没拿到公网地址」

STUN 服务器默认 `stun:stun.l.google.com:19302`，设置里可改。

### 4.3 界面

- 菜单：一行「上次检测：一致 · 3 分钟前」（没测过：「还没检测过」）、「立即检测」（开窗口并开始）、「打开检测窗口…」；之后是测速的几项（SPEED.md §1.4）
- 窗口：最上面「IP 检测」|「测速」分段切换；IP 检测页见 COMPARE.md §1
- 设置页：ipapi.is 的 key（钥匙串）、DNS 探测个数（1–50）、STUN 服务器；「真实网络」已去掉（旧设置键 `netcheck.realNetworks` 不迁移）

## 5. 验证

- `BaoboxTests/NetCheck`：回包解析（含 2026-11 实测的回包形状）、ICE 候选解析、地址分类、同一家云厂商（`NetCheckLogicTests`）；
  建表、四样各自比、多数规则、缺值、DNS 分组、WebRTC 另查、报告的标记、ASN 不带分隔符（`NetCheckCompareTests`）
- 2026-11-25 在本机真跑过两次（直连、没开代理）：五项都有结果，约 6 秒，WebRTC 拿到的地址和 IPv4 相同。
  两次都是「不一致：国家」——DNS 那一行有一组 Google 的服务器 bash.ws 标在 `USA`（另一组标在新加坡），见 COMPARE.md §10
