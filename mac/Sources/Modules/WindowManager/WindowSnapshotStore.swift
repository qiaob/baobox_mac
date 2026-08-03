import AppKit

/// 一条窗口记录。frame 为 CG 全局坐标（与 AXWindow 同系）。
///
/// 多显示器：额外记录采集时所在显示器的 UUID 与窗口在该屏 visibleFrame 内的
/// 相对位置/尺寸（0–1）。恢复时原屏还在就按相对值还原 —— 分辨率、排列偏移变了也稳；
/// 原屏不在才退回绝对坐标 + 收敛到现有屏幕。两个字段可选，兼容旧数据。
struct WindowSnapshotEntry: Codable, Equatable {
    let bundleID: String
    let title: String
    let frameCG: CGRect
    let displayUUID: String?
    let relative: CGRect?
}

/// 一份完整的窗口布局快照。
struct WindowSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var entries: [WindowSnapshotEntry]
}

/// 布局快照：采集当前所有窗口的位置，之后一键恢复。
/// 存储走 Application Support/Baobox；操作低频，直接同步落盘（无防抖）。
@MainActor
final class WindowSnapshotStore: ObservableObject {
    @Published private(set) var snapshots: [WindowSnapshot] = []

    static var storeFile: URL { ClipboardStore.baseDir.appendingPathComponent("window_layouts.json") }

    init() {
        load()
    }

    func add(name: String, entries: [WindowSnapshotEntry]) {
        snapshots.append(WindowSnapshot(id: UUID(), name: name, createdAt: Date(), entries: entries))
        saveNow()
    }

    func delete(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
        saveNow()
    }

    // MARK: - 采集

    /// 采集所有常规 App 的非最小化标准窗口。不含 Baobox 自己（设置窗不值得记录）。
    static func captureCurrent() -> [WindowSnapshotEntry] {
        let screens = NSScreen.screens
        var out: [WindowSnapshotEntry] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            for window in AXWindow.windows(pid: app.processIdentifier) {
                guard AXWindow.isStandard(window), !AXWindow.isMinimized(window),
                      let frame = AXWindow.frameCG(of: window),
                      frame.width >= 60, frame.height >= 40 else { continue }

                // 记录所在显示器与屏内相对位置（交集最大的屏视为所在屏）。
                let frameAK = Geometry.appKitRect(fromCG: frame)
                var displayUUID: String?
                var relative: CGRect?
                if let screen = WindowLayout.targetScreen(forWindowAK: frameAK,
                                                          screens: screens,
                                                          mouseScreen: nil) {
                    displayUUID = Self.uuid(of: screen)
                    relative = Self.relativeRect(frameAK, in: screen.visibleFrame)
                }
                out.append(WindowSnapshotEntry(bundleID: bundleID,
                                               title: AXWindow.title(of: window) ?? "",
                                               frameCG: frame,
                                               displayUUID: displayUUID,
                                               relative: relative))
            }
        }
        return out
    }

    // MARK: - 恢复

    /// 恢复快照：按 bundleID 分组，先精确匹配标题，剩余按顺序兜底；
    /// 已退出的 App 静默跳过，frame 夹进当前屏幕布局。
    static func restore(_ snapshot: WindowSnapshot) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let byBundle = Dictionary(grouping: snapshot.entries, by: \.bundleID)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, let wanted = byBundle[bundleID] else { continue }

            var available: [(window: AXUIElement, title: String)] = AXWindow.windows(pid: app.processIdentifier)
                .filter { AXWindow.isStandard($0) && !AXWindow.isMinimized($0) }
                .map { ($0, AXWindow.title(of: $0) ?? "") }

            // 两遍匹配：先让有标题的记录认领同名窗口，避免无标题记录抢走别人的目标。
            var matches: [(AXUIElement, WindowSnapshotEntry)] = []
            var unresolved: [WindowSnapshotEntry] = []
            for entry in wanted {
                if !entry.title.isEmpty,
                   let index = available.firstIndex(where: { $0.title == entry.title }) {
                    matches.append((available.remove(at: index).window, entry))
                } else {
                    unresolved.append(entry)
                }
            }
            for entry in unresolved {
                guard !available.isEmpty else { break }
                matches.append((available.removeFirst().window, entry))
            }

            for (window, entry) in matches {
                apply(entry, to: window, screens: screens)
            }
        }
    }

    private static func apply(_ entry: WindowSnapshotEntry, to window: AXUIElement, screens: [NSScreen]) {
        // 原显示器仍接入：按屏内相对位置在其当前 visibleFrame 里还原，
        // 分辨率调整、排列（全局偏移）变化都不影响结果。
        if let uuid = entry.displayUUID, let relative = entry.relative,
           let screen = screens.first(where: { Self.uuid(of: $0) == uuid }) {
            let frameAK = absoluteRect(relative, in: screen.visibleFrame)
            let safeAK = WindowLayout.clamped(frameAK, into: screen.visibleFrame)
            AXWindow.setFrameCG(Geometry.cgRect(fromAppKit: safeAK), on: window)
            return
        }

        // 原显示器已不在（或旧数据无屏信息）：绝对坐标夹进交集最大的屏（游离时退回鼠标屏）。
        let frameAK = Geometry.appKitRect(fromCG: entry.frameCG)
        let mouse = NSEvent.mouseLocation
        let mouseScreen = screens.first { NSMouseInRect(mouse, $0.frame, false) }
        guard let target = WindowLayout.targetScreen(forWindowAK: frameAK,
                                                     screens: screens,
                                                     mouseScreen: mouseScreen) else { return }
        let safeAK = WindowLayout.clamped(frameAK, into: target.visibleFrame)
        AXWindow.setFrameCG(Geometry.cgRect(fromAppKit: safeAK), on: window)
    }

    // MARK: - 显示器标识与相对坐标

    /// 显示器持久标识。CGDirectDisplayID 重启/重插可能变化，UUID 才稳定。
    private static func uuid(of screen: NSScreen) -> String? {
        guard let displayID = screen.displayID,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String?
    }

    private static func relativeRect(_ frameAK: NSRect, in visible: NSRect) -> CGRect? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(x: (frameAK.minX - visible.minX) / visible.width,
                      y: (frameAK.minY - visible.minY) / visible.height,
                      width: frameAK.width / visible.width,
                      height: frameAK.height / visible.height)
    }

    private static func absoluteRect(_ relative: CGRect, in visible: NSRect) -> NSRect {
        NSRect(x: visible.minX + relative.minX * visible.width,
               y: visible.minY + relative.minY * visible.height,
               width: relative.width * visible.width,
               height: relative.height * visible.height)
    }

    // MARK: - 持久化

    private func saveNow() {
        try? FileManager.default.createDirectory(at: ClipboardStore.baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshots) {
            try? data.write(to: Self.storeFile)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([WindowSnapshot].self, from: data) {
            snapshots = decoded
        }
    }
}
