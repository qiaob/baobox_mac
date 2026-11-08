# 动捕走路（真人动作捕捉数据）

试用反馈（2026-11-08）：程序做的走路「膝盖都没有弯曲，僵硬」，重做的两版程序化步态（按真人步态的脚踝轨迹 + IK）
还是「像个机器人一样」，要求找开源的方案。结论：走路换成**开源的真人动作捕捉数据**，按腿长换算到 VRM 骨骼上；
用户看了 6 种风格的预览，要求「孩子气、女性化、开心都做上，不同场景用不同的」。

## 1. 数据

- 来源：万代南梦宫研究所开源的 [Bandai-Namco-Research-Motiondataset](https://github.com/BandaiNamcoResearchInc/Bandai-Namco-Research-Motiondataset)
  的 Dataset 1（同一个演员按 15 种风格做 20 种动作，BVH，30 fps）。
- 许可：**CC BY-NC 4.0**（署名、非商业，允许改编和再分发）。Baobox 是免费工具，可以用；打包的数据文件里写着出处与许可，
  本文档是署名。将来如果有商业分发，这三段要换成可商用的数据（例如 CC BY 4.0 的 100STYLE）。
- 用的三段：`dataset-1_walk_feminine_001`（女性化）、`dataset-1_walk_happy_001`（开心）、`dataset-1_walk_childish_001`（孩子气）。
  原始 BVH 不进仓库，用 GitHub 上的直链下载（`dataset/Bandai-Namco-Research-Motiondataset-1/data/<名字>.bvh`）。

## 2. 换算（`mac/scripts/mocap/convert_bvh.py`，离线跑一次）

输出 `mac/Sources/Resources/Motions/mocap-walk-<风格>.json`（各约 20 KB），App 运行时由 `VRMMocap` 读取。

1. 解析 BVH、正向运动学求每帧各关节的世界位置 / 旋转（`bvh.py`）。
2. 截一个完整步态：左脚两次着地之间、离片段正中最近的那一段（着地 = 踝的水平速度低于身体速度的 1/4，且之前摆动够 6 帧）。
3. 换到规范化人形空间（+X 人物左、+Y 上、+Z 前）：「前」取这一段 hips 的水平位移方向。减去平均速度 × 时间变成**原地**，
   首尾的残差按时间线性摊掉，循环首尾闭合。
4. 长度全部除以腿长（大腿 + 小腿）。地面 = 一个周期里脚尖的最低点；hips 高度相对「腿伸直站着」。
5. 每帧输出：
   - hips 位移；
   - 躯干（hips、spine、chest、neck、head）与手臂（肩、上臂、小臂、手）的**世界旋转**。按关节位置求方向（骨骼朝向 + 弯曲面），
     不依赖原骨架的静止姿势；neck、head 把一个周期里的平均前后倾扳回竖直（原骨架头颈关节本身往后歪 10° 左右，不扳会仰着头）；
   - 左右踝的位置（左右、前后相对 hips 的平均位置，上下相对脚掌放平时的踝高）与脚掌角度（相对放平，正 = 脚跟抬起）；
   - 地面速度（腿长 / 秒）。

## 3. 运行时（`VRMMocap`、`PetGait`）

- `VRMMocap.definitions(body:)` 给每段生成一个 `VRMMotion.Definition`（`walk_feminine` / `walk_happy` / `walk_childish`），
  和程序化动作一起采样成动画（`VRMMotion.clips`）：
  - 躯干、手臂：世界旋转逐级换成相对父骨骼的局部旋转；
  - 腿：动捕的踝位置 × 这个身材的腿长，换成相对 plantFoot 静止解的偏移，交给 `VRMMotion.plantFoot` 解 ——
    身材比例和演员不同（ぱペコ穿厚底鞋，踝更高），脚照样踩在地上、踩地期间不滑（离线核对：前后漂移 < 1 mm）。
- 速度：每段的地面速度 × 腿长 = 模型单位 / 秒，PetModelView 换成宠物窗点 / 秒（`gaitSpeeds`），引擎按这趟的走法挪窗口。

| 走法（`PetGait`） | 片段 | 什么时候 | 速度（腿长 / 秒） |
|---|---|---|---|
| `calm` | 女性化 | 平时：闲逛、走去空地待着 | 1.15 |
| `happy` | 开心 | 心情好：刚被摸 / 戳、来了通知、你回到电脑前（她从睡着醒来），之后 40 秒内开始的走路 | 1.78 |
| `playful` | 孩子气 | 「活泼」档自己溜达；「适中」档的闲逛约四次里一次 | 1.20 |

- 走法在**开始走的那一刻**挑（`PetEngine.pickGait`），走的途中不换；新的一趟换了走法，渲染层淡过去（0.25 s）。
- 赶路（挡住正在用的窗口要让开）还是跑步（`run`，程序化），速度按跑步步幅（`runSpeed`）。
- 读不到资源（或不是 VRM）时退回原来的程序化 `walk`，速度用 `VRMMotion.groundSpeed`。
- 斜着走的楼梯接进来之前，上下踩台阶先用平常的走路片段（`climb` 映射到 `walk_feminine`）。

## 4. 怎么加一种走法

1. 下载 BVH（同一数据集的别的风格，或骨架关节名一样的其它数据），跑
   `python3 mac/scripts/mocap/convert_bvh.py <in.bvh> mac/Sources/Resources/Motions/mocap-walk-<名字>.json`。
2. `VRMMocap.walks` 加一行片段名 → 资源名；`PetGait` 加一种、`PetModelView.gaitClipNames` 对上、`PetEngine.pickGait` 决定什么时候用。
3. 装上看一遍（或离线渲染侧面逐帧、带地面刻度的动图）：脚是否打滑、手臂是否穿过蓬袖子和裙子。
