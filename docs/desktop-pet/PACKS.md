# 桌面宠物 · 形象（3D 模型 / 2D 帧图）与设置里下载

> 代码：`mac/Sources/Modules/DesktopPet/` —— `GLTFLoader`（读模型）· `PetModelView`（3D 渲染）· `PetCatalog`（内置 / 可下载清单）· `PetPackStore`（下载）· `SpriteRenderer`（素材包加载 + 2D 渲染）。
> 上层设计见 `docs/desktop-pet/DESIGN.md`（PR #46）§7；本文是 §7.2 / §7.3 的落地与偏差说明。

## 1. 结论

- **默认 3D**：内置 3 个毛绒形象（小猫 / 小狗 / 小兔），开箱即用，不用用户做任何事。
- **更多形象一键下载**：设置 → 桌面宠物 → 更多形象，跟离线翻译模型一样一个按钮 + 进度条，可删除。现有 16 个：柴犬、哈士奇、狐狸、巴哥犬、熊猫、长耳兔、青蛙、浣熊、小鸡、团子猫、方块猫 / 狗 / 兔 / 猪 / 狮、机器人。
- 交互（单击 / 双击 / 抚摸 / 喂食 / 陪玩 / 睡醒）与通知气泡见 `INTERACTION.md`。
- **2D 帧图形象照旧支持**（自制用），格式见 §4.2。
- **直接读 GLB / glTF，不转 USDZ**。与 DESIGN.md §7.3「出厂前统一转 USDZ」不同：本机没有 Reality Converter / Blender，用户自己往文件夹里放模型时也做不到转换；SceneKit / Model I/O 又都不认 glTF，所以 App 内自带一个最小读取器（§5）。
- 素材全部转存在本仓库（个人自用，按用户决定不做授权审查）。原计划的 Frakassets 2D 素材包放在 itch.io，脚本请求一律 429，App 里下载不了，已放弃。

## 2. 文件布局

| 位置 | 内容 |
|---|---|
| `mac/Sources/Resources/Pets/<id>/` | 内置形象：`pet.json` + `model.glb`。`project.yml` 以**文件夹引用**整体打进 `Baobox.app/Contents/Resources/Pets/<id>/`（按普通资源会平铺到 Resources 根下，各形象的 `pet.json` 同名冲突）。 |
| `assets/pets/<id>/` | 可下载形象，同样的两个文件，不进 App 包。 |
| `~/Library/Application Support/Baobox/Pets/<id>/` | 下载的形象装在这里；自制形象也放这里（一个子文件夹一个形象）。 |

加载顺序（同 id 先到先得）：内置（按 `PetCatalog.builtIn`）→ 已下载（按 `PetCatalog.downloadable`）→ 自制（按文件夹名）。没选过形象时用第一个内置的。

## 3. 设置里下载（`PetPackStore`）

- 清单写死在 `PetCatalog.downloadable`：每个文件的字节数 + SHA-256。地址钉在 `PetCatalog.revision` 这个提交上，依次尝试：
  1. `https://raw.githubusercontent.com/qiaob/baobox_mac/<revision>/assets/pets/<id>/<file>`
  2. `https://cdn.jsdelivr.net/gh/qiaob/baobox_mac@<revision>/assets/pets/<id>/<file>`（国内网络更稳）
- 逐文件按源顺序试；连不上 / 非 200 / 大小或哈希不对都换下一个源，全失败报最后一个错误。
- 先写进 `Pets/.download-<id>/`（隐藏目录，加载器会跳过），**全部校验通过才整体挪成** `Pets/<id>/`，中途失败不留半个包。下载完自动换上。
- 删除只删下载的那个文件夹；正在用的被删了就回到第一个内置形象。
- 不做断点续传（最大的不到 1 MB）。

### 加一个可下载形象

1. 文件放进 `assets/pets/<id>/`（`pet.json` + `model.glb`，贴图请内嵌进 GLB，下载器不建子目录），提交并推送。
2. 用 `shasum -a 256` 和 `stat -f %z` 取每个文件的哈希和大小，写进 `PetCatalog.downloadable`；`revision` 改成第 1 步的提交。
3. `Localizable.xcstrings` 加 `pet.pack.<id>` 的中英名字。

素材只增不改：要换图就提交新文件、改哈希和 `revision`（已发布的旧版本 App 还钉在旧提交上，不受影响）。

## 4. `pet.json`

### 4.1 3D

```json
{
  "model": "model.glb",
  "clips": {
    "idle": "idle_breathe",
    "walk": "walk_in",
    "happy": "wave",
    "sleep": { "clip": "lie_down", "hold": true },
    "drag": "happy_wiggle"
  },
  "fidgets": ["look_around", "scratch_ear", "yawn", "stretch"],
  "interactions": {
    "poke": [["giggle"], ["ear_perk"], ["happy_wiggle"]],
    "highFive": [["paw_highfive_R"], ["paw_highfive_L"]],
    "pet": [["listen_nod"]],
    "feed": [["sit_down", "sit_hold_eat", "stand_up"], ["sit_down", "sit_hold_drink", "stand_up"]],
    "play": [["pounce"], ["bat_paw_L"], ["lie_play"]],
    "wake": [["get_up", "stretch"], ["get_up", "yawn"]]
  },
  "yaw": 0,
  "scale": 1
}
```

- `clips`：引擎状态 → 模型里的动画片段名。状态有五个：`idle` 待机、`walk` 走路、`happy` 来通知时（播一次）、`sleep` 睡觉（默认播完停在最后一帧）、`drag` 被拖着。值可以直接写片段名，也可以写 `{ "clip", "loop", "hold" }`。
- 没写的状态按片段名猜（idle / survey → 待机，walk → 走路，jump / wave / yes → 通知，sleep / lie / sit → 睡觉），再没有就用待机。
- `fidgets`：待机时每 8–16 秒随机播一个的小动作，播完回到待机；来通知 / 开始走路会立刻打断。
- `interactions`：互动 → 若干候选（随机挑一个），每个候选是一串依次播放的片段（只有一段时也可以直接写字符串）。互动有六种：`poke` 单击、`highFive` 双击、`pet` 抚摸、`feed` 喂食、`play` 陪玩、`wake` 睡醒。没写的按片段名猜（giggle / jump → 单击，highfive / wave → 双击，nod → 抚摸，eat / drink → 喂食，pounce / dance → 陪玩，get_up / yawn → 睡醒），猜不到就不支持（环形菜单里不显示「喂食」「陪玩」）。
- 片段名要写全名：Quaternius 的模型带 `AnimalArmature|` 之类的前缀（有的重复三遍）。
- `yaw`：模型正面不朝 +Z 时的修正（度）；`scale`：在自动取景的基础上再放大 / 缩小。
- `name`：只对自制形象有用（内置 / 可下载形象的名字按界面语言取自 `PetCatalog`）。
- 只放一个 `.glb`、不写 `pet.json` 也行：文件夹名当名字，动作全靠猜。

### 4.2 2D

```json
{
  "name": "橘猫",
  "pixelArt": true,
  "facing": "right",
  "states": {
    "idle":  { "sheet": "cat.png", "frameWidth": 32, "frameHeight": 32, "row": 0, "fps": 6 },
    "walk":  { "sheet": "cat.png", "frameWidth": 32, "frameHeight": 32, "row": 1, "fps": 12 },
    "happy": { "frames": ["jump1.png", "jump2.png"], "fps": 10 },
    "sleep": { "sheet": "cat.png", "frameWidth": 32, "frameHeight": 32, "row": 2, "column": 4, "count": 2, "fps": 3 }
  }
}
```

- 状态固定 `idle`（必需）/ `walk` / `happy` / `sleep`，缺的回退 `idle`（帧率也用 `idle` 的）。
- 取帧二选一：整图分行（`sheet` 文件名或 `"*"` = 文件夹里第一张 PNG；`row` 从上往下 0 起；`column` 起始列；`count` 不写取到行尾）或散图序列（`frames`）。
- `pixelArt: true` 时按整数个屏幕像素放大、最近邻采样；`facing` 写素材本身朝哪边，走的方向相反时自动镜像。
- 渲染按所有帧不透明像素的并集统一缩放、脚踩窗口底边 —— 不同来源的素材留白差别很大。

## 5. GLB 读取器（`GLTFLoader`）

覆盖宠物模型用得到的部分：三角形网格、PBR 基色（颜色 / 内嵌或相对路径贴图）、骨骼蒙皮、位置 / 旋转 / 缩放动画（LINEAR / STEP；CUBICSPLINE 取关键值）。
不支持：Draco / meshopt 压缩、KTX2 贴图、稀疏访问器、形变（morph）动画 —— `extensionsRequired` 非空直接拒绝；稀疏访问器 / 形变只出现在形变目标上时不影响（BabyPurrPal 就是这样）。解析全程容错，坏的部分跳过，不 crash。

实测踩到的三个坑（狐狸 / 机器人逐帧离屏渲染对比找到的）：

1. **SceneKit 会把蒙皮网格所在节点的变换再乘一遍**（glTF 规定忽略）：RobotExpressive 的手（节点带 100 倍缩放）被放大一百倍。蒙皮网格统一挂到模型根下；若顶点在网格节点的局部空间（FBX2glTF 导出的模型都这样：节点带 100 倍缩放 + 绕 X 转 −90°），把节点变换烘进顶点 / 法线，再从逆绑定矩阵里除掉 —— 蒙皮结果不变，包围盒（相机取景靠它）正确。
2. **有的导出器存的蒙皮权重加起来不是 1**（RobotExpressive 的手最大 1.75）：线性混合蒙皮时顶点被成倍推远，手被拉成长条。每个顶点归一化（three.js 读 glTF 时同样会做）。
3. **没带法线的网格**（Khronos Fox）：按面法线补。

## 6. 渲染（`PetModelView`）

- 透明 `SCNView`；固定透视相机（视角 28°、略俯视）+ 方向光 + 环境光，无阴影。模型按包围盒归一到「脚踩 y=0、高 ≤ 1.1、长 ≤ 1.35」，走路侧身也放得下，头顶留出提醒时跳一下的空间。
- 朝向：走路侧身（±90°），待机 / 睡觉 3/4 侧向最后走的方向，来通知正对用户；转身 0.3 秒过渡。片段间交叉淡入淡出 150ms；一次性片段（挥手）播完才切走。
- 功耗：走路 / 提醒 / 拖拽 30fps、待机 20fps；睡下（片段播完）后整个场景暂停、不再渲染，宠物隐藏时同样暂停。实测（M3，Debug 构建）待机约 4–6% CPU。
- 鼠标事件转给宠物窗，拖拽 / 点击菜单与 2D 一致。用到 3D 形象时才创建这个视图（只用 2D 的不付 SceneKit 初始化的钱）。

## 7. 来源

| id | 形象 | 来源 |
|---|---|---|
| `plush-cat` / `plush-dog` / `plush-bunny` | 小猫 / 小狗 / 小兔（内置） | BabyPurrPal（`github.com/akshaynikhare/BabyPurrPal`，`assets/characters/`） |
| `shiba` / `husky` / `fox` | 柴犬 / 哈士奇 / 狐狸 | Quaternius Ultimate Animated Animals（poly.pizza） |
| `pug` | 巴哥犬 | Quaternius Characters Pug（poly.pizza） |
| `panda` / `rabbit` / `frog` | 熊猫 / 长耳兔 / 青蛙 | Quaternius 直立动物角色（poly.pizza） |
| `raccoon` / `chick` / `cat-blob` | 浣熊 / 小鸡 / 团子猫 | Quaternius 方块动物 / Cat Blob（poly.pizza） |
| `cube-cat` / `cube-dog` / `cube-bunny` / `cube-pig` / `cube-lion` | 方块猫 / 狗 / 兔 / 猪 / 狮 | Kenney Cube Pets（外置贴图已内嵌进 GLB） |
| `robot` | 机器人 | three.js 示例 RobotExpressive（Tomás Laulhé） |
