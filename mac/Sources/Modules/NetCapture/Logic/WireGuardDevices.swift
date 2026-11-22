import Foundation

// 网络抓包的纯逻辑（Foundation + CryptoKit，进 BaoboxTests）：WireGuard 多台设备。
// 见 docs/packet-capture/WIREGUARD-DEVICES.md。
//
// 一台设备 = 一份密钥 + 一个 UDP 端口 + 一张二维码 + 一个名字。引擎给每台开一个 `--mode wireguard:<密钥文件>@<端口>`，
// 桥按「连接是从哪个监听进来的」认设备：密钥文件名（去掉 `.json`）就是设备 id。
// 数据在 `<supportDir>/wireguard/`：设备表 `devices.json`（数组顺序 = 列表顺序），每台的密钥 `<id>.json`。

/// 一台经 WireGuard 接进来的设备。
struct WireGuardDevice: Equatable, Identifiable, Sendable {
    /// 小写 UUID。也是密钥文件名（`<id>.json`）和设备键（`wg:<id>`）里的那一段。
    let id: String
    var name: String
    /// 添加时分配，之后不变（二维码里写死了）。
    let port: UInt16
}

/// 设备表的编解码与几条规则（端口、默认名、设备键）。
enum WireGuardDeviceTable {
    /// 设备键：事件里带 `wg` 的连接记在 `wg:<id>` 名下，其余仍按来源 IP。
    static let keyPrefix = "wg:"

    static func deviceKey(id: String) -> String { keyPrefix + id }

    /// `wg:<id>` → id；不是隧道设备的键返回 nil。
    static func deviceID(fromKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let id = String(key.dropFirst(keyPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// id 只认小写 UUID：它要拼进文件路径，别的写法一概不认。
    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.lowercased()
    }

    /// 名字最长这么多个字符（界面上一行放得下，MCP 也不能塞进一大段）。
    static let maxNameLength = 64

    /// 名字整理：换行、制表等控制字符换成空格，去掉首尾空白，截到 `maxNameLength` 个字符；空的不算名字。
    /// 界面输入、MCP、读设备表都走这里。
    static func cleanName(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    /// 解设备表的结果：留下来的设备、丢掉了几条、整个文件是不是读不出来（调用方据此先把原文件备份一份）。
    struct DecodeReport: Equatable {
        var devices: [WireGuardDevice]
        var dropped: Int
        var unreadable: Bool
    }

    /// 解设备表。整个文件不是数组 → 空表；坏的条目（id 不是小写 UUID、没有名字、端口不对）跳过；
    /// 重复的 id、重复的端口只留第一条（两个监听抢一个端口，引擎会起不来）。
    static func decode(_ data: Data) -> [WireGuardDevice] {
        decodeReport(data).devices
    }

    static func decodeReport(_ data: Data) -> DecodeReport {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return DecodeReport(devices: [], dropped: 0, unreadable: true)
        }
        var seenIDs = Set<String>()
        var seenPorts = Set<UInt16>()
        var devices: [WireGuardDevice] = []
        for item in items {
            guard let object = item as? [String: Any],
                  let id = object["id"] as? String, isValidID(id),
                  let name = (object["name"] as? String).flatMap(cleanName),
                  let number = object["port"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let port = UInt16(exactly: number.doubleValue), port > 0,
                  !seenIDs.contains(id), !seenPorts.contains(port) else { continue }
            seenIDs.insert(id)
            seenPorts.insert(port)
            devices.append(WireGuardDevice(id: id, name: name, port: port))
        }
        return DecodeReport(devices: devices, dropped: items.count - devices.count, unreadable: false)
    }

    static func encode(_ devices: [WireGuardDevice]) -> Data {
        let objects = devices.map { ["id": $0.id, "name": $0.name, "port": Int($0.port)] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }

    /// 新设备的端口：从设置里的起始端口往后排 —— 取「起始端口」和「起始端口以上已用的最大端口 + 1」里大的那个，
    /// 再跳过已用的和 `reserved`（代理、SOCKS、配置页、MCP 的端口）。往上排到 65535 还没有，就从起始端口、再从 1024 起找空的。
    /// 全满（实际不会）返回 nil。
    static func nextPort(start: UInt16, used: [UInt16], reserved: Set<UInt16>) -> UInt16? {
        let taken = Set(used).union(reserved)
        let start = max(start, 1024)
        func scan(from low: UInt16, to high: UInt16) -> UInt16? {
            guard low <= high else { return nil }
            return (low...high).first { !taken.contains($0) }
        }
        var first: UInt16? = start
        if let highest = used.filter({ $0 >= start }).max() {
            first = highest == .max ? nil : highest + 1
        }
        if let first, let port = scan(from: first, to: .max) { return port }
        return scan(from: start, to: .max) ?? scan(from: 1024, to: start)
    }

    /// 「设备 N」：N 从「已有几台 + 1」起，跟已有的名字重了就往上加。`format` 把数字变成本地化的名字。
    static func defaultName(existing: [String], format: (Int) -> String) -> String {
        let names = Set(existing)
        var number = existing.count + 1
        while names.contains(format(number)) { number += 1 }
        return format(number)
    }
}

/// 多设备之前只有一份密钥（`<supportDir>/wireguard.json`）。首次启动新版本时把它变成第一台设备：
/// 钥匙和端口都不变，扫过旧码的手机照样能连。先写设备表、再搬密钥文件，中途失败下次重来不丢钥匙。
enum WireGuardMigration {
    enum Plan: Equatable {
        /// 不用迁（新装，或早就迁完了）。
        case nothing
        /// 有旧密钥、还没有设备表：建第一台设备，写设备表，再把旧文件搬成它的密钥。
        case migrate
        /// 上次迁到一半：设备表写了，旧文件还没搬。搬到这一台（第一台，迁出来的那台总在最前面）名下。
        case finishMove(deviceID: String)
    }

    /// 两个 Baobox 同时迁移（worktree 构建和 /Applications 里那份共用支持目录）时，钥匙可能落在设备表里没有的 id 下，
    /// 而表里那台没有钥匙。这种「没人认的钥匙」只在恰好一把、缺钥匙的设备恰好一台时还给它（多了分不清是谁的，不动）。
    /// 返回 设备 id → 那把钥匙的文件 id。
    static func reclaim(missing: [String], orphans: [String]) -> [String: String] {
        guard missing.count == 1, orphans.count == 1 else { return [:] }
        return [missing[0]: orphans[0]]
    }

    /// `legacyValid`：旧密钥文件在、而且读得出来（读不出来的不迁，留着也不碍事）。
    static func plan(tableExists: Bool, devices: [WireGuardDevice], legacyValid: Bool,
                     keyFileExists: (String) -> Bool) -> Plan {
        guard legacyValid else { return .nothing }
        guard tableExists else { return .migrate }
        if let first = devices.first, !keyFileExists(first.id) { return .finishMove(deviceID: first.id) }
        return .nothing
    }
}

/// 设备表与各台密钥的读写（在后台线程调）。写设备表是「临时文件 + 原子改名」，密钥沿用 `WireGuardKeyFile`（权限 600）。
struct WireGuardDeviceFiles: Sendable {
    /// `<supportDir>/wireguard/`
    let folder: URL
    /// 多设备之前的那一份：`<supportDir>/wireguard.json`
    let legacyKeyURL: URL

    var tableURL: URL { folder.appendingPathComponent("devices.json") }

    func keyURL(id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// 读设备表；文件不存在返回 nil（和「空表」分开：迁移要看它）。
    /// 有条目被丢掉、或者整个文件读不出来：先把原文件复制成 `devices.broken-<时间>.json` 留着（下次写盘就盖掉了），再继续。
    func readTable() -> [WireGuardDevice]? {
        guard let data = try? Data(contentsOf: tableURL) else { return nil }
        let report = WireGuardDeviceTable.decodeReport(data)
        if report.unreadable || report.dropped > 0 { backUpTable() }
        return report.devices
    }

    /// 坏的设备表备份到哪（同 Mock 规则的 `mock-rules.broken-<时间>.json`）。
    func backUpTable() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = folder.appendingPathComponent("devices.broken-\(formatter.string(from: Date())).json")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: tableURL, to: backup)
    }

    /// 旧的单份密钥还在、读得出来（还没迁完）。
    var legacyKeysExist: Bool { WireGuardKeyFile.read(at: legacyKeyURL) != nil }

    func writeTable(_ devices: [WireGuardDevice]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WireGuardDeviceTable.encode(devices).write(to: tableURL, options: .atomic)
    }

    func readKeys(id: String) -> WireGuardKeys? {
        WireGuardKeyFile.read(at: keyURL(id: id))
    }

    /// 给新设备生成一份密钥写下去。
    func createKeys(id: String) throws -> WireGuardKeys {
        try WireGuardKeyFile.replace(at: keyURL(id: id))
    }

    /// 删掉一台的密钥；文件本来就没有不算错。
    func removeKeys(id: String) throws {
        let url = keyURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    struct LoadResult: Equatable, Sendable {
        var devices: [WireGuardDevice]
        /// 读得出来的密钥；缺了或坏了的设备不在这里。
        var keys: [String: WireGuardKeys]
        /// 这一次（或补完上次）迁出来的设备。
        var migrated: WireGuardDevice?
        /// 密钥不在 `<id>.json` 的设备（旧文件没搬成）：引擎的监听用这个文件。
        var keyFiles: [String: URL] = [:]
        /// 要报给用户的写盘问题（`StorageWriteFailure`）。
        var problems: [String] = []
    }

    /// 读设备表和各台密钥，必要时先把旧的单份密钥迁成第一台设备。
    /// `migratedName`：迁出来的那台叫什么（`10.0.0.1` 的别名，没有就是「设备 1」）；`legacyPort`：旧设置里的端口。
    /// 写设备表失败就抛出去（旧文件原样留着，下次再迁）；搬文件失败只是这台暂时没有钥匙，下次启动再搬。
    func load(migratedName: String, legacyPort: UInt16) throws -> LoadResult {
        let table = readTable()
        let legacy = WireGuardKeyFile.read(at: legacyKeyURL)
        var devices = table ?? []
        var migrated: WireGuardDevice?
        var keyFiles: [String: URL] = [:]
        var problems: [String] = []
        let plan = WireGuardMigration.plan(tableExists: table != nil, devices: devices, legacyValid: legacy != nil,
                                           keyFileExists: { FileManager.default.fileExists(atPath: keyURL(id: $0).path) })
        var moveTo: String?
        switch plan {
        case .nothing:
            break
        case .migrate:
            let device = WireGuardDevice(id: WireGuardDeviceTable.newID(),
                                         name: WireGuardDeviceTable.cleanName(migratedName) ?? "1",
                                         port: legacyPort)
            devices = [device]
            try writeTable(devices)
            migrated = device
            moveTo = device.id
        case .finishMove(let id):
            migrated = devices.first { $0.id == id }
            moveTo = id
        }
        if let id = moveTo, let error = moveLegacy(to: id) {
            // 没搬成：这一次直接用旧文件（钥匙一样，扫过旧码的手机照样能连），下次启动再搬。
            keyFiles[id] = legacyKeyURL
            problems.append(error)
        }
        var keys: [String: WireGuardKeys] = [:]
        for device in devices {
            if let file = keyFiles[device.id], let found = WireGuardKeyFile.read(at: file) {
                keys[device.id] = found
            } else if let found = readKeys(id: device.id) {
                keys[device.id] = found
            }
        }
        // 没人认的钥匙还给缺钥匙的那台（两个 Baobox 同时迁移留下的）。
        let missing = devices.map(\.id).filter { keys[$0] == nil }
        if !missing.isEmpty {
            let known = Set(devices.map(\.id))
            for (deviceID, orphanID) in WireGuardMigration.reclaim(missing: missing, orphans: orphanKeyIDs(excluding: known)) {
                guard let found = readKeys(id: orphanID) else { continue }
                if rename(keyURL(id: orphanID).path, keyURL(id: deviceID).path) == 0 {
                    keys[deviceID] = found
                } else {
                    keyFiles[deviceID] = keyURL(id: orphanID)
                    keys[deviceID] = found
                    problems.append(String(cString: strerror(errno)))
                }
            }
        }
        return LoadResult(devices: devices, keys: keys, migrated: migrated, keyFiles: keyFiles, problems: problems)
    }

    /// 目录里 `<小写 uuid>.json`、读得出钥匙、又不是表里任何一台的文件。
    func orphanKeyIDs(excluding known: Set<String>) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard WireGuardDeviceTable.isValidID(id), !known.contains(id), readKeys(id: id) != nil else { return nil }
            return id
        }.sorted()
    }

    /// 旧密钥文件改名成这台的密钥（同一个卷上，原子的；权限原样是 600）。失败返回原因。
    private func moveLegacy(to id: String) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard rename(legacyKeyURL.path, keyURL(id: id).path) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }
}

/// 设备列表里「最近活动」那一列：这台最后一个包是多久以前。
enum WireGuardActivity {
    enum Seen: Equatable {
        case never
        case justNow
        case minutes(Int)
        case hours(Int)
        case yesterday
        case days(Int)
    }

    /// 绿点：这么久之内有包。
    static let recentWindow: TimeInterval = 5 * 60

    static func seen(_ date: Date?, now: Date, calendar: Calendar = .current) -> Seen {
        guard let date else { return .never }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return .justNow }
        if seconds < 3600 { return .minutes(Int(seconds / 60)) }
        if seconds < 86_400 { return .hours(Int(seconds / 3600)) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 2
        return days <= 1 ? .yesterday : .days(days)
    }

    static func isRecent(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < recentWindow
    }
}
