import Foundation
import XCTest

/// 快速入口的查询耗时（docs/launcher/TECH_DESIGN.md §5.2 的预算：Release 下 5000 个候选一次查询 ≤ 5 ms）。
/// 单元测试是 Debug 编译、比 Release 慢一个数量级，这里只用宽松上限防退化；实测的中位数打印在日志里（`LAUNCHER_PERF`）。
final class LauncherRankingPerformanceTests: XCTestCase {

    func testQueryOverFiveThousandCandidates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var start = DispatchTime.now().uptimeNanoseconds
        let candidates = LauncherPerfFixture.candidates(pinyinForClipboard: true)
        let buildWithPinyin = LauncherPerfFixture.milliseconds(since: start)
        start = DispatchTime.now().uptimeNanoseconds
        _ = LauncherPerfFixture.candidates(pinyinForClipboard: false)
        let buildWithoutClipboardPinyin = LauncherPerfFixture.milliseconds(since: start)
        XCTAssertEqual(candidates.count, 5000)
        let records = LauncherPerfFixture.records(for: candidates, now: now)

        var medians: [Double] = []
        var lines: [String] = []
        for query in LauncherPerfFixture.queries {
            var times: [Double] = []
            var matched = 0
            for _ in 0..<9 {
                let begin = DispatchTime.now().uptimeNanoseconds
                let result = LauncherRanking.rank(candidates, query: query, records: records, now: now)
                times.append(LauncherPerfFixture.milliseconds(since: begin))
                matched = result.items.count
            }
            let median = LauncherPerfFixture.median(times)
            medians.append(median)
            lines.append(String(format: "「%@」=%.2fms(%ld)", query, median, matched))
            XCTAssertLessThanOrEqual(median, 50, "查询「\(query)」的中位数 \(median) ms 超过 Debug 下的宽松上限")
        }
        print(String(format: "LAUNCHER_PERF build(pinyin all)=%.0fms build(no clipboard pinyin)=%.0fms "
                     + "median-of-medians=%.2fms max=%.2fms",
                     buildWithPinyin, buildWithoutClipboardPinyin,
                     LauncherPerfFixture.median(medians), medians.max() ?? 0))
        print("LAUNCHER_PERF " + lines.joined(separator: " "))
    }
}

/// 造 5000 个像真实数据的候选：App 300、命令 150、片段 550、剪贴板 4000，中英文混合，长度像 App 名和剪贴板文本。
/// 用固定种子，每次一样。
enum LauncherPerfFixture {

    /// 空查询 = 全部命中、只按使用分排（空输入时的建议走这条），是排序量最大的情况。
    static let queries = [
        "", "s", "sa", "saf", "chrome", "vsc", "wx", "weixin", "微信", "截图", "docker", "jie", "会议记录",
        "zzqx", "summarize the clipboard",
    ]

    static func candidates(pinyinForClipboard: Bool) -> [LauncherCandidate] {
        var rng = LauncherSeededGenerator(seed: 2026)
        var result: [LauncherCandidate] = []
        result.reserveCapacity(5000)

        for index in 0..<300 {
            let base = appNames[index % appNames.count]
            let name = index < appNames.count ? base : "\(base) \(appSuffixes[(index / appNames.count) % appSuffixes.count])"
            result.append(LauncherCandidate(sourceID: "apps", entryID: "app\(index)",
                                            searchKeys: [LauncherSearchKey(name)]))
        }
        for index in 0..<150 {
            let title = commandVerbs[index % commandVerbs.count] + commandObjects[index / commandVerbs.count % commandObjects.count]
            let keyword = "\(englishWords[index % englishWords.count]) \(englishWords[(index * 7) % englishWords.count])"
            result.append(LauncherCandidate(sourceID: "commands", entryID: "cmd\(index)",
                                            searchKeys: [LauncherSearchKey(title), LauncherSearchKey(keyword)]))
        }
        for index in 0..<550 {
            let title = text(length: 4 + Int(rng.next() % 12), using: &rng)
            let body = text(length: 30 + Int(rng.next() % 60), using: &rng)
            result.append(LauncherCandidate(sourceID: "snippets", entryID: "snip\(index)",
                                            searchKeys: [LauncherSearchKey(title), LauncherSearchKey(body)]))
        }
        for index in 0..<4000 {
            let body = text(length: 20 + Int(rng.next() % 181), using: &rng)
            result.append(LauncherCandidate(sourceID: "clipboard", entryID: "clip\(index)",
                                            searchKeys: [LauncherSearchKey(body, pinyin: pinyinForClipboard)]))
        }
        return result
    }

    /// 给前 200 个候选记一些使用，让排序真的去算使用分。
    static func records(for candidates: [LauncherCandidate], now: Date) -> LauncherUsageRecords {
        var records = LauncherUsageRecords()
        for (index, candidate) in candidates.prefix(200).enumerated() {
            for _ in 0...(index % 5) {
                records.recordUse(of: candidate.key, at: now.addingTimeInterval(-Double(index) * 3600))
            }
        }
        records.recordChoice("apps/app0", forInput: "saf", at: now)
        records.setAlias("vsc", for: "apps/app2")
        records.hide("apps/app3")
        return records
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    /// 一段长度约为 `length` 个字符的文本：英文句子、中文句子、命令行 / 链接 / JSON、中英混合四种轮着来。
    private static func text(length: Int, using rng: inout LauncherSeededGenerator) -> String {
        var pieces: [String] = []
        var count = 0
        let kind = Int(rng.next() % 4)
        while count < length {
            let piece: String
            switch (kind, Int(rng.next() % 3)) {
            case (0, _): piece = englishWords[Int(rng.next() % UInt64(englishWords.count))]
            case (1, _): piece = chineseWords[Int(rng.next() % UInt64(chineseWords.count))]
            case (2, 0): piece = codeLines[Int(rng.next() % UInt64(codeLines.count))]
            case (2, _): piece = englishWords[Int(rng.next() % UInt64(englishWords.count))]
            case (_, 0): piece = chineseWords[Int(rng.next() % UInt64(chineseWords.count))]
            default: piece = englishWords[Int(rng.next() % UInt64(englishWords.count))]
            }
            pieces.append(piece)
            count += piece.count + 1
        }
        let joined = pieces.joined(separator: kind == 1 ? "" : " ")
        return String(joined.prefix(length))
    }

    private static let appNames = [
        "Safari", "Google Chrome", "Visual Studio Code", "Xcode", "微信", "企业微信", "网易云音乐", "QQ音乐", "钉钉", "飞书",
        "Slack", "Notion", "Figma", "终端", "访达", "系统设置", "计算器", "日历", "备忘录", "提醒事项", "地图", "照片",
        "音乐", "播客", "Keynote 讲演", "Pages 文稿", "Numbers 表格", "Final Cut Pro", "Logic Pro", "iTerm", "Docker",
        "Postman", "TablePlus", "Sublime Text", "IntelliJ IDEA", "PyCharm", "Android Studio", "腾讯会议", "百度网盘",
        "有道词典", "哔哩哔哩", "爱奇艺", "优酷", "迅雷", "搜狗输入法", "WPS Office", "Microsoft Word", "Microsoft Excel",
        "Microsoft PowerPoint", "Microsoft Outlook", "Zoom", "Telegram", "WhatsApp", "Spotify", "1Password",
        "CleanShot X", "Bartender", "活动监视器", "磁盘工具", "钥匙串访问", "控制台", "预览", "文本编辑", "快捷指令",
        "App Store", "Baobox", "Safari Technology Preview", "Firefox", "Arc", "Obsidian",
    ]
    private static let appSuffixes = ["Helper", "Beta", "2", "Pro", "Lite", "Preview"]
    private static let commandVerbs = ["开始", "停止", "打开", "关闭", "暂停", "切换", "显示", "隐藏", "清空", "重新开始"]
    private static let commandObjects = [
        "截图", "录屏", "听写", "专注", "防休眠", "窗口左半屏", "剪贴板", "会议", "划词助手", "网络抓包", "桌面宠物",
        "菜单栏管理", "长截屏", "屏幕取字", "翻译",
    ]
    private static let englishWords = [
        "the", "quick", "build", "deploy", "server", "error", "request", "response", "config", "update", "meeting",
        "notes", "project", "release", "docker", "kubectl", "git", "commit", "branch", "merge", "token", "session",
        "user", "login", "password", "api", "json", "http", "localhost", "staging", "production", "review", "design",
        "feature", "bugfix", "test", "coverage", "summary", "schedule", "invoice",
    ]
    private static let chineseWords = [
        "今天", "会议", "记录", "需求", "方案", "确认", "上线", "时间", "下周", "讨论", "客户", "反馈", "问题", "修复",
        "版本", "发布", "设计", "评审", "截图", "剪贴板", "翻译", "文档", "链接", "地址", "验证码", "快递", "订单",
        "付款", "明天", "上午", "下午", "我们", "已经", "可以", "一下",
    ]
    private static let codeLines = [
        "docker run -it --rm ubuntu bash", "kubectl get pods -n default", "git checkout -b feat/launcher",
        "https://github.com/example/repo/pull/123", #"{"id": 42, "name": "test"}"#,
        "SELECT * FROM users WHERE id = 1;", "ssh deploy@10.0.0.1", "npm install --save-dev typescript",
    ]
}
