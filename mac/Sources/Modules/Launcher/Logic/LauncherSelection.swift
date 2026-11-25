import Foundation

// 快速入口的选中行（docs/launcher/TECH_DESIGN.md §4「选中行」，PR 11 复查后定）：列表换了一批行之后选中哪一行。
// 规则只有一条：这次输入以来用户没有手动选过行 → 选中永远在第一行；手动选过 → 选中留在他选的那一行上
// （按行 id 跟着走；那一行没了才回到第一行）。所有「后台结果回来后刷新」的地方（文件、路径、后台建好搜索键、图片识别结果）
// 都用这一条。不再用「选中的是不是第 0 行」来推断用户的意思 —— 那样会出两种错：
// - 输入 `plan.txt`，扫的目录里只有 `plan.txt.bak`：内存来源先交的普通文件行把选中带到了第 1 行，Spotlight 带来固定行时
//   被当成「用户挪过」不跟过去，⏎ 去上网搜而不是打开文件；
// - 用户按 ↓ 再按 ↑ 回到第 0 行（那是手动选的），固定行来了却把选中拉走。
// 纯逻辑，进 BaoboxTests；面板模型（`LauncherPanelModel`）包一层。

/// 选中哪一行、这次输入以来用户手动选过没有。
struct LauncherSelectionState: Equatable, Sendable {
    /// 选中第几行。
    private(set) var index = 0
    /// 这次输入以来用户手动选过行：按过 ↑ ↓、鼠标悬停换了一行。输入一变就清零。
    private(set) var isManual = false

    /// 列表换了一批行（`oldIDs` → `newIDs`，行 id）。返回列表要不要回到顶上。
    /// - `newInput`（输入变了、挂上 / 去掉了图片）：第一行，手动选过的标记清零，回到顶上。
    /// - 后台结果回来（同一个输入）：没手动选过 → 第一行（第一行换了一个才回到顶上，不然不动滚动位置）；
    ///   手动选过 → 按行 id 留在他选的那一行；那一行没了 → 第一行，不再算手动选过（他选的已经不在了）。
    mutating func rowsChanged(from oldIDs: [String], to newIDs: [String], newInput: Bool) -> Bool {
        let previous = oldIDs.indices.contains(index) ? oldIDs[index] : nil
        if newInput {
            isManual = false
            index = 0
            return true
        }
        if isManual, let previous, let kept = newIDs.firstIndex(of: previous) {
            index = kept
            return false
        }
        isManual = false
        index = 0
        return previous != newIDs.first
    }

    /// ↑ ↓：到头不循环。按了就算手动选过（到头了没动也算：他表示了要这一行）。
    mutating func move(by delta: Int, rowCount: Int) {
        guard rowCount > 0 else { return }
        index = min(max(0, index + delta), rowCount - 1)
        isManual = true
    }

    /// 鼠标悬停（真的动过的鼠标）停在第 `row` 行上：换了一行才算手动选过。
    mutating func hover(_ row: Int, rowCount: Int) {
        guard (0..<rowCount).contains(row), row != index else { return }
        index = row
        isManual = true
    }
}
