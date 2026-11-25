import Foundation

// 快速入口的一次性提醒（docs/launcher/TECH_DESIGN.md §5.4「一次性提醒」，第 10 步）：输入「20 分钟后提醒我取快递」回车设好，到点经通知内核提醒。
// 这里是纯模型和规则：提醒本身、`reminders.json` 的读写格式（解码全程容错）、哪些到点了、晚了多久、标题里写「今天 / 明天 / 日期」、
// 什么输入算「列出提醒」。当前时间、日历由调用方传入，不读写磁盘。落盘、计时、发通知在 App 侧（`LauncherReminderCenter`）。
// 只依赖 Foundation，进 BaoboxTests。

/// 一条设好的提醒。
struct LauncherReminder: Equatable, Sendable, Identifiable {
    let id: String
    /// 到点的时刻。
    let date: Date
    /// 事由。
    let text: String
    /// 设的时候。
    let created: Date
}

/// `reminders.json` 的格式与规则。
///
/// ```json
/// {"version":1,"reminders":[{"id":"…","date":1800000000,"text":"取快递","created":1799998800}]}
/// ```
/// 时间写成 1970 年起的秒数（同使用记录，不依赖 JSONEncoder 的日期策略）。
enum LauncherReminderBook {
    static let version = 1
    /// 最多留这么多条（还没到点的）；再多删最晚的那些 —— 不会有人设两百条一次性提醒。
    static let maxCount = 200
    /// 事由最多这么多个字符（输入框里打的一句话，写进文件前截一下）。
    static let maxTextLength = 200
    /// 晚了不到这么久不算晚（计时器本身有几百毫秒的误差，唤醒后对表也要一会儿）。
    static let latenessThreshold: TimeInterval = 60

    /// 解码：顶层不是对象、`reminders` 不是数组时得到空表；单条缺字段、类型不对、事由是空的只跳过那一条；id 重复只留第一条。
    /// 版本号比当前新也照读认得的字段。按到点时刻排好。
    static func decode(_ data: Data) -> [LauncherReminder] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["reminders"] as? [Any] else { return [] }
        var seen: Set<String> = []
        var result: [LauncherReminder] = []
        for element in list {
            guard let item = element as? [String: Any],
                  let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                  let date = seconds(item["date"]),
                  let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            let created = seconds(item["created"]) ?? date
            result.append(LauncherReminder(id: id, date: date, text: String(text.prefix(maxTextLength)), created: created))
        }
        return sorted(result)
    }

    /// 编码（键排序，文件稳定）。
    static func encode(_ reminders: [LauncherReminder]) -> Data? {
        let list: [[String: Any]] = reminders.map { reminder in
            ["id": reminder.id, "date": reminder.date.timeIntervalSince1970, "text": reminder.text,
             "created": reminder.created.timeIntervalSince1970]
        }
        return try? JSONSerialization.data(withJSONObject: ["version": version, "reminders": list], options: [.sortedKeys])
    }

    /// 加一条：按到点时刻排好；超过上限时删最晚的（刚加的那条不删）。
    static func inserting(_ reminder: LauncherReminder, into reminders: [LauncherReminder]) -> [LauncherReminder] {
        var list = sorted(reminders.filter { $0.id != reminder.id } + [reminder])
        while list.count > maxCount, let index = list.lastIndex(where: { $0.id != reminder.id }) {
            list.remove(at: index)
        }
        return list
    }

    /// 到点了的（`date <= now`）和还没到的，各自按到点时刻排好。
    static func split(_ reminders: [LauncherReminder], now: Date) -> (due: [LauncherReminder], pending: [LauncherReminder]) {
        let ordered = sorted(reminders)
        return (ordered.filter { $0.date <= now }, ordered.filter { $0.date > now })
    }

    /// 晚了多久（秒）；不到 `latenessThreshold` 算准时，为 nil。
    static func lateness(of reminder: LauncherReminder, now: Date) -> TimeInterval? {
        let late = now.timeIntervalSince(reminder.date)
        return late >= latenessThreshold ? late : nil
    }

    /// 输入是不是「列出提醒」：「提醒」「reminders」「reminder」（不分大小写、去首尾空白）。
    static func isListQuery(_ text: String) -> Bool {
        listQueries.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static let listQueries: Set<String> = ["提醒", "reminders", "reminder"]

    private static func sorted(_ reminders: [LauncherReminder]) -> [LauncherReminder] {
        reminders.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
    }

    private static func seconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// 标题里的「哪一天」：今天、明天、后天，其余写日期。
enum LauncherReminderDay: Equatable, Sendable {
    case today, tomorrow, dayAfterTomorrow
    /// 别的日子（月、日，有没有跨年）。
    case date(sameYear: Bool)

    static func of(_ date: Date, now: Date, calendar: Calendar) -> LauncherReminderDay {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? Int.max
        switch days {
        case 0: return .today
        case 1: return .tomorrow
        case 2: return .dayAfterTomorrow
        default:
            return .date(sameYear: calendar.component(.year, from: date) == calendar.component(.year, from: now))
        }
    }
}

/// 「晚了多久」的说法：不到一小时按分钟、不到一天按小时、再久按天（向下取整，至少 1）。
enum LauncherReminderLateness: Equatable, Sendable {
    case minutes(Int), hours(Int), days(Int)

    init(seconds: TimeInterval) {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 {
            self = .minutes(minutes)
        } else if minutes < 60 * 24 {
            self = .hours(minutes / 60)
        } else {
            self = .days(minutes / (60 * 24))
        }
    }
}
