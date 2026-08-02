# 屏幕取字（OCR）

嵌在截图模块里，**不新立 `ToolModule`**。

## 为什么不单独立模块

OCR 的入口天然就是「框一块屏幕」，而这套交互——多屏 overlay、窗口悬停命中、手柄微调、
像素放大镜、菜单场景的冻结底图——`CaptureOverlayView` 里已经全有了。
单独立模块只会得到：菜单栏多一层二级菜单、设置多一个 Tab、再抄一遍选区交互。
`ToolModule` 是给「有独立生命周期的工具」准备的，取字没有。

更实际的一点：进标注相时 `frozenImage` 就是选区的冻结图，取字直接拿它跑，**一次屏都不用重抓**。

## 入口（两条，一份实现）

| 入口 | 路径 | 适用 |
|---|---|---|
| 标注工具条「取字」按钮（贴图/长截屏右边） | 普通截图会话 → `finishSelection(.ocr)` → `CaptureController.finishRecognize(图)` | 已经框好了，临时决定要文字 |
| 快捷键 / 菜单「屏幕取字」 | `beginTextRecognition()` → `CaptureSessionMode.ocr` 会话 | 一步到位，最快 |
| 截图历史条目 · 贴图窗右键 | 直接 `OCRResultWindow.present(image:)` | 对已有图片补一次识别 |

快捷键 `screenshot.ocr` 出厂**不绑定**（沿用项目对易冲突组合的一贯做法）。

### `.ocr` 会话怎么复用现有链路

会话模式加一个 `case ocr` 后，**选区、窗口命中、⏎ 全屏、菜单冻结底图这些逻辑一行都不用改**，
只在两个终点分流：

- `CaptureController.finishComposited(_:mode:)` —— 冻结裁剪那条路的终点；
- `performCapture(target:mode:)` 的成功分支 —— 实时抓屏那条路的终点。

`sessionMode == .ocr` 时把图交给 `OCRResultWindow.present`，否则照旧走 `ScreenshotResultHandler`。

overlay 侧只多了一个 `ocrMode`：不出标注工具条、框选松手即识别（取字这条路径的价值就是快，
要微调选区可以走普通截图 + 工具条按钮），外加一套自己的提示条文案。

## 识别（`Sources/Core/TextRecognizer.swift`）

放 Core 而不是 Screenshot 模块，因为截图历史、贴图窗都要用，以后剪贴板里的图片也可能要
（和 `QRCodeGenerator` 当初下沉是一个道理）。

- `VNRecognizeTextRequest`（`.accurate` + 语言纠错）与 `VNDetectBarcodesRequest` **一起 perform**，
  同一张图只解码一次；顺手把画面里的二维码/条码内容也带回来（生成早就有了，识别正好补上另一半）。
- 只用 macOS 11 起就稳定的 `VNImageRequestHandler` 一套接口，不碰 macOS 15 才有的新 Vision Swift API。
- 全程离线，屏幕录制以外**不需要任何新权限**。
- 非 `@MainActor`：大图识别几百毫秒到秒级，一律在后台队列调用。

### 版面还原

Vision 返回的是一堆带归一化 `boundingBox`（原点左下）的碎片，首尾相连会糊成一行。这里：

1. 按 `midY` 自上而下排序；
2. 与当前行平均中心相差不到半个行高的并进同一行（多栏排版会命中）；
3. 行内按 `minX` 从左到右拼接——**中日韩之间不补空格**，其余补一个（否则中文被塞满空格、英文粘成一坨）；
4. 行距明显大于行高（> 0.8×）时多空一行，还原段落。

## 结果窗（`OCRResultWindow`）

识别难免有错，所以默认给**可编辑文本框**而不是只读展示——就地改完再复制，比重识别快。
结构对齐 `ClipboardEditorWindow`：标准窗口 + 强引用池 + `windowWillClose` 摘除，
`NSTextView` 自带撤销与 ⌘F 查找条，关掉全部智能替换（识别结果常是代码/路径/命令）。

- 识别在后台跑，窗口先以「识别中…」占位，避免点了没反应；
- 识别到二维码时底部单独一行展示，⏎/「复制」时与正文一并进剪贴板；
- 设置里勾了「识别后直接复制」就不开窗，识别完静默进剪贴板（没识别到内容才弹一次提示）。

## 设置（截图 Tab 新增一节）

- **识别语言**：中文+英文（默认）/ 仅英文 / 中文+英文+日文。语言选得越少准确率通常越高。
- **识别后直接复制，不弹结果窗**：默认关。

存 `screenshot.ocrLanguage` / `screenshot.ocrAutoCopyOnly` 两个 UserDefaults 键。

## 涉及文件

| 文件 | 改动 |
|---|---|
| `Sources/Core/TextRecognizer.swift` | **新增** —— Vision 识别 + 版面还原 + 语言选项 |
| `Sources/Modules/Screenshot/OCRResultWindow.swift` | **新增** —— 结果窗（可编辑 + 复制） |
| `CaptureController.swift` | `CaptureSessionMode.ocr`、`beginTextRecognition()`、`finishRecognize(_:)`、两个终点分流 |
| `CaptureOverlayWindow.swift` / `CaptureOverlayView.swift` | `ocrMode`：不出工具条、松手即识别、专属提示条；`FinishAction.ocr` |
| `AnnotationToolbar.swift` | 「取字」按钮（`text.viewfinder`）+ delegate 方法 |
| `ScreenshotTool.swift` | 菜单「屏幕取字」、快捷键 `screenshot.ocr`（出厂不绑定）、历史条目「取字」 |
| `PinnedImageWindow.swift` | 右键菜单「取字」 |
| `ScreenshotSettingsView.swift` / `ScreenshotResultHandler.swift` | 设置节与两个 UserDefaults 键 |
| `Localizable.xcstrings` | 20 条 `screenshot.ocr.* / annotation.recognizeText / pin.menu.recognizeText` 等 |

## 已知取舍

- 标注不参与取字：标注是画在文字上的遮挡物，喂给 OCR 只会添乱，`.ocr` 用未合成的原图。
- 竖排文字、艺术字、极低对比度的截图识别率有限，属于 Vision 自身能力边界。
- 结果窗是普通可 key 的窗口（要能编辑），会激活本 App；这与长截屏控制条「全程不抢焦点」的
  取舍相反，但取字的终点就是复制粘贴，激活是预期内的。
