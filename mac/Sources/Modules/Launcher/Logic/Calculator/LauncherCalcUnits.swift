import Foundation

// 单位表（docs/launcher/TECH_DESIGN.md §7「单位」）：换算用 Foundation 的 Measurement / Dimension，
// 这里只管「哪些写法指哪个单位」和「中英文界面各显示成什么」。
// 一个写法可以指几个单位（`m` = 米 / 分钟），由换算句型按两边量纲是否一致来定。
// 数据量区分大小写（`MB` 兆字节、`Mb` 兆比特），先查区分大小写的表，查不到再不分大小写查。

enum LauncherCalcDimension: Sendable {
    case length, mass, temperature, area, volume, speed, duration, data
}

struct LauncherCalcUnit {
    let dimension: LauncherCalcDimension
    let unit: Dimension
    /// 英文界面显示：`km`、`°C`、`ft²`
    let symbol: String
    /// 中文界面显示：`公里`、`摄氏度`、`平方英尺`
    let zh: String
    /// 不分大小写的写法（英文存小写；中文名也在这里）。
    let names: [String]
    /// 区分大小写的写法（`MB`、`Mb`）。
    var exactNames: [String] = []

    func name(_ context: LauncherCalcContext) -> String { context.text(zh, symbol) }
}

enum LauncherCalcUnitTable {
    // Foundation 自带的这几个系数只取了五六位（`UnitSpeed.kilometersPerHour` 是 0.277778，60 mph 换出来
    // 96.5605627 而不是 96.56064），按定义的精确值重建。系数都相对各自量纲的基本单位（米每秒、千克、升、开尔文）。
    private static let kilometersPerHour = UnitSpeed(symbol: "km/h", converter: UnitConverterLinear(coefficient: 1_000.0 / 3_600.0))
    private static let knots = UnitSpeed(symbol: "kn", converter: UnitConverterLinear(coefficient: 1_852.0 / 3_600.0))
    private static let pounds = UnitMass(symbol: "lb", converter: UnitConverterLinear(coefficient: 0.45359237))
    private static let ounces = UnitMass(symbol: "oz", converter: UnitConverterLinear(coefficient: 0.45359237 / 16))
    private static let gallons = UnitVolume(symbol: "gal", converter: UnitConverterLinear(coefficient: 3.785411784))
    private static let fluidOunces = UnitVolume(symbol: "fl oz",
                                                converter: UnitConverterLinear(coefficient: 3.785411784 / 128))
    private static let fahrenheit = UnitTemperature(symbol: "°F",
                                                    converter: UnitConverterLinear(coefficient: 5.0 / 9.0,
                                                                                   constant: 459.67 * 5.0 / 9.0))

    // 中国市制和 Foundation 没有的单位：系数都相对各自量纲的基本单位（米、千克、平方米、秒）。
    private static let li = UnitLength(symbol: "li", converter: UnitConverterLinear(coefficient: 500))
    private static let chi = UnitLength(symbol: "chi", converter: UnitConverterLinear(coefficient: 1.0 / 3.0))
    private static let cun = UnitLength(symbol: "cun", converter: UnitConverterLinear(coefficient: 1.0 / 30.0))
    private static let jin = UnitMass(symbol: "jin", converter: UnitConverterLinear(coefficient: 0.5))
    private static let liang = UnitMass(symbol: "liang", converter: UnitConverterLinear(coefficient: 0.05))
    private static let mu = UnitArea(symbol: "mu", converter: UnitConverterLinear(coefficient: 2000.0 / 3.0))
    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))

    static let all: [LauncherCalcUnit] = length + mass + temperature + area + volume + speed + duration + data

    private static let length: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .length, unit: UnitLength.meters, symbol: "m", zh: "米",
                         names: ["m", "meter", "meters", "metre", "metres", "米"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.kilometers, symbol: "km", zh: "公里",
                         names: ["km", "kilometer", "kilometers", "kilometre", "kilometres", "公里", "千米"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.centimeters, symbol: "cm", zh: "厘米",
                         names: ["cm", "centimeter", "centimeters", "centimetre", "centimetres", "厘米"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.millimeters, symbol: "mm", zh: "毫米",
                         names: ["mm", "millimeter", "millimeters", "millimetre", "millimetres", "毫米"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.micrometers, symbol: "µm", zh: "微米",
                         names: ["um", "micrometer", "micrometers", "micron", "microns", "微米"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.nanometers, symbol: "nm", zh: "纳米",
                         names: ["nm", "nanometer", "nanometers", "纳米"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.miles, symbol: "mi", zh: "英里",
                         names: ["mi", "mile", "miles", "英里"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.feet, symbol: "ft", zh: "英尺",
                         names: ["ft", "foot", "feet", "英尺"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.inches, symbol: "in", zh: "英寸",
                         names: ["in", "inch", "inches", "英寸"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.yards, symbol: "yd", zh: "码",
                         names: ["yd", "yard", "yards", "码"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.nauticalMiles, symbol: "nmi", zh: "海里",
                         names: ["nmi", "nautical mile", "nautical miles", "海里"]),
        LauncherCalcUnit(dimension: .length, unit: UnitLength.lightyears, symbol: "ly", zh: "光年",
                         names: ["ly", "light year", "light years", "lightyear", "lightyears", "光年"]),
        LauncherCalcUnit(dimension: .length, unit: li, symbol: "li", zh: "里", names: ["里", "华里"]),
        LauncherCalcUnit(dimension: .length, unit: chi, symbol: "chi", zh: "尺", names: ["尺", "市尺"]),
        LauncherCalcUnit(dimension: .length, unit: cun, symbol: "cun", zh: "寸", names: ["寸", "市寸"]),
    ]

    private static let mass: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .mass, unit: UnitMass.kilograms, symbol: "kg", zh: "千克",
                         names: ["kg", "kgs", "kilogram", "kilograms", "千克", "公斤"]),
        LauncherCalcUnit(dimension: .mass, unit: UnitMass.grams, symbol: "g", zh: "克",
                         names: ["g", "gram", "grams", "克"]),
        LauncherCalcUnit(dimension: .mass, unit: UnitMass.milligrams, symbol: "mg", zh: "毫克",
                         names: ["mg", "milligram", "milligrams", "毫克"]),
        LauncherCalcUnit(dimension: .mass, unit: UnitMass.metricTons, symbol: "t", zh: "吨",
                         names: ["t", "tonne", "tonnes", "metric ton", "metric tons", "吨"]),
        LauncherCalcUnit(dimension: .mass, unit: pounds, symbol: "lb", zh: "磅",
                         names: ["lb", "lbs", "pound", "pounds", "磅"]),
        LauncherCalcUnit(dimension: .mass, unit: ounces, symbol: "oz", zh: "盎司",
                         names: ["oz", "ounce", "ounces", "盎司"]),
        LauncherCalcUnit(dimension: .mass, unit: jin, symbol: "jin", zh: "斤", names: ["斤", "市斤"]),
        LauncherCalcUnit(dimension: .mass, unit: liang, symbol: "liang", zh: "两", names: ["两"]),
    ]

    private static let temperature: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .temperature, unit: UnitTemperature.celsius, symbol: "°C", zh: "摄氏度",
                         names: ["c", "°c", "celsius", "摄氏度", "摄氏"]),
        LauncherCalcUnit(dimension: .temperature, unit: fahrenheit, symbol: "°F", zh: "华氏度",
                         names: ["f", "°f", "fahrenheit", "华氏度", "华氏"]),
        LauncherCalcUnit(dimension: .temperature, unit: UnitTemperature.kelvin, symbol: "K", zh: "开尔文",
                         names: ["k", "kelvin", "kelvins", "开尔文"]),
    ]

    private static let area: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .area, unit: UnitArea.squareMeters, symbol: "m²", zh: "平方米",
                         names: ["m2", "m^2", "sq m", "sqm", "square meter", "square meters", "square metre",
                                 "square metres", "平方米", "平米"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.squareKilometers, symbol: "km²", zh: "平方公里",
                         names: ["km2", "km^2", "sq km", "square kilometer", "square kilometers", "square kilometre",
                                 "square kilometres", "平方公里", "平方千米"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.squareCentimeters, symbol: "cm²", zh: "平方厘米",
                         names: ["cm2", "cm^2", "sq cm", "square centimeter", "square centimeters", "平方厘米"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.squareFeet, symbol: "ft²", zh: "平方英尺",
                         names: ["ft2", "ft^2", "sq ft", "sqft", "square foot", "square feet", "平方英尺"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.squareInches, symbol: "in²", zh: "平方英寸",
                         names: ["in2", "in^2", "sq in", "square inch", "square inches", "平方英寸"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.squareMiles, symbol: "mi²", zh: "平方英里",
                         names: ["mi2", "mi^2", "sq mi", "square mile", "square miles", "平方英里"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.acres, symbol: "ac", zh: "英亩",
                         names: ["acre", "acres", "英亩"]),
        LauncherCalcUnit(dimension: .area, unit: UnitArea.hectares, symbol: "ha", zh: "公顷",
                         names: ["ha", "hectare", "hectares", "公顷"]),
        LauncherCalcUnit(dimension: .area, unit: mu, symbol: "mu", zh: "亩", names: ["亩"]),
    ]

    private static let volume: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .volume, unit: UnitVolume.liters, symbol: "L", zh: "升",
                         names: ["l", "liter", "liters", "litre", "litres", "升", "公升"]),
        LauncherCalcUnit(dimension: .volume, unit: UnitVolume.milliliters, symbol: "mL", zh: "毫升",
                         names: ["ml", "milliliter", "milliliters", "millilitre", "millilitres", "毫升"]),
        LauncherCalcUnit(dimension: .volume, unit: UnitVolume.cubicMeters, symbol: "m³", zh: "立方米",
                         names: ["m3", "m^3", "cubic meter", "cubic meters", "cubic metre", "cubic metres", "立方米"]),
        LauncherCalcUnit(dimension: .volume, unit: UnitVolume.cubicCentimeters, symbol: "cm³", zh: "立方厘米",
                         names: ["cm3", "cm^3", "cc", "cubic centimeter", "cubic centimeters", "立方厘米"]),
        LauncherCalcUnit(dimension: .volume, unit: gallons, symbol: "gal", zh: "加仑",
                         names: ["gal", "gallon", "gallons", "加仑"]),
        LauncherCalcUnit(dimension: .volume, unit: fluidOunces, symbol: "fl oz", zh: "液量盎司",
                         names: ["fl oz", "floz", "fluid ounce", "fluid ounces", "液量盎司"]),
    ]

    private static let speed: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .speed, unit: UnitSpeed.metersPerSecond, symbol: "m/s", zh: "米/秒",
                         names: ["m/s", "mps", "meters per second", "metres per second", "米每秒", "米/秒"]),
        LauncherCalcUnit(dimension: .speed, unit: kilometersPerHour, symbol: "km/h", zh: "公里/小时",
                         names: ["km/h", "kmh", "kph", "kmph", "kilometers per hour", "kilometres per hour",
                                 "公里每小时", "千米每小时", "公里/小时", "千米/小时"]),
        LauncherCalcUnit(dimension: .speed, unit: UnitSpeed.milesPerHour, symbol: "mph", zh: "英里/小时",
                         names: ["mph", "miles per hour", "英里每小时", "英里/小时"]),
        LauncherCalcUnit(dimension: .speed, unit: knots, symbol: "kn", zh: "节",
                         names: ["kn", "kt", "knot", "knots", "节"]),
    ]

    private static let duration: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .duration, unit: UnitDuration.milliseconds, symbol: "ms", zh: "毫秒",
                         names: ["ms", "millisecond", "milliseconds", "毫秒"]),
        LauncherCalcUnit(dimension: .duration, unit: UnitDuration.seconds, symbol: "s", zh: "秒",
                         names: ["s", "sec", "secs", "second", "seconds", "秒", "秒钟"]),
        // `m` 也可能是分钟（`3 h 20 m`）：排在米之后，两边量纲对得上才用它。
        LauncherCalcUnit(dimension: .duration, unit: UnitDuration.minutes, symbol: "min", zh: "分钟",
                         names: ["m", "min", "mins", "minute", "minutes", "分", "分钟"]),
        LauncherCalcUnit(dimension: .duration, unit: UnitDuration.hours, symbol: "h", zh: "小时",
                         names: ["h", "hr", "hrs", "hour", "hours", "小时", "个小时", "钟头", "个钟头"]),
        LauncherCalcUnit(dimension: .duration, unit: day, symbol: "d", zh: "天",
                         names: ["d", "day", "days", "天"]),
        LauncherCalcUnit(dimension: .duration, unit: week, symbol: "wk", zh: "周",
                         names: ["wk", "wks", "week", "weeks", "周", "星期", "个星期"]),
    ]

    // 数据量按十进制（1 GB = 1000 MB，同访达）；要二进制写 GiB / MiB。
    private static let data: [LauncherCalcUnit] = [
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.bytes, symbol: "B", zh: "字节",
                         names: ["byte", "bytes", "字节"], exactNames: ["B"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.kilobytes, symbol: "KB", zh: "KB",
                         names: ["kb", "kilobyte", "kilobytes"], exactNames: ["KB", "kB"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.megabytes, symbol: "MB", zh: "MB",
                         names: ["mb", "megabyte", "megabytes", "兆字节"], exactNames: ["MB"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.gigabytes, symbol: "GB", zh: "GB",
                         names: ["gb", "gigabyte", "gigabytes"], exactNames: ["GB"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.terabytes, symbol: "TB", zh: "TB",
                         names: ["tb", "terabyte", "terabytes"], exactNames: ["TB"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.petabytes, symbol: "PB", zh: "PB",
                         names: ["pb", "petabyte", "petabytes"], exactNames: ["PB"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.kibibytes, symbol: "KiB", zh: "KiB",
                         names: ["kib", "kibibyte", "kibibytes"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.mebibytes, symbol: "MiB", zh: "MiB",
                         names: ["mib", "mebibyte", "mebibytes"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.gibibytes, symbol: "GiB", zh: "GiB",
                         names: ["gib", "gibibyte", "gibibytes"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.tebibytes, symbol: "TiB", zh: "TiB",
                         names: ["tib", "tebibyte", "tebibytes"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.bits, symbol: "bit", zh: "比特",
                         names: ["bit", "bits", "比特"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.kilobits, symbol: "Kb", zh: "Kb",
                         names: ["kbit", "kbits", "kilobit", "kilobits"], exactNames: ["Kb"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.megabits, symbol: "Mb", zh: "Mb",
                         names: ["mbit", "mbits", "megabit", "megabits"], exactNames: ["Mb"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.gigabits, symbol: "Gb", zh: "Gb",
                         names: ["gbit", "gbits", "gigabit", "gigabits"], exactNames: ["Gb"]),
        LauncherCalcUnit(dimension: .data, unit: UnitInformationStorage.terabits, symbol: "Tb", zh: "Tb",
                         names: ["tbit", "tbits", "terabit", "terabits"], exactNames: ["Tb"]),
    ]

    /// 不分大小写的写法 → 候选单位（按表里的顺序）。
    private static let byName: [String: [Int]] = index { $0.names }
    /// 区分大小写的写法 → 候选单位。
    private static let byExactName: [String: [Int]] = index { $0.exactNames }

    static let cjkNames: Set<String> = Set(all.flatMap(\.names).filter { name in
        name.unicodeScalars.contains(where: LauncherCalcLexer.isCJK)
    }.flatMap { $0.split(separator: "/").map(String.init) })

    /// 这个写法指哪些单位：先按原样查区分大小写的表，查不到再按小写查。
    static func lookup(_ key: String) -> [LauncherCalcUnit] {
        let indices = byExactName[key] ?? byName[key.lowercased()] ?? []
        return indices.compactMap { all.indices.contains($0) ? all[$0] : nil }
    }

    private static func index(_ names: (LauncherCalcUnit) -> [String]) -> [String: [Int]] {
        var table: [String: [Int]] = [:]
        for (position, unit) in all.enumerated() {
            for name in names(unit) { table[name, default: []].append(position) }
        }
        return table
    }
}
