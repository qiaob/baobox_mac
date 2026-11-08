"""把一段 BVH 走路截成一个完整步态循环，换算到「规范化人形空间」（+X 人物左、+Y 上、+Z 前，T 字姿势 = 单位旋转），
长度按腿长归一化。输出 JSON：每帧 hips 位移、躯干 / 手臂的世界旋转、两只脚的踝位置与脚掌角度、地面速度。
腿交给 App 里的 plantFoot（IK）按踝位置解，脚踩地不打滑。设计与数据来源见 docs/desktop-pet/MOCAP.md。

用法（需要 numpy、scipy）：
    python3 convert_bvh.py <in.bvh> <out.json> [第几次左脚着地开始，默认取片段正中间那一步]
骨架按万代南梦宫研究所动捕数据集（Bandai-Namco-Research-Motiondataset）的关节名写的。"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bvh import BVH


def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-9)


def frame(a, b, a0, b0):
    """把静止时的 (a0, b0) 转到 (a, b) 的旋转（a 精确对齐，b 正交化）。返回四元数 (x, y, z, w)。"""
    from scipy.spatial.transform import Rotation as R

    a = unit(a)
    b = unit(b - (np.sum(b * a, axis=-1, keepdims=True)) * a)
    c = np.cross(a, b)
    a0 = unit(np.asarray(a0, float))
    b0 = unit(np.asarray(b0, float) - np.dot(b0, a0) * a0)
    c0 = np.cross(a0, b0)
    cur = np.stack([a, b, c], axis=-1)  # (F, 3, 3) 列向量
    rest = np.stack([a0, b0, c0], axis=-1)  # (3, 3)
    m = cur @ rest.T
    return R.from_matrix(m).as_quat()


def heel_strikes(ankle, dt, speed):
    s = np.linalg.norm(np.diff(ankle[:, [0, 2]], axis=0), axis=1) / dt
    stance = s < 0.25 * speed
    out, swing = [], 0
    for k in range(1, len(stance)):
        if not stance[k]:
            swing += 1
        elif swing >= 6:  # 摆动够久才算一次着地（去掉脚跟→脚尖的二次触地）
            out.append(k)
            swing = 0
    return out


def main(path, out, cycles=1, pick=None):
    b = BVH(path)
    pos, rot = b.fk()
    I = b.index
    dt = b.dt
    hips_w = pos[:, I["Hips"]]
    med_speed = np.median(
        np.linalg.norm(np.diff(hips_w[:, [0, 2]], axis=0), axis=1) / dt
    )
    strikes = heel_strikes(pos[:, I["Foot_L"]], dt, med_speed)
    mid = len(b.frames) / 2
    if pick is None:
        k = min(
            range(len(strikes) - cycles),
            key=lambda i: abs((strikes[i] + strikes[i + cycles]) / 2 - mid),
        )
    else:
        k = pick
    f0, f1 = strikes[k], strikes[k + cycles]
    F = f1 - f0
    # 规范化坐标轴：前 = 这一段 hips 的水平位移方向。
    d = hips_w[f1] - hips_w[f0]
    d[1] = 0
    fwd = d / np.linalg.norm(d)
    up = np.array([0.0, 1.0, 0.0])
    left = np.cross(up, fwd)
    M = np.stack([left, up, fwd])  # 规范化 = M @ 世界
    P = np.einsum("ij,fkj->fki", M, pos[f0 : f1 + 1])
    Rw = np.einsum("ij,fkjl->fkil", M, rot[f0 : f1 + 1])  # 世界旋转换到规范化坐标
    t = np.arange(F + 1) / F
    drift = P[F, I["Hips"]] - P[0, I["Hips"]]
    P = P - t[:, None, None] * drift[None, None, :]  # 原地 + 首尾闭合
    speed = drift[2] / (F * dt)
    ground = min(P[:F, I["Toes_L"], 1].min(), P[:F, I["Toes_R"], 1].min())
    P[..., 1] -= ground
    cx, cz = P[:F, I["Hips"], 0].mean(), P[:F, I["Hips"], 2].mean()
    P[..., 0] -= cx
    P[..., 2] -= cz
    L = np.linalg.norm(b.offsets[I["LowerLeg_L"]]) + np.linalg.norm(
        b.offsets[I["Foot_L"]]
    )
    hip_drop = -b.offsets[I["UpperLeg_L"]][
        0
    ]  # hips 关节比腿根高多少（hips 局部 X 朝上）
    ankle_h = min(P[:F, I["Foot_L"], 1].min(), P[:F, I["Foot_R"], 1].min())
    hips_ref = ankle_h + L + hip_drop  # 腿伸直站着时 hips 的高度
    P = P[:F]
    Rw = Rw[:F]
    g = lambda n: P[:, I[n]]
    res = {
        "source": path.split("/")[-1],
        "license": "CC BY-NC 4.0, Bandai Namco Research Inc. (Bandai-Namco-Research-Motiondataset)",
        "frames": int(F),
        "fps": round(1 / dt),
        "speed": round(float(speed / L), 5),
        "range": [int(f0), int(f1)],
    }
    hips = g("Hips").copy()
    hips[:, 1] -= hips_ref
    res["hips"] = (hips / L).round(5).tolist()
    # 躯干
    pelvis_left = unit(g("UpperLeg_L") - g("UpperLeg_R"))
    pelvis_up = unit(g("Spine") - g("Hips"))
    chest_left = unit(Rw[:, I["Chest"]] @ np.array([0, 0, 1.0]))
    head_x = Rw[:, I["Head"]] @ np.array([1.0, 0, 0])
    head_z = Rw[:, I["Head"]] @ np.array([0, 0, 1.0])
    head_y = Rw[:, I["Head"]] @ np.array([0, 1.0, 0])
    lat = (
        head_z
        if abs(np.mean(np.sum(head_z * chest_left, 1)))
        > abs(np.mean(np.sum(head_y * chest_left, 1)))
        else head_y
    )
    lat = lat * np.sign(np.mean(np.sum(lat * chest_left, 1)))

    def level(up):
        """把这根骨骼一个周期里的平均朝向扳回竖直（只去掉骨架本身的前后 / 左右歪，周期里的晃动保留）。"""
        from scipy.spatial.transform import Rotation as R

        mean = unit(np.mean(up, axis=0))
        axis = np.cross(mean, [0, 1.0, 0])
        angle = np.arcsin(min(np.linalg.norm(axis), 1.0))
        if np.linalg.norm(axis) < 1e-9:
            return np.eye(3)
        return R.from_rotvec(unit(axis) * angle).as_matrix()

    neck_up = unit(g("Head") - g("Neck"))
    fix_neck = level(neck_up)
    fix_head = level(unit(head_x))
    rots = {
        "hips": frame(pelvis_left, pelvis_up, [1, 0, 0], [0, 1, 0]),
        "spine": frame(
            unit(g("Chest") - g("Spine")),
            pelvis_left + chest_left,
            [0, 1, 0],
            [1, 0, 0],
        ),
        "chest": frame(unit(g("Neck") - g("Chest")), chest_left, [0, 1, 0], [1, 0, 0]),
        "neck": frame(
            neck_up @ fix_neck.T, chest_left @ fix_neck.T, [0, 1, 0], [1, 0, 0]
        ),
        "head": frame(
            unit(head_x) @ fix_head.T, lat @ fix_head.T, [0, 1, 0], [1, 0, 0]
        ),
    }
    chest_up = unit(g("Neck") - g("Chest"))
    chest_fwd = np.cross(chest_left, chest_up)
    for side, sgn in (("L", 1.0), ("R", -1.0)):
        name = "left" if side == "L" else "right"
        upper = g("LowerArm_" + side) - g("UpperArm_" + side)
        fore = g("Hand_" + side) - g("LowerArm_" + side)
        bend = unit(np.cross(unit(upper), unit(fore)) + 0.05 * (-sgn) * chest_up)
        hand = Rw[:, I["Hand_" + side]] @ np.array([sgn, 0, 0])
        rest_dir, rest_bend = [sgn, 0, 0], [0, -sgn, 0]
        rots[name + "Shoulder"] = frame(
            g("UpperArm_" + side) - g("Shoulder_" + side),
            chest_fwd,
            rest_dir,
            [0, 0, 1],
        )
        rots[name + "UpperArm"] = frame(upper, bend, rest_dir, rest_bend)
        rots[name + "LowerArm"] = frame(fore, bend, rest_dir, rest_bend)
        rots[name + "Hand"] = frame(hand, bend, rest_dir, rest_bend)
    res["rot"] = {k: v.round(5).tolist() for k, v in rots.items()}
    # 脚：踝位置（相对「脚掌放平时的踝高」）与脚掌角度（正 = 脚跟抬起）
    res["ankle"], res["toe"] = {}, {}
    for side in "LR":
        name = "left" if side == "L" else "right"
        a = g("Foot_" + side).copy()
        f = g("Toes_" + side) - g("Foot_" + side)
        pitch = np.degrees(np.arctan2(-f[:, 1], np.linalg.norm(f[:, [0, 2]], axis=1)))
        flat = a[:, 1] < ankle_h + 0.6  # 踝在最低处附近 = 脚掌放平
        pitch_flat = np.median(pitch[flat]) if flat.any() else np.median(pitch)
        a[:, 1] -= ankle_h
        res["ankle"][name] = (a / L).round(5).tolist()
        res["toe"][name] = (pitch - pitch_flat).round(2).tolist()

    # 诊断：躯干平均前倾（度）
    def lean(v):
        return float(np.degrees(np.mean(np.arctan2(v[:, 2], v[:, 1]))))

    res["diag"] = {
        "pelvis_up_lean": lean(pelvis_up),
        "spine_lean": lean(unit(g("Chest") - g("Spine"))),
        "chest_lean": lean(chest_up),
        "neck_lean": lean(unit(g("Head") - g("Neck"))),
        "head_lean": lean(unit(head_x)),
        "speed_cm_s": float(speed),
        "leg_cm": float(L),
        "cycle_s": float(F * dt),
        "step_width_cm": float(np.mean(np.abs(a[:, 0]))),
    }
    with open(out, "w") as f:
        json.dump(res, f, separators=(",", ":"))
    print(
        out.split("/")[-1],
        "frames",
        F,
        "cycle %.2fs" % (F * dt),
        "speed %.2f leg/s" % (speed / L),
        {k: round(v, 1) for k, v in res["diag"].items()},
    )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], pick=int(sys.argv[3]) if len(sys.argv) > 3 else None)
