# 划词翻译（SelectionTranslate）设计

## 1. 需求

在**任何 App**里选中一段文字（英文或中文，单词、句子、整段都行），
就在选区旁弹出浮层：英 → 中 / 中 → 英翻译 + 朗读原文 / 朗读译文，
省掉「复制 → 切到浏览器 Google 翻译 → 看完 → 再复制回来」的来回。

仅 macOS（本模块只有 Mac 实现）。

## 2. 取词：三条路径，按可靠性排序

| 路径 | 覆盖 | 代价 |
|---|---|---|
| **AX 读选中文字**（默认） | 原生 App、浏览器网页、Google Docs 大多数情况 | 需要辅助功能权限 |
| **模拟 ⌘C 兜底**（仅手动触发时） | AX 读不到的 App（部分 Electron / 自绘界面、Docs 个别状态） | 短暂改动剪贴板（读完立即恢复原内容）；可能被剪贴板历史记一条 |
| **框选 OCR**（手动） | **根本不能选中**的文字：图片、扫描版 PDF、视频画面、游戏 | 框选一次；复用 Core 的 `TextRecognizer`（Vision 本地识别） |

自动弹出只走 AX —— 绝不为了弹窗去合成按键、动用户剪贴板。

## 3. 触发

- **选中后自动弹出**（设置开关，默认开）：CGEventTap（listen-only）监听全局
  左键抬起，延迟 ~120ms 后查 AX 选区；有非空选区且与上次不同才弹。
  点在浮层自身、或前台是 Baobox 时忽略。无辅助功能权限时 tap 建不起来，
  静默降级为手动触发。
- **全局快捷键**（出厂不绑定，仓库惯例）：菜单 / 快捷键页触发，走 AX，
  读不到时按设置走 ⌘C 兜底。
- **框选 OCR**：菜单 / 快捷键触发。冻结鼠标所在屏（与截图覆盖层同款
  `CGWindowListCreateImage` 底图），拖出矩形 → 按图像自身像素密度裁剪
  （不假设 backingScaleFactor，见 PR #32 的教训）→ Vision 识别 → 走翻译浮层。

## 4. 翻译与朗读

- 语种判定：`NLLanguageRecognizer`（本地）——中文 → 译英，其余 → 译中
  （本功能只做英⇄中）。
- 翻译：Translation 框架（macOS 15+，本地、免 key），会话挂在浮层视图的
  `.translationTask` 上，与 LiveTranslate（PR #31）同款模式。
  macOS 14 上浮层照常显示原文与朗读，只提示「翻译需要 macOS 15」。
- 朗读：`AVSpeechSynthesizer`，按语种选 zh-CN / en-US 嗓音；浮层关闭即停。

## 5. 浮层

不抢焦点的 NSPanel（`.nonactivatingPanel` + `canBecomeKey = false`），
跨 Space、全屏 App 上可见；优先贴在选区下方，放不下翻到上方，
始终夹在当前屏 visibleFrame 内。内容：方向（English → 中文）、原文
（可选中复制）、译文、按钮行（朗读原文 / 朗读译文 / 复制译文 / 关闭）。
Esc、点击浮层外任意处关闭。

## 6. 设置（UserDefaults 键，前缀 `selectiontranslate.`）

- `autoPopup`：选中后自动弹出（默认开）
- `copyFallback`：快捷键触发时 AX 读不到则模拟 ⌘C（默认开）
- `autoSpeak`：翻译完成后自动朗读译文（默认关）

## 7. 文件

```
mac/Sources/Modules/SelectionTranslate/
  SelectionTranslateTool.swift        模块壳（菜单 / 快捷键 / 设置页）
  SelectionTranslateController.swift  状态机：触发、事件 tap、TTS、面板调度
  SelectionText.swift                 AX 取词 + ⌘C 兜底 + 语种判定
  SelectionTranslatePanel.swift       浮层窗口与 SwiftUI 内容（含翻译会话）
  RegionTextPicker.swift              冻结屏框选 → OCR
  SelectionTranslateSettingsView.swift 设置页
```

权限：辅助功能（取词 + 事件 tap，与键盘点击 / 窗口管理共用一份授权）；
框选 OCR 另需屏幕录制。无新第三方依赖。
