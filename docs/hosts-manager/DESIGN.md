# hosts 管理

对应 issue：[#13 新工具：hosts 管理](https://github.com/qiaob/baobox_mac/issues/13)

## 目标

多套 hosts 方案，菜单栏一勾即生效；**只动自己那一段**，系统与用户手写的内容原样保留。

## 模块结构

```
Sources/Modules/Hosts/
├── HostsEnv.swift          # 支持目录、路径常量、shell/AppleScript 转义、提权执行器
├── HostsFile.swift         # /etc/hosts 的读取与「块标记」合成（纯函数，无副作用）
├── HostsScheme.swift       # 方案模型 + HostsStore（存储 + 应用协调）
├── HostsWriter.swift       # 唯一会动 /etc/hosts 的地方
├── HostsTool.swift         # ToolModule 壳：菜单 + 状态
└── HostsSettingsView.swift # 方案增删改、内容编辑、立即应用
```

数据落 `~/Library/Application Support/Baobox/Hosts/schemes.json`，与系统文件解耦——
真正的 `/etc/hosts` 只在「应用」时被改写一次。

## 只动自己那一段

写入的内容一律包在块标记里：

```
# >>> Baobox begin >>>
# 本段由 Baobox 管理，会被整段覆盖；要手工加条目请写在这段之外。
# --- 测试环境 ---
127.0.0.1 api.example.com
# <<< Baobox end <<<
```

每次应用的流程是 **读 → 摘掉旧块 → 拼上新块 → 整体写回**：

- `HostsFile.stripBlock` 把标记之间（含标记行）的内容摘掉，剩下的就是「用户自己的部分」；
- 缺 `endMarker`（用户手工编辑坏了）时从 `beginMarker` 丢到文件末尾——宁可少留我们自己的内容，
  也不能把半截块留在文件里越滚越长；
- 块为空 = 取消接管，文件回到只剩用户内容的样子。

这是 CLAUDE.md 约定 4 在系统文件上的应用：**只动自己的键，保留未知内容**。

## 提权

写 `/etc/hosts` 要 root。当前实现走 **A 方案**：`osascript` 的
`do shell script … with administrator privileges`——不需要额外的特权助手 target 与签名配置，
代价是每次弹一次系统授权框。

所有提权动作收敛在 `HostsEnv.runPrivileged` 与 `HostsWriter.write` 两处，将来换
`SMAppService` 特权助手时上层完全不用动。

一次授权里完成全部动作（拼成一条 `&&` 串联的命令）：

```sh
[ -f /etc/hosts.baobox.bak ] || /bin/cp /etc/hosts /etc/hosts.baobox.bak
/bin/cp <暂存文件> /etc/hosts
/usr/sbin/chown root:wheel /etc/hosts
/bin/chmod 644 /etc/hosts
/usr/bin/dscacheutil -flushcache
/usr/bin/killall -HUP mDNSResponder || true
```

几个刻意为之的细节：

- **备份只在不存在时做一次**。否则第二次应用会把备份覆盖成「已被我们改过」的版本，
  真正的原始 hosts 就永久丢了。
- **先以当前用户身份写暂存文件，再由特权命令整体 `cp` 过去**。避免把长文本塞进 shell 命令行，
  也天然是原子替换。
- `killall` 在 mDNSResponder 没跑时返回非零，`|| true` 兜住，否则整条命令会被判失败。
- 路径一律 `shellQuote` 单引号包裹（支持目录路径里有空格），再整体做 AppleScript 字符串转义。
- **内容没变就不弹授权框**（`composed == current` 直接成功返回）。频繁无谓地要密码是这个功能
  最容易被讨厌的地方。

用户在授权框上点取消 → AppleScript 报 `-128` → 识别为 `.cancelled`，**安静回滚**，不弹错误框。

## 勾选即生效，失败必回滚

菜单里勾一下方案就直接写系统（用户的预期是"勾了就生效"，不该再多一步"应用"）。
但写入可能失败或被取消，所以：

```
setEnabled(新值) → apply() → 失败/取消 → setEnabled(旧值)
```

否则菜单显示与 `/etc/hosts` 实际内容不符，比功能不工作更糟。设置页的 Toggle 走同一套逻辑。

删除一套**已启用**的方案后会自动重写一次——否则它的内容还留在系统文件里。

## 菜单零磁盘 IO

约定 2：`submenuItems()` 只读内存。`isManaged`（系统 hosts 是否带 Baobox 块）在
`activate()` 与每次 `apply()` 之后刷新并缓存，菜单构建期间不碰磁盘。

## 已知取舍

- **每次应用都要输密码**。用 `SMAppService` 特权助手可以做到一次授权长期有效，但要多一个
  helper target、独立签名与 launchd plist。等这个工具确认常用了再上，别提前付这个复杂度。
- 方案之间的域名冲突（同一域名在两套里指向不同 IP）目前不检测，先后顺序由 hosts 文件本身的
  语义决定（前者生效）。P1 再加提示。
- 远程 hosts 订阅、与 NetCapture 联动的「环境」概念都留在 issue 里，本次不做。
