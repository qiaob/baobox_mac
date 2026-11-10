import Foundation

/// 自由听译的记录进会议库（docs/meeting/ENGINE.md §4.5.3、docs/meeting/TECH_DESIGN.md §2.3）。
/// 引擎决定记不记、什么时候记；会议库决定写到哪、写成什么样、整理不整理纪要。
/// MeetingStore 实现；装配时（`AppDelegate.meetingEngine`）作为构造参数交给引擎，引擎开的每个会话都带着它（ENGINE.md §4.6）。
///
/// **纯 Foundation**：同目录的约定（见 MeetingEngineTypes.swift）。
@MainActor
protocol FreeListeningLibrary: AnyObject {
    /// 会议库根目录（设置页「保存位置」、字幕条「打开记录文件夹」）。
    var folderURL: URL { get }
    /// 开一份新记录：会议库里新的一条（记下第一句才登记进索引，一句没有不留痕迹）。
    /// `summarizes` = 此刻「停止后整理纪要」开着（决定记录里先写不写纪要占位）。
    func beginFreeListeningRecord(start: Date, run: MeetingEngineRun, summarizes: Bool) -> FreeListeningRecord
}

/// 一份正在写的自由听译记录（MeetingTranscript 实现）。
@MainActor
protocol FreeListeningRecord: AnyObject {
    /// 记录文件（字幕条「打开本次记录」）。
    var fileURL: URL { get }
    /// 写盘失败时回调一次，参数是给用户看的一行提示（已本地化）。
    var onWriteError: ((String) -> Void)? { get set }
    /// 记下 / 更新一句（同一 `key` 后到的覆盖先到的）。
    func update(_ line: MeetingEngineLine)
    /// 改设置后的重启接着写：设置真变了才记一行「改为：…」。
    func continueWith(_ run: MeetingEngineRun, at time: Date)
    /// 收尾。`summarizes` = 此刻的「停止后整理纪要」（收尾时现读）；`terminating` = App 退出：同步写完、纪要标「没整理完」。
    func finish(at time: Date, terminating: Bool, summarizes: Bool)
}
