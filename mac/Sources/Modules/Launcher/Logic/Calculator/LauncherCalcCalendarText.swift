import Foundation

// 计算引擎里日期、时区结果用的星期和月份名（docs/launcher/TECH_DESIGN.md §7）。

/// 星期、月份的显示名（自己写死，不依赖系统的本地化数据，输出稳定）。
enum LauncherCalcCalendarText {
    /// Calendar 的 weekday：1 = 周日 … 7 = 周六。
    static func weekdayZh(_ weekday: Int) -> String {
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    static func weekdayZhShort(_ weekday: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    static func weekdayEn(_ weekday: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
    }

    static func monthEn(_ month: Int) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return names.indices.contains(month - 1) ? names[month - 1] : ""
    }

    /// 周一为 1 … 周日为 7 时的「一」…「日」。
    static func weekdayZhShortSuffix(_ day: Int) -> String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        return names.indices.contains(day - 1) ? names[day - 1] : ""
    }

    /// 周一为 1 … 周日为 7 时的英文全名。
    static func weekdayEnFull(_ day: Int) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return names.indices.contains(day - 1) ? names[day - 1] : ""
    }
}
