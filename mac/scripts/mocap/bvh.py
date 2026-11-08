"""BVH 解析 + 正向运动学（numpy / scipy）。只读文本里的数字，不执行任何东西。"""

import numpy as np
from scipy.spatial.transform import Rotation as R


class BVH:
    def __init__(self, path):
        with open(path) as f:
            tokens = f.read().split()
        self.names, self.parents, self.offsets, self.channels = [], [], [], []
        stack, i, end_site = [], 0, False
        while tokens[i] != "MOTION":
            t = tokens[i]
            if t in ("ROOT", "JOINT"):
                self.names.append(tokens[i + 1])
                self.parents.append(stack[-1] if stack else -1)
                self.offsets.append(np.zeros(3))
                self.channels.append([])
                i += 2
            elif t == "End":
                end_site = True
                i += 2
            elif t == "{":
                stack.append(-2 if end_site else len(self.names) - 1)
                end_site = False
                i += 1
            elif t == "}":
                stack.pop()
                i += 1
            elif t == "OFFSET":
                if stack[-1] >= 0:
                    self.offsets[stack[-1]] = np.array(
                        [float(x) for x in tokens[i + 1 : i + 4]]
                    )
                i += 4
            elif t == "CHANNELS":
                n = int(tokens[i + 1])
                self.channels[stack[-1]] = tokens[i + 2 : i + 2 + n]
                i += 2 + n
            else:
                i += 1
        n_frames = int(tokens[i + 2])
        self.dt = float(tokens[i + 5])
        values = np.array([float(x) for x in tokens[i + 6 :]])
        width = sum(len(c) for c in self.channels)
        self.frames = values[: n_frames * width].reshape(n_frames, width)
        self.index = {n: k for k, n in enumerate(self.names)}

    def fk(self):
        """每帧每个关节的世界位置 (F, J, 3) 与世界旋转矩阵 (F, J, 3, 3)。"""
        F, J = len(self.frames), len(self.names)
        pos = np.zeros((F, J, 3))
        rot = np.zeros((F, J, 3, 3))
        col = 0
        cols = []
        for ch in self.channels:
            cols.append(col)
            col += len(ch)
        for j in range(J):
            ch = self.channels[j]
            c0 = cols[j]
            trans = np.tile(self.offsets[j], (F, 1))
            order, angles = "", []
            for k, name in enumerate(ch):
                if name.endswith("position"):
                    trans[:, "XYZ".index(name[0])] = self.frames[:, c0 + k]
                else:
                    order += name[0]
                    angles.append(self.frames[:, c0 + k])
            local = (
                R.from_euler(order, np.stack(angles, axis=1), degrees=True).as_matrix()
                if order
                else np.tile(np.eye(3), (F, 1, 1))
            )
            p = self.parents[j]
            if p < 0:
                pos[:, j] = trans
                rot[:, j] = local
            else:
                pos[:, j] = pos[:, p] + np.einsum("fij,fj->fi", rot[:, p], trans)
                rot[:, j] = rot[:, p] @ local
        return pos, rot
