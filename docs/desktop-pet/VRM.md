# 桌面宠物 · VRM 形象（二次元人形）

> 代码：`mac/Sources/Modules/DesktopPet/` —— `GLTFLoader`（读 GLB，新增形变目标 / 透明模式 / 自发光）·
> `VRMModel`（解析 VRM 扩展：人形骨骼、表情、MToon 参数）· `VRMMotion`（程序化人形动作）· `PetModelView`（后台读取、表情、取景）。
> 上层：`DESIGN.md` §7（3D 渲染后端）、`PACKS.md`（形象包格式）、`INTERACTION.md` §5「二次元形象：下一轮做」—— 就是这一篇。

## 1. 目标与范围

VRoid 等工具做的 VRM 模型（`.vrm` 就是带扩展的 GLB）放进形象文件夹就能当桌宠，并且**像宠物一样动起来**：

| 要做 | 说明 |
|---|---|
| 程序化人形动作 | VRM 不带动画。按 VRM 规定的人形骨骼（hips / spine / upperArm …）现场生成待机、走路、挥手、坐下睡觉、被拎起、各种互动与健康提醒的动作，任何 VRM 都能用 |
| 表情 | 自动眨眼；开心、惊讶、眯眼笑、打哈欠等跟着动作走（用模型自带的表情形变） |
| 卡通光影 | 近似 MToon：两段式明暗 + 模型自带的阴影色，替代现在的 Lambert 光照 |
| 透明 | 睫毛、眉毛、头发边缘的 MASK / BLEND 材质正确裁切与混合 |
| 后台读取 | 20 MB 级模型读一次 0.7–3.6 秒，改到后台，换形象不卡界面 |
| 取景 | 按身高取景（T 字姿势的臂展不算），人物不再被缩成一半 |
| VRM 0.x 与 1.0 | 两版扩展都读；朝向（0.x 面朝 −Z）自动修正，`pet.json` 不用写 `yaw` |
| 两个可下载形象 | 凍香（あわ）、錬金術師の少女（マユラ），许可允许再分发，进「更多形象」 |

**这一版不做**：头发 / 裙摆物理（spring bone，走路时头发是硬的）、MToon 描边与边缘光、视线跟随鼠标、口型。

## 2. 读取（GLTFLoader 的增量）

- **形变目标（morph target）**：只为 VRM 表情实际用到的目标建 `SCNMorpher`（`calculationMode = .additive`，glTF 的目标本来就是增量）。
  VRoid 的脸有五十多个目标，全建内存翻倍，用不上。非 VRM 模型照旧不读形变。
- **透明模式**：`alphaMode = MASK` → 片元着色器按 `alphaCutoff` 丢弃；`BLEND` → 不写深度、排在不透明物体之后画。
- **自发光**：`emissiveTexture` / `emissiveFactor`（VRoid 头发高光、眼睛高光）。
- **模型文件**：文件夹里只放一个 `.vrm`（不写 `pet.json`）也认。

## 3. VRM 扩展（VRMModel）

| | VRM 0.x（`extensions.VRM`） | VRM 1.0（`extensions.VRMC_vrm`） |
|---|---|---|
| 人形骨骼 | `humanoid.humanBones[] {bone, node}` | `humanoid.humanBones {名字: {node}}` |
| 表情 | `blendShapeMaster.blendShapeGroups[] {presetName, name, binds[{mesh, index, weight 0–100}]}` | `expressions.preset/custom {名字: {morphTargetBinds[{node, index, weight 0–1}]}}` |
| MToon | `materialProperties[]`（按材质下标对应）：`_ShadeColor`、`_ShadeShift`、`_ShadeToony` | 材质上的 `VRMC_materials_mtoon`：`shadeColorFactor`、`shadingShiftFactor`、`shadingToonyFactor` |
| 朝向 | 面朝 −Z | 面朝 +Z |

表情统一成内部名：`blink`、`blinkLeft`、`blinkRight`、`happy`（0.x 的 joy）、`relaxed`（fun）、`sad`（sorrow）、`angry`、`surprised`（0.x 是自定义名 Surprised）、`aa ih ou ee oh`（a i u e o）。

## 4. 程序化动作（VRMMotion）

### 4.1 规范化人形空间

动作写在「规范化」空间里：人物面朝 +Z、+X 是人物左手边、T 字姿势下每根骨骼的旋转都是单位旋转。
换算到模型的实际骨骼（与 three-vrm 相同）：

```
实际局部旋转 = 父骨骼静止世界旋转⁻¹ · q · 父骨骼静止世界旋转 · 静止局部旋转
```

- VRoid 导出的 0.x 模型骨骼全是单位旋转，公式退化成「实际 = q」；1.0 模型（如 pixiv 样例）骨骼带初始旋转，必须换算。
- 0.x 面朝 −Z：q 先绕 Y 转 180° 共轭（四元数 x、z 取反），hips 位移的 x、z 取反。
- 模型缺的可选骨骼（chest、neck、肩…）跳过，动作照样成立。

### 4.2 片段

每个片段是「骨骼旋转 + hips 位移 + 表情权重」随时间的函数，按 30 fps 采样成 `CAKeyframeAnimation`，
装进现有的 `GLTFClip`（引擎的播放、淡入淡出、锁定逻辑一行不改）。表情轨用 `morpher.weights[i]` 关键路径挂在同一片段里。

| 片段 | 用途 | 内容 |
|---|---|---|
| `idle` | 待机（循环 4 s） | 手臂自然下垂、肘微弯；胸口起伏，重心左右轻移，头微摆 |
| `walk` | 走路的后备（循环 1.3 s） | 程序做的：大腿前后摆、膝盖在摆动相弯曲，手臂反向摆。试用反馈「僵硬、像机器人」，平时不用，只在动捕资源读不到时用 |
| `walk_feminine` / `walk_happy` / `walk_childish` | 走路（循环） | **真人动捕**（MOCAP.md）：平时女性化地走，心情好时开心地走，活泼时孩子气地走 |
| `run` | 赶路（循环 0.7 s） | 前倾，手臂弯约 90° 前后大摆，大步，两步之间腾空 |
| `squat_down` / `squat` / `squat_up` | 歇脚：蹲 | 两手先按住裙子往下蹲，蹲稳了抱膝轻晃；起身前先按住裙子 |
| `sit_ground_down` / `sit_ground` / `sit_ground_up` | 歇脚：坐地 | 蹲下、跪落成鸭子坐，双手搭在两腿中间的裙子上晃身子；倒着站起 |
| `jump_crouch` / `jump_rise` / `jump_fall` / `jump_spin` / `jump_reach` / `jump_land` | 跳上 / 跳下（SETTLE.md §4.4） | 蹲下蓄力蹬起 → 上升 / 下落 → 二段跳空中再蹬、并腿转一圈 → 落地前腿先伸 → 屈膝缓冲；引擎按阶段切片段、按抛物线挪窗口 |
| `hop_crouch` / `hop_fall` | 往下轻跳 | 小蹲轻轻一跳，腿并拢微屈、两臂轻轻张开落下 |
| `boost_crouch` / `fly` / `fly_down` / `boost_brake` | 背火箭飞（`VRMBooster`） | 点火蹲下蓄力 → 往上飞（前倾、腿并拢浮动）/ 往下小火悬停着降 → 刹车腿先伸，落地接 `jump_land` |
| `wave` | 来通知、双击 | 右手举到头侧，小臂左右摆三下，开心表情 |
| `sleep` | 睡觉（播完停住） | **站着打盹**：低头歪头、肩膀手臂松下来、膝盖微屈，闭眼 |
| `drag` | 被拎起（循环） | 腿悬空交替轻踢，手臂微张，惊讶表情 |
| `look_around` / `tilt_head` / `stretch` | 待机小动作 | 东张西望 / 歪头微笑 / 双手从两侧举过头顶、后仰踮脚 |
| `giggle` / `jump` | 单击 | 缩肩、双手在胸前笑 / 下蹲起跳落地，开心表情 |
| `nod` | 抚摸 | 眯眼笑着点两下头 |
| `dance` | 陪玩 | 左右摇摆，在胸前拍手，跟着节拍点头 |
| `get_up` | 睡醒 | 睁眼、抬头回到待机（接 `stretch` 或 `yawn`） |
| `sit_down` / `sit_hold_drink` / `sit_hold_eat` / `stand_up` | 喝水提醒、喂食 | **站着**双手捧杯到胸前 → 举到嘴边喝两口（吃东西时嘴一张一合）→ 放下 |
| `yawn` | 休息提醒 | 右手捂嘴、头微仰，张嘴、眯眼 |

**坐、蹲要挡住裙底**：VRoid 的裙子没有布料模拟（spring bone 这一版不做），大腿一往前抬 —— 坐、跪、蹲 ——
裙子不会搭在腿上，相机略俯视就会看到裙底。最早的结论是不坐到地上（睡觉站着打盹，喝水 / 吃东西站着捧杯，片段名仍用 `sit_down` 等）。
2026-11 加了蹲和坐地（引擎的「歇脚」，SETTLE.md §5.5），靠两件事挡住：
- 裙子假布料：节点名带 skirt、挂在 hips 或大腿下面的裙片骨骼按大腿姿态转（`VRMRig.skirt`、`VRMMotion.skirtRotations`），
  抬起的大腿把那一片推过去、坐地时末端顺着地面摊开；裙子没有单独骨骼的形象（ぱペコ）靠姿势本身挡；
- 姿势：蹲时膝盖并拢高过胯、手臂环抱小腿，坐成鸭子坐、双手搭在两腿中间。角度是对着两个模型逐帧扫出来的，改了要重扫；
  用「内裤颜色像素 + 身体涂品红」两次渲染检测有没有露（凍香坐下 / 起身过渡中段一个 3/4 方向仍有一条 5–10 像素的细缝）。

坐下 / 下蹲类的 hips 高度由 `VRMBody.groundedHips` 按此刻的大腿、膝盖角度现算（腿长、踝高从模型骨骼量出来），
膝盖和脚不会扎进地里；现在只有 `jump` 的下蹲与 `sleep` 的微屈膝用到。

**第二批（用户试用反馈：「动作太少」「人小，手指动作看不出来，要幅度大的」）**：只做手臂离开身体、整个人动起来的大动作，
同一个触发点有好几种随机挑（`PetModelSpec.stateVariants`、多个互动候选），待机小动作 5–10 秒一次（毛绒形象仍是 8–16 秒）：

| 触发 | 候选 |
|---|---|
| 来通知 | `wave` 挥手、`big_wave` 双手过头大幅挥、`raise_hand` 举手、`banzai` 万岁跳、`ta_da` 跳起来双手张开 |
| 待机小动作 | `look_around`（上身跟着转）、`tilt_head`、`stretch`、`side_bend` 侧弯腰、`flamingo` 单脚站张开双臂、`hands_behind` 背手踮脚晃、`sway_hum` 闭眼大幅摇、`yawn` |
| 单击 | `giggle`、`jump`、`startled` 吓得双手往上甩、`lean_laugh` 笑弯腰、`shy` 捧脸扭身、`pout` 叉腰扭头跺脚 |
| 双击 | `high_five`、`power_pose` 秀肌肉、`bow` 鞠躬、`wave` |
| 抚摸 | `nod`、`shy` |
| 陪玩 | `dance`、`spin`、`jumping_jacks` 开合跳、`boxing` 侧身打拳、`airplane` 开飞机、`twist_dance` 扭扭舞、`run_in_place` 原地跑、`cheer` |

- 手指：默认自然微屈（比 T 字姿势的平伸手自然），握拳 / 张手只是配合大动作，不做比 V、勾手指这类看不见的手势。
- 弯腰的幅度控制在三十多度：没有头发物理，再深长头发会像旗子一样平着飘出去（弯腰看地上的动作因此去掉）。

片段名与健康提醒、互动的猜测规则（`PetModelSpec.resolvedClips / resolvedInteractions`）对齐，
VRM 不需要 `pet.json`；写了 `pet.json` 的照旧按它来（可以换成模型自带的动画）。默认映射见 `PetModelSpec.withVRMDefaults`：
待机 `idle`、走路 `walk`、来通知 `wave`、睡觉 `sleep`、被拎起 `drag`；小动作 `look_around / tilt_head / stretch`；
单击 `giggle / jump`、双击 `wave`、抚摸 `nod`、喂食 `sit_down → sit_hold_eat → stand_up`、陪玩 `dance`、
睡醒 `get_up → stretch / yawn`。

### 4.3 眨眼

单独一条循环动画（7 s 一轮，里面两次单眨 + 一次连眨，看起来不机械）。带表情的片段会把 `blink` 压成 0，
睡觉把它压成 1，片段结束后眨眼循环自然恢复。

## 5. 卡通光影

VRM 材质改用 `.constant` 光照 + 片元着色器自己算明暗（不受场景灯光影响，与毛绒形象互不干扰）：

```
ndl   = dot(法线, 固定的视空间光方向)
lit   = linearstep(-1 + toony, 1 - toony, ndl + shift)
颜色 = 底色 × mix(阴影色, 1, lit) + 自发光
```

- 1.0 直接用 `shadingShiftFactor / shadingToonyFactor`；0.x 的公式不同，换算成等价的 1.0 参数：
  `toony₁ = 1 − (1 − toony₀)(1 − shift₀)/2`，`shift₁ = −shift₀ − 1 + toony₁`。
- 不做描边、边缘光、matcap、GI 均衡。

## 6. 后台读取与取景

- `PetModelView.setPackage` 改成：后台队列读文件、建节点树（不挂进场景），回主线程挂上、套动作；期间旧形象先撤掉。
  读失败才回退 2D 占位（`PetController.applyCharacter` 改成回调）。连换两次时只认最后一次。
- 取景：只按身高取景（T 字姿势的臂展不算）。人物撑满窗口高度的 83%、脚贴近窗口底边（毛绒形象 73%）。
- **宠物窗放大**：人形在方窗里只占一小条（试用反馈「调到最大还是很小」），VRM 的宠物窗边长 ×1.55，
  同样的尺寸设置下人比原来高约 1.76 倍；尺寸滑块上限 1.6 → 2.2。换形象时窗口以底边中点为准缩放，脚不挪地方。
  没用竖长窗：开飞机、单脚站这类双臂张开的动作需要横向空间。
- **走路不打滑**：宠物窗的移动速度按步幅算（`VRMMotion.groundSpeed`：腿长 × 摆幅 × 步频，再按取景缩放换成点 / 秒），
  原来固定 34 点 / 秒，人放大后步子大、身子挪得慢，像在空中踩水（试用反馈「飘在空中」）。脚下加一块软影子，在空中时藏起来。
- **钉脚**（`VRMMotion.plantFeet`，两节骨骼的腿部 IK）：站着的片段每一帧重算腿，hips 怎么挪怎么转脚都不离开原位、脚掌放平
  （试用反馈「站着的时候脚左右摇晃」）。走路、跳、转圈、被拎起、跺脚那只脚不钉。
- **只有人身上接点击**（试用反馈「点人旁边也能拖动」）：每秒 20 次按此刻动画里各骨骼的屏幕投影判断鼠标在不在人身上
  （头一个圆、躯干一段胶囊、四肢各两段），不在就让宠物窗不接鼠标，点击落到下面的窗口。拖拽中不切换；
  毛绒 / 2D 形象仍是整个窗口（`PetController.updateClickThrough`、`PetModelView.hitsBody`）。

## 7. 可下载形象

| id | 角色 / 作者 | 来源 | 许可（作者在 VRoid Hub 上的设置） |
|---|---|---|---|
| `vroid-toka` | 凍香 / あわ | VRoid Hub 模型 6113323975888025598 | 他人可用、可改、可再分发、可商用、无需署名 |
| `vroid-alchemist` | 錬金術師の少女 / マユラ（mayura） | VRoid Hub 模型 3171992335144963851 | 他人可用、可改、可再分发、**不可商用**、无需署名 |

- 文件：`assets/pets/<id>/pet.json`（只写 `"model": "model.vrm"`）+ `model.vrm`，按 `PACKS.md` §3 的流程登记大小与哈希。
- jsDelivr 单文件上限 20 MB：原文件的 2048 贴图降到 1024（两个模型都允许改；其余字节、元数据与许可原样），
  凍香 20.5 → 14.7 MB、錬金術師 24.2 → 14.1 MB，两个下载源都能用。脸部特写对比看不出差别。
- 署名写进设置页（`PetCatalog.credit`）与 `PACKS.md`。
- 用户本机自己下载的 ぱペコ、マヌカンちゃん 不允许再分发，**不进仓库**。

## 8. 验证

- 离线探针：用 App 里同一份 `GLTFLoader` / `VRM*` 源码编一个命令行程序，SceneKit 离屏渲染每个片段的关键帧，
  人工看姿势、表情、光影；VRM 0.x（两个可下载形象）与 1.0（pixiv 样例 `VRM1_Constraint_Twist_Sample`）各跑一遍。
- `xcodebuild` 编过；本机装上后逐项看：待机 / 走路转身 / 通知挥手 / 拖拽 / 睡觉与叫醒 / 单击双击抚摸陪玩 / 喝水与伸懒腰提醒 / 换形象不卡。
