import AppKit
import CoreGraphics

/// 一个能站的窗口顶边（屏幕坐标，左下角原点）。
struct PetLedge {
    let id: CGWindowID
    /// 窗口的位置大小。
    let frame: NSRect
    /// 顶边上没被前面窗口挡住、上方也没被挡住的若干段（x 范围）。
    let segments: [ClosedRange<CGFloat>]

    func segment(containing x: CGFloat) -> ClosedRange<CGFloat>? {
        segments.first { $0.contains(x) }
    }
}

/// 屏幕上的一个普通 App 窗口（找空地时判断宠物挡住了谁，docs/desktop-pet/SETTLE.md §3）。
struct PetWindowInfo {
    let id: CGWindowID
    /// 屏幕坐标，左下角原点。
    let frame: NSRect
    let pid: pid_t
}

/// 看屏幕上的 App 窗口，算出宠物能站的顶边（docs/desktop-pet/ROAM.md §2.1），顺带交出所有窗口的位置与所属 App。
/// 只读窗口的位置与前后层级（`CGWindowListCopyWindowInfo`），不读标题和内容，不需要额外权限。
/// 平时每秒刷一次；宠物站在窗口上 / 正在跳时每秒 10 次，窗口被拖动时跟得上。
@MainActor
final class PetWindowWatcher {
    private(set) var ledges: [PetLedge] = []
    /// 普通 App 窗口，从前往后（不含 Baobox 自己的）。
    private(set) var windows: [PetWindowInfo] = []
    private var timer: Timer?
    private var interval: TimeInterval = 0

    /// 宠物在窗口上 / 正在跳：刷得勤一些。
    var fast = false {
        didSet { if fast != oldValue, timer != nil { schedule() } }
    }

    var isRunning: Bool { timer != nil }

    func start() {
        refresh()
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ledges = []
        windows = []
    }

    private func schedule() {
        let wanted: TimeInterval = fast ? 0.1 : 1
        guard timer == nil || interval != wanted else { return }
        timer?.invalidate()
        interval = wanted
        let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        (ledges, windows) = Self.read()
    }

    /// 窗口列表从前往后：每个窗口的顶边减去它前面那些窗口挡住的部分（顶边本身和上方一小段都要空着）。
    private static func read() -> ([PetLedge], [PetWindowInfo]) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first else { return ([], []) }
        let primaryHeight = primary.frame.height
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrames = NSScreen.screens.map(\.frame)
        var occluders: [NSRect] = []
        var result: [PetLedge] = []
        var windows: [PetWindowInfo] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1 else { continue }
            // CG 的窗口坐标原点在主屏左上角、y 朝下。
            let frame = NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            if frame.width >= 40, frame.height >= 30 { windows.append(PetWindowInfo(id: number, frame: frame, pid: pid)) }
            defer { occluders.append(frame) }
            // 太小的（工具条、弹窗）、全屏的不站。
            guard frame.width >= 160, frame.height >= 100,
                  !screenFrames.contains(where: { abs($0.minX - frame.minX) < 1 && abs($0.maxY - frame.maxY) < 1
                                                  && abs($0.width - frame.width) < 1 }) else { continue }
            var segments: [ClosedRange<CGFloat>] = [frame.minX...frame.maxX]
            for front in occluders where front.minY <= frame.maxY + 40 && front.maxY >= frame.maxY - 2 {
                segments = subtract(front.minX...front.maxX, from: segments)
            }
            segments = segments.filter { $0.upperBound - $0.lowerBound >= 50 }
            if !segments.isEmpty { result.append(PetLedge(id: number, frame: frame, segments: segments)) }
        }
        return (result, windows)
    }

    private static func subtract(_ cut: ClosedRange<CGFloat>, from segments: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        segments.flatMap { segment -> [ClosedRange<CGFloat>] in
            guard cut.overlaps(segment) else { return [segment] }
            var pieces: [ClosedRange<CGFloat>] = []
            if cut.lowerBound > segment.lowerBound { pieces.append(segment.lowerBound...cut.lowerBound) }
            if cut.upperBound < segment.upperBound { pieces.append(cut.upperBound...segment.upperBound) }
            return pieces
        }
    }
}
