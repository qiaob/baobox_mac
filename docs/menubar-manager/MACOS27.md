# 菜单栏管理 · macOS 27 适配（2026-11-20）

TECH_DESIGN.md 的做法（扫各 App 的状态栏窗口、看不见的占位项、模拟 ⌘ 拖）是在 macOS 14.6 上做、在 14.6 上测的。
用户的 Mac 从 14.6 直接升到 27.2.1（26B131）后，这套做法整个没了依据，0.0.8 启动 6 秒就崩（TECH_DESIGN.md §11）。
本文是调研结论和两步走的方案：**A 先做**（这次：交给系统的「«」，设置里一句话），**B 已验证可行、以后再做**。

## 1. 系统改了什么

苹果分两步改了菜单栏：

- macOS 26：各 App 的状态栏窗口归 Control Center 所有，按窗口归属找 App 的办法失效（Ice #664、CodexBar #3377）。
- macOS 27：整条菜单栏每块屏只有**一个窗口**，由系统进程 **MenuBarAgent** 画，各 App 的状态项是挂在里面的「场景」。

在用户的 27.2.1 上实测（探针都在会话草稿目录，没进仓库）：

| 现象 | 结果 |
|---|---|
| `NSStatusBarWindow.windowNumber` | 合成值 1<<32、2<<32 …，放不进 `CGWindowID`（0.0.8 就崩在这） |
| 窗口列表里各 App 的 layer 25 窗口 | 没有了；菜单栏那一条是 MenuBarAgent（layer 24）和 Window Server |
| 宽度 ≥ 半屏的状态项 | 被系统丢掉（窗口落在 y = -33），一万宽的占位项不再能把图标挤出屏幕 |
| 放不下的状态项 | 系统自己收进状态栏图标最左边的「«」，点它就能看到（截图实测：塞满后 Baobox、1Password、输入法、钉钉、Tailscale、Wi‑Fi 都进了「«」） |
| 被收进「«」时 App 这边能看出来吗 | 看不出来：已经在菜单栏上的状态项被收进去，AppKit 的窗口位置不变；只有刚建、从没摆上去的状态项落在 (0, -33)。可靠的信号是它从 MenuBarAgent 的辅助功能树里消失 |
| `NSStatusItem Preferred Position <名字>` | 只管**没被用户 ⌘ 拖过**的状态项第一次怎么摆（值越大越靠左，0 当没设）。用户拖过以后，MenuBarAgent 日志照样写「Using legacy NSStatusItemHost preferredPosition 226 for status:com.baobox.app::Item-0」，排序却按用户拖的来（1Password 5594 排在 Baobox 226 右边）；重建状态项也挪不动。App 偏好里的这个键在拖动 / 重建后被系统删掉。新排序存在哪没找到（偏好里没有，可能在受保护的控制中心容器里或只在内存） |
| 状态项窗口的 `occlusionState` | 在菜单栏上的也不含 `.visible`，不能再拿它判断看不看得见 |

## 2. 别人在 27 上的三种做法

| 做法 | 谁 | 怎么做 | 代价 |
|---|---|---|---|
| 白名单 | Stash、MenuBarHider | 私有框架 `MenuBarClientCore` 的 `MBAssessmentModeAssertion`（考试模式用的「只许这些 App 画状态项」） | 按 App 不按图标；不能排序；所有屏一套；开着时点时钟打不开通知中心；私有接口，系统一升级可能失效 |
| 挤进系统溢出 | IceMelt | 宽度算好的挡板把要藏的图标挤进系统「«」 | 挡板 ≤ 半屏，宽屏藏不全；随前台 App 菜单宽度不停重算；点隐藏的图标要先开「«」 |
| 读图标 | Thaw、StableBar | 辅助功能读 MenuBarAgent 的树（或各 App 的 `AXExtrasMenuBar`）；排序写 `com.apple.MenuBarAgent` 的 `TrailingItemPreferredPositions` | 没有窗口可截图，图标只能用 App 图标代替 |

## 3. A：在 27 上交给系统，只写一句话（这次做）

被刘海、菜单宽度挤掉的图标，系统收进「«」，点一下就能找到 —— 当初做菜单栏管理要解决的「图标被挤没了、点不到」，27 上系统自己解决了，
Baobox 自己的图标也一样，挤不下时在「«」里。

第一版 A 想再加一层「Baobox 图标被收进去就自动挪回最右边」，装到用户的 27.2.1 上实测（2026-11-20）两头都不成立（§1 表）：
看不出 Baobox 被收进去了（窗口位置不变），挪也挪不动（用户 ⌘ 拖过以后位置值不管用）。要做就得用辅助功能读 MenuBarAgent 来判断、
换一种还没验证的办法来挪，用户同意先不做。所以 A 只做这些：

- **判断走哪条路**：沿用 TECH_DESIGN.md §11 的运行时判断（主图标窗口号放不进 `CGWindowID` = 系统收纳）。旧系统上一切照旧。
- **系统收纳时什么都不装**：不装占位项、不扫描、菜单顶部那一行不出现，不需要任何权限。用户存的 `menubar.enabled` 不改，也不起作用。
- **设置页**只剩一句话：放不下的图标在菜单栏左边的「«」里，点它就能看到；想让 Baobox 图标一直露在外面，按住 ⌘ 把它拖到最右边。
  开关、「把 Baobox 图标放到最右边」、图标列表、两项权限都不显示（「放到最右边」对拖过的图标不起作用，留着只会让人以为坏了）。
- **子菜单**只有一行置灰的「放不下的图标在菜单栏左边的「«」里」。
- 「打开 Baobox 菜单」快捷键照旧：27 上 Baobox 图标的窗口看不出可见，`showMenu()` 走最后一个分支，在鼠标位置弹出菜单。

## 4. B：白名单隐藏（已验证，以后做）

2026-11-20 在用户的 27.2.1 上用探针验证（临时探针 App，bundle id 与签名同 Baobox 以借用它的授权，跑完即注销删除）：

1. **读图标**：辅助功能读 MenuBarAgent 的树，活跃屏那个窗口里每个位置一个 `AXGroup`，里面是系统图标的 `AXMenuBarItem`
   （带 `com.apple.menuextra.clock / wifi / battery / controlcenter` 这类标识）或 App 自己的 `AXButton`（`AXUIElementGetPid` = 归属 App）。
   各 App 的 `AXExtrasMenuBar` 也还在，但藏起来以后照样有，分不出藏没藏 —— 以 MenuBarAgent 的树为准。
2. **藏**：`MBAssessmentModeConfiguration(initWithAllowedSystemItems:allowedBundleIdentifiers:)` + `MBAssessmentModeAssertion`
   `activateWithConfiguration:completionHandler:`，白名单 = 正在运行的全部 App 减去要藏的；系统图标传 0…255（Stash：只传 0…63 会误伤「屏幕镜像」）。
   Tailscale 的图标消失，其余往右补位，回调无错；`invalidate` 后回到原位。
3. **点开被藏的**：换一份放行它的白名单（先激活新的再作废旧的），约 0.9 秒后图标出现；对它的 `AXButton` 做 `AXPress`，菜单弹出，2.5 秒后还开着；
   `AXPress` 会卡调用方约 1.6 秒（返回 -25204 但菜单已开），实现时放后台线程；对菜单 `AXCancel` 能关。

B 的形态（用户的原设计，按 27 的限制改）：设置里按 **App** 选显示 / 隐藏；隐藏的 App 列在 Baobox 菜单最上面一行（图标用 App 图标）；
点一下 = 临时放行 + 打开它的菜单，菜单关了再藏回去。还没验证的：通知中心被挡（MenuBarHider 的绕法：鼠标悬停时钟时临时放开）、
多显示器、进程被强杀时白名单是否自动作废、新启动的 App 何时补进白名单。私有接口不可用时退回 A。

## 5. 不采用

- 挤进系统溢出（IceMelt 的做法）：挡板宽度要不停重算、宽屏藏不全、点隐藏的图标要先开系统的「«」—— 最复杂也最不稳。
- 改系统设置里「允许在菜单栏显示」的开关（MenuBarHider 的实验做法）：持久改系统设置，崩了要靠日志恢复，风险不值。

参考：Stash（github.com/brentc22/stash）、MenuBarHider（github.com/happy666End/MenuBarHider）、IceMelt PR #46、
StableBar PR #373、vorssaint-utils #698、Thaw macos-27-preview.3。
