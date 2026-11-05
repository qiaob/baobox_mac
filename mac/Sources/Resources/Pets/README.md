# 宠物素材包（Pets）

宠物形象以「素材包」为单位：一个文件夹 = 一个形象，文件夹里放 `pet.json` + 图片。
运行时从两处扫描（同名时包内优先）：

1. App 包内 `Pets/`（随版本发布的内置形象）；
2. `~/Library/Application Support/Baobox/Pets/`（用户自放，**不用重新打包即可新增/更换**）。

首次启动时 App 会在第 2 处自动建好三个示例文件夹（橘猫 / 柴犬 / 赤狐，只含 pet.json），
把对应的帧图 PNG 放进去、在设置里选该形象即可。

> 注：本仓库的推送通道只支持文本文件，PNG / 模型等二进制素材不进 git，
> 按下面的链接手动下载后放进文件夹即可。

## pet.json 格式

```json
{
  "name": "橘猫",
  "pixelArt": true,
  "states": {
    "idle":  { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 5,  "fps": 6 },
    "walk":  { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 13, "fps": 12 },
    "happy": { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 1,  "fps": 10 },
    "sleep": { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 9,  "fps": 4 }
  }
}
```

- 状态名固定四个：`idle`（待机，**必需**）、`walk`、`happy`（通知提醒时）、`sleep`；缺失的状态自动回退 idle。
- 两种取帧方式二选一：
  - **整图分行**：`sheet` = 帧图文件名，或 `"*"` 表示文件夹里第一张 PNG（优先文件名含 `side` 的）；
    `frameWidth/frameHeight` 是单帧尺寸，`row` 是第几行（0 起、从上往下），`count` 不写则按图宽自动算。
  - **散图序列**：`"frames": ["a.png", "b.png", ...]` 按顺序播放。
- `fps` 每状态可调；`pixelArt: true` 时放大用最近邻（像素图不糊边）。

## 推荐素材（已核对授权）

### 2D（当前渲染器直接可用）

- **Frakassets Free Pets Pack**（免费，CC-BY 4.0，署名 Frakassets）— https://frakassets.itch.io/free-pets-pack
  10 只动物（橘猫、柴犬、赤狐、兔子、仓鼠、刺猬等），每只 Idle / Walk / Happy / Sleep 四动画、含侧面图。
  用法：下 zip → 取 `<动物>_64px_side-view_*.png`（64px、side-view 那张）放进 App 建好的对应文件夹即可。
  其帧图的行顺序是 Happy / Idle / Sleep / Walk × South / East / North / West，
  示例 pet.json 已按 East（朝右）行写好；若实际行序不同，改 pet.json 的 `row` 数字。
- OpenGameArt 的 CC0 收藏里有大量猫/狗帧图可淘：https://opengameart.org （搜 cat / dog sprite，认准 License: CC0）。

### 3D（M3 渲染后端用，先下着）

- 狐狸 Fox.glb（模型 CC0，动画 CC-BY 4.0）— https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/Fox/glTF-Binary/Fox.glb
- Quaternius 动物包（CC0）— https://quaternius.com/packs/ultimateanimatedanimals.html
- 机器人 RobotExpressive（MIT）— https://raw.githubusercontent.com/mrdoob/three.js/dev/examples/models/gltf/RobotExpressive/RobotExpressive.glb

GLB 入 App 前需转 USDZ（苹果免费 Reality Converter 或 Blender），转换在 M3 里程碑处理。
