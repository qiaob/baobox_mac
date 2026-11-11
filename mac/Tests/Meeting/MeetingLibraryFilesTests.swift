import Foundation
import XCTest

/// 会议库的磁盘布局、索引重建 / 对账、旧实时翻译记录的导入（docs/meeting/TECH_DESIGN.md §4）。扫目录的用临时目录。
final class MeetingLibraryFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baobox-meeting-tests-\(UUID().uuidString)",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func meta(id: String, title: String, start: Date, status: MeetingStatus = .summarized) throws -> String {
        let data = try XCTUnwrap(MeetingMeta(id: id, type: .online, title: title, start: start, status: status).encoded())
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - 布局

    func testFolderNamesStartWithTheLocalTimeAndACleanTitle() {
        XCTAssertEqual(MeetingLibraryLayout.folderName(start: localDate(14, 5, 59), title: "设计评审"), "2026-11-10 14-05 设计评审")
        XCTAssertEqual(MeetingLibraryLayout.folderName(start: localDate(14, 5, 0), title: " / : "), "2026-11-10 14-05")
        XCTAssertEqual(MeetingLibraryLayout.yearFolder(for: localDate(14, 5, 0)), "2026")
    }

    func testSanitizedTitleRemovesWhatFileSystemsDoNotLike() {
        XCTAssertEqual(MeetingLibraryLayout.sanitizedTitle("A/B:C*D?\"E\"<F>|G\\H"), "A B C D E F G H")
        XCTAssertEqual(MeetingLibraryLayout.sanitizedTitle("  ..隐藏\n\t文件  "), "隐藏 文件")
        XCTAssertEqual(MeetingLibraryLayout.sanitizedTitle(String(repeating: "长", count: 70)), String(repeating: "长", count: 60))
    }

    func testDatesAndTitlesReadBackFromFolderAndLegacyFileNames() {
        XCTAssertEqual(MeetingLibraryLayout.date(fromFolderName: "2026-11-10 14-05 设计评审"), localDate(14, 5, 0))
        XCTAssertEqual(MeetingLibraryLayout.title(fromFolderName: "2026-11-10 14-05 设计评审"), "设计评审")
        XCTAssertNil(MeetingLibraryLayout.date(fromFolderName: "设计评审"))
        XCTAssertEqual(MeetingLibraryLayout.title(fromFolderName: "设计评审"), "设计评审")
        XCTAssertEqual(MeetingLibraryLayout.date(fromLegacyFileName: "2026-11-10 14-05-30.md"), localDate(14, 5, 30))
        XCTAssertNil(MeetingLibraryLayout.date(fromLegacyFileName: "notes.md"))
    }

    func testUniqueAddsANumberWhenTheNameIsTaken() {
        XCTAssertEqual(MeetingLibraryLayout.unique("周会") { _ in false }, "周会")
        let taken: Set<String> = ["周会", "周会 (2)"]
        XCTAssertEqual(MeetingLibraryLayout.unique("周会") { taken.contains($0) }, "周会 (3)")
    }

    // MARK: - 扫目录

    func testDirectoriesAreYearFoldersWithAMetaOrAMarkdown() throws {
        try write(try meta(id: "a", title: "周会", start: localDate(10, 0, 0)), to: "2026/2026-11-10 10-00 周会/meta.json")
        try write("# 只有转录", to: "2026/2026-11-10 11-00 线下会议/meeting.md")
        try write("x", to: "2026/2026-11-10 12-00 空的/别的文件.txt")
        try write("x", to: "2026/.hidden/meta.json")
        try write("x", to: "weekly/2026-W46.md")
        try write("x", to: "202x/2026-11-10 10-00 周会/meta.json")

        XCTAssertEqual(MeetingLibraryScanner.directories(root: root),
                       ["2026/2026-11-10 10-00 周会", "2026/2026-11-10 11-00 线下会议"])
    }

    func testRecordRepairsMissingFieldsFromTheFolder() throws {
        try write("{\"type\": \"offline\"}", to: "2026/2026-11-10 10-00 周会/meta.json")
        try write("# 转录", to: "2026/2026-11-10 11-00 线下会议/meeting.md")
        try write("写坏了", to: "2026/2026-11-10 12-00 坏的/meta.json")

        let repaired = try XCTUnwrap(MeetingLibraryScanner.record(root: root, dir: "2026/2026-11-10 10-00 周会"))
        XCTAssertEqual(repaired.id, "2026/2026-11-10 10-00 周会", "缺 id 用目录路径")
        XCTAssertEqual(repaired.meta.start, localDate(10, 0, 0))
        XCTAssertEqual(repaired.meta.title, "周会")
        XCTAssertEqual(repaired.meta.type, .offline)

        let markdownOnly = try XCTUnwrap(MeetingLibraryScanner.record(root: root, dir: "2026/2026-11-10 11-00 线下会议"))
        XCTAssertEqual(markdownOnly.meta.type, .free)
        XCTAssertEqual(markdownOnly.meta.status, .transcribed)
        XCTAssertEqual(markdownOnly.meta.template, "content")
        XCTAssertEqual(markdownOnly.meta.title, "线下会议")

        XCTAssertNil(MeetingLibraryScanner.record(root: root, dir: "2026/2026-11-10 12-00 坏的"), "meta 坏了也没有 meeting.md")
        XCTAssertNil(MeetingLibraryScanner.record(root: root, dir: "2026/不存在"))
    }

    func testRebuildAndReconcileFollowTheDisk() throws {
        try write(try meta(id: "a", title: "早的", start: localDate(9, 0, 0)), to: "2026/2026-11-10 09-00 早的/meta.json")
        try write(try meta(id: "b", title: "晚的", start: localDate(15, 0, 0)), to: "2026/2026-11-10 15-00 晚的/meta.json")
        let rebuilt = MeetingLibraryScanner.rebuild(root: root)
        XCTAssertEqual(rebuilt.map(\.id), ["b", "a"], "新的在前")

        let gone = MeetingRecord(dir: "2026/2026-11-09 10-00 删掉了", meta: MeetingMeta(id: "gone", type: .online, title: "删掉了",
                                                                                     start: localDate(10, 0, 0, day: 9)))
        let (records, changed) = MeetingLibraryScanner.reconcile([rebuilt[1], gone], root: root)
        XCTAssertTrue(changed)
        XCTAssertEqual(records.map(\.id), ["b", "a"], "目录没了的去掉，磁盘上多的读进来")
        XCTAssertFalse(MeetingLibraryScanner.reconcile(rebuilt, root: root).changed)
    }

    func testIndexRoundTripsAndABrokenElementMeansRebuild() throws {
        let records = [MeetingRecord(dir: "2026/x", meta: MeetingMeta(id: "x", type: .offline, title: "x", start: localDate(10, 0, 0)))]
        let data = try XCTUnwrap(MeetingLibraryScanner.encodeIndex(records))
        XCTAssertEqual(MeetingLibraryScanner.decodeIndex(data), records)
        XCTAssertNil(MeetingLibraryScanner.decodeIndex(Data("{}".utf8)), "不是数组")
        XCTAssertEqual(MeetingLibraryScanner.decodeIndex(Data("[]".utf8)), [])
    }

    func testSortedIsNewestFirstThenByFolder() {
        let a = MeetingRecord(dir: "2026/a", meta: MeetingMeta(id: "a", type: .online, title: "a", start: localDate(10, 0, 0)))
        let b = MeetingRecord(dir: "2026/b", meta: MeetingMeta(id: "b", type: .online, title: "b", start: localDate(10, 0, 0)))
        let c = MeetingRecord(dir: "2026/c", meta: MeetingMeta(id: "c", type: .online, title: "c", start: localDate(11, 0, 0)))
        XCTAssertEqual(MeetingLibraryScanner.sorted([a, c, b]).map(\.id), ["c", "b", "a"])
    }

    // MARK: - 旧记录导入

    func testLegacyHeaderGivesTheEndTimeAndWhetherMinutesWereWritten() {
        let content = """
        # 实时翻译记录 2026-11-01 09:30

        - 开始：2026-11-01 09:30:00
        - 结束：2026-11-01 09:45:10（15分10秒）
        - 音源：麦克风

        ## 纪要

        ### 要点
        - 一条

        ## 记录

        - 2026-11-01 10:00:00 这行在正文里，不算
        """
        let parsed = MeetingLegacyImporter.parse(content: content)
        XCTAssertEqual(parsed.end, localDate(9, 45, 10, day: 1))
        XCTAssertTrue(parsed.summarized)
        let unfinished = MeetingLegacyImporter.parse(content: "- Started: 2026-11-01 09:30:00\n\n## Transcript\n")
        XCTAssertNil(unfinished.end)
        XCTAssertFalse(unfinished.summarized)
    }

    func testLegacyScanReadsTopLevelMarkdownFiles() throws {
        try write("- 开始：2026-11-01 09:30:00\n- 结束：2026-11-01 09:40:00\n\n### Key points\n", to: "legacy/2026-11-01 09-30-00.md")
        try write("x", to: "legacy/不是 md.txt")
        try write("x", to: "legacy/.hidden.md")
        try write("x", to: "legacy/sub/2026-11-02 09-30-00.md")

        let items = MeetingLegacyImporter.scan(folder: root.appendingPathComponent("legacy", isDirectory: true))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.start, localDate(9, 30, 0, day: 1))
        XCTAssertEqual(items.first?.end, localDate(9, 40, 0, day: 1))
        XCTAssertEqual(items.first?.summarized, true)
        XCTAssertTrue(items.first?.path.hasSuffix("legacy/2026-11-01 09-30-00.md") ?? false)
        XCTAssertEqual(MeetingLegacyImporter.scan(folder: root.appendingPathComponent("没有这个目录")), [])
    }
}
