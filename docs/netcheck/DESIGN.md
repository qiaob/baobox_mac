# 网络泄露检测（NetCheck）—— 需求与技术设计

2026-11-25。模块 id `netcheck`，菜单顺序在「网络抓包」之后。

## 1. 要回答什么

用户开着代理 / VPN / Tailscale 出口节点时，关心两件事：

1. **运营商能不能看到我的流量**（至少是访问了哪些网站）
2. **App 能不能看出我的真实位置**

单看「出口 IP 是哪」回答不了：DNS 查询、IPv6、WebRTC 的 UDP 都可能绕过隧道。
所以测五项，再把五项收成这两个问题的回答（**总结**），放在窗口最上面。

| 检测 | 看什么 | 什么算泄露 |
|---|---|---|
| 出口 | 当前公网 IPv4 属于谁、在哪、是不是机房 | 出口就是「真实网络」（隧道没生效） |
| IPv6 | 有没有 IPv6 出口、它属于谁 | 是真实网络，或与 IPv4 出口不是同一家 |
| DNS | 实际替你查 DNS 的服务器属于谁 | 其中有真实网络的服务器 |
| WebRTC | 网页经 STUN 拿到的公网地址 | 不是出口 IP（UDP 绕过了隧道，只接管 TCP 的系统代理常见） |
| 时区 | 系统时区与出口所在时区 | 不算泄露；不一致时 App 能看出你在用代理 |

「真实网络」由用户声明：关掉 VPN 测一次，点「把 ASxxxx 记为真实网络」（或在设置里手填）。
不声明也能用，只是 DNS 那项判不出「泄露给了谁」（给「测不出」，不假装没问题）。

总结的规则：

- **运营商**：出口漏了 → 能（全部）；IPv6 / DNS / WebRTC 任一项漏了 → 能看到一部分；
  这几项有测不出的 → 说不准；否则 → 看不到（只看得到你连着隧道入口）
- **真实位置**：出口 / IPv6 / WebRTC 漏了 → 能（真实 IP 暴露）；其中有测不出的 → 说不准；
  否则看不出，但出口是机房 IP、时区不一致、DNS 泄露（网站能看出运营商）这几条算「看得出在用代理」（提示）
- 窗口底部写明：这里测的是网络层，App 有定位权限时会直接用 GPS / Wi-Fi 定位，与隧道无关

## 2. 隐私

每次检测都会把出口 IP 告诉 ipapi.is、bash.ws、ipify 与 STUN 服务器，这是检测本身绕不开的。
所以**只在用户点「立即检测」时测**，启动时不测、不定时测。结果只在内存里，不落盘。
ipapi.is 的 key（可选）存钥匙串。

## 3. 规格来源

判定规则与 baobox_shared 的 `baobox-core/src/netcheck.rs` 是同一套（Windows / Linux 用那份 Rust），
这里是 Swift 的另一种写法：**改判定时两边一起改**。差别只在展示：Rust 版直接产出中文句子，
这里的纯逻辑产出结构化的原因（`NetCheckReason`），由 `NetCheckText` 本地化。

## 4. 结构

```
Modules/NetCheck/
├── Logic/NetCheckLogic.swift   纯 Foundation（进 BaoboxTests）：回包解析、ICE 候选、地址分类、五项判定、总结
├── NetCheckEngine.swift        URLSession 请求、系统解析器探测、系统时区
├── NetCheckWebRTC.swift        隐藏的 1×1 WKWebView 跑 RTCPeerConnection，收集 ICE 候选
├── NetCheckSession.swift       @MainActor 状态：跑一次检测、上次结果、记真实网络
├── NetCheckWindow.swift        结果窗口（DesktopSpaceWindow），也承载那个 WebView
├── NetCheckText.swift          结论 → 文案、纯文本报告
├── NetCheckSettings.swift      设置键 + 钥匙串
├── NetCheckSettingsView.swift  设置页
└── NetCheckTool.swift          ToolModule 壳
```

### 4.1 请求顺序（`NetCheckEngine`）

1. `GET https://api.ipapi.is/[?key=]` → IPv4 出口。认两种回包：不带 key 的（2026-09-01 起
   没有 `is_datacenter` 等判定，`asn` 是 `"AS15169 Google LLC"` 字符串）与带 key 的（`asn` / `location` 是对象）。
   没有机房判定时退回内置的云厂商 ASN 表
2. `GET https://api6.ipify.org`：只有 AAAA 记录。连不上 = 没有 IPv6 出口（两者在客户端分不开，而这正是不会漏的情况）；
   连上了再 `?q=<v6>` 查归属
3. DNS：`GET https://bash.ws/id` 拿 id（只收字母数字）→ 后台线程 `getaddrinfo("<i>.<id>.bash.ws")` × N
   （走系统解析器，正是要测的那条路）→ `GET https://bash.ws/dnsleak/test/<id>?json=2`。
   回 `error` 记录（一台解析器都没来）报「测不出」，不当成「没泄露」
4. WebRTC（见 4.2）
5. `TimeZone.current.identifier`

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
- 判定：`srflx` / `prflx` / 公网 `host` 地址与出口 IPv4 / IPv6 比较（IPv6 按字节比，不按写法）；
  mDNS 名字（`….local`）与 `relay` 跳过；内网地址（含 `100.64.0.0/10`，Tailscale 的地址在这里）只算提示；
  一个公网地址都没有 = 网页拿不到，算没问题

STUN 服务器默认 `stun:stun.l.google.com:19302`，设置里可改。

### 4.3 界面

- 菜单：状态行（上次结论 + 多久前）、两行总结、「立即检测」（开窗口并开始）、「打开检测窗口…」
- 窗口：顶部整体结论 + 「立即检测」+「复制报告」；两张总结卡片；五项逐行（图标按结论着色）；
  底部：bash.ws 的原话、没声明真实网络时的提示与「把 ASxxxx 记为真实网络」按钮、定位权限的说明
- 设置页：真实网络（ASN 列表）、ipapi.is 的 key（钥匙串）、DNS 探测个数（1–50）、STUN 服务器

## 5. 验证

- `BaoboxTests/NetCheck`：回包解析（含 2026-11 实测的回包形状）、ICE 候选解析、地址分类、五项判定、总结
- 这个仓库在 Linux 上开发，Swift 部分靠 macOS 构建工作流编译与跑测试
- **还没在真 Mac 上跑过**：WKWebView 里 WebRTC 收集到的候选形状（WebKit 默认不给 host 候选、
  或给 mDNS 名字）与超时取值，要在真机上看一次
