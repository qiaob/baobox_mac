import Foundation
import XCTest

/// WireGuard 多台设备：设备表、端口、默认名、迁移（docs/packet-capture/WIREGUARD-DEVICES.md §3）。
final class WireGuardDevicesTests: XCTestCase {

    private let idA = "6f1c2a9e-0b7d-4c55-9a3e-2f8d1e4b7c60"
    private let idB = "0a6c4f2e-91d3-4b8a-b7e5-3c2d1f0e9a88"
    private let idC = "d4e5f6a7-b8c9-4d0e-8f1a-2b3c4d5e6f70"

    // MARK: - 设备表

    func testTableRoundTripKeepsOrder() {
        let devices = [WireGuardDevice(id: idB, name: "vivo", port: 51820),
                       WireGuardDevice(id: idA, name: "测试 iPhone", port: 51821)]
        XCTAssertEqual(WireGuardDeviceTable.decode(WireGuardDeviceTable.encode(devices)), devices)
    }

    func testTableIsWhatTheDocumentSays() throws {
        let data = WireGuardDeviceTable.encode([WireGuardDevice(id: idA, name: "vivo", port: 51820)])
        let objects = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0]["id"] as? String, idA)
        XCTAssertEqual(objects[0]["name"] as? String, "vivo")
        XCTAssertEqual(objects[0]["port"] as? Int, 51820)
    }

    /// 坏的条目跳过，好的照留；整个文件坏了就是空表；重复的 id / 端口只留第一条。
    func testTableToleratesBadEntries() {
        let text = """
        [
          {"id": "\(idA)", "name": "vivo", "port": 51820},
          {"id": "../../etc/passwd", "name": "bad id", "port": 51821},
          {"id": "\(idA.uppercased())", "name": "upper", "port": 51822},
          {"id": "\(idB)", "name": "   ", "port": 51823},
          {"id": "\(idB)", "name": "no port"},
          {"id": "\(idB)", "name": "string port", "port": "51824"},
          {"id": "\(idB)", "name": "too big", "port": 70000},
          {"id": "\(idB)", "name": "bool port", "port": true},
          {"id": "\(idB)", "name": "zero", "port": 0},
          "not an object",
          {"id": "\(idA)", "name": "same id", "port": 51825},
          {"id": "\(idC)", "name": "same port", "port": 51820},
          {"id": "\(idB)", "name": "  Pixel 模拟器 ", "port": 51826}
        ]
        """
        XCTAssertEqual(WireGuardDeviceTable.decode(Data(text.utf8)), [
            WireGuardDevice(id: idA, name: "vivo", port: 51820),
            WireGuardDevice(id: idB, name: "Pixel 模拟器", port: 51826),
        ])
        XCTAssertEqual(WireGuardDeviceTable.decode(Data("{\"id\": 1}".utf8)), [])
        XCTAssertEqual(WireGuardDeviceTable.decode(Data("garbage".utf8)), [])
    }

    func testDeviceKey() {
        XCTAssertEqual(WireGuardDeviceTable.deviceKey(id: idA), "wg:" + idA)
        XCTAssertEqual(WireGuardDeviceTable.deviceID(fromKey: "wg:" + idA), idA)
        XCTAssertNil(WireGuardDeviceTable.deviceID(fromKey: "10.0.0.1"))
        XCTAssertNil(WireGuardDeviceTable.deviceID(fromKey: "wg:"))
        XCTAssertTrue(WireGuardDeviceTable.isValidID(WireGuardDeviceTable.newID()))
        XCTAssertFalse(WireGuardDeviceTable.isValidID(idA.uppercased()))
    }

    // MARK: - 端口

    func testFirstDeviceUsesTheStartPort() {
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 51820, used: [], reserved: [9090, 9091, 9092, 9191]), 51820)
    }

    /// 之后取「已用的最大端口 + 1」：删掉中间一台空出来的端口不再用（扫过那张码的手机还会来敲门）。
    func testNextIsAboveTheHighestUsed() {
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 51820, used: [51820, 51821], reserved: []), 51822)
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 51820, used: [51822, 51820], reserved: []), 51823)
    }

    /// 跳过代理 / SOCKS / 配置页 / MCP 正在用的端口。
    func testSkipsReservedPorts() {
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 9090, used: [], reserved: [9090, 9091, 9092, 9191]), 9093)
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 51820, used: [51820], reserved: [51821, 51822]), 51823)
    }

    /// 起始端口改大了：新设备从新的起始端口排，已有的不动。改小了：从起始端口以上已用的最大端口往后排。
    func testStartPortChanges() {
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 60000, used: [51820, 51821], reserved: []), 60000)
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 51820, used: [60000], reserved: []), 60001)
    }

    /// 紧贴上限：往上没有了，就从起始端口往上找空的，再不行从 1024 找。
    func testNearTheTop() {
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 65534, used: [65534], reserved: []), 65535)
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 65534, used: [65534, 65535], reserved: []), 1024)
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 65530, used: [65530, 65535], reserved: [65531]), 65532)
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 65535, used: [], reserved: [65535]), 1024)
        // 起始端口低于 1024 的设置按 1024 算。
        XCTAssertEqual(WireGuardDeviceTable.nextPort(start: 80, used: [], reserved: []), 1024)
    }

    // MARK: - 默认名

    func testDefaultName() {
        let format: (Int) -> String = { "设备 \($0)" }
        XCTAssertEqual(WireGuardDeviceTable.defaultName(existing: [], format: format), "设备 1")
        XCTAssertEqual(WireGuardDeviceTable.defaultName(existing: ["vivo", "测试 iPhone", "Pixel 模拟器"], format: format), "设备 4")
        // 删了「设备 2」还剩两台：「设备 3」已经有了，往上加。
        XCTAssertEqual(WireGuardDeviceTable.defaultName(existing: ["设备 1", "设备 3"], format: format), "设备 4")
    }

    func testCleanName() {
        XCTAssertEqual(WireGuardDeviceTable.cleanName("  vivo \n"), "vivo")
        XCTAssertNil(WireGuardDeviceTable.cleanName(" \t\n"))
        // 换行、制表等控制字符换成空格（MCP 传进来的名字不过滤会把列表撑成几行）。
        XCTAssertEqual(WireGuardDeviceTable.cleanName("测试\niPhone\t2\u{0007}"), "测试 iPhone 2")
        // 截到 64 个字符（按字符算，不按字节）。
        let long = String(repeating: "设", count: 100)
        XCTAssertEqual(WireGuardDeviceTable.cleanName(long)?.count, 64)
        XCTAssertEqual(WireGuardDeviceTable.cleanName(String(repeating: "a", count: 63) + "   b"), String(repeating: "a", count: 63))
    }

    func testDecodeReport() {
        let good = WireGuardDeviceTable.encode([WireGuardDevice(id: idA, name: "a", port: 1)])
        XCTAssertEqual(WireGuardDeviceTable.decodeReport(good), .init(devices: [WireGuardDevice(id: idA, name: "a", port: 1)],
                                                                      dropped: 0, unreadable: false))
        let mixed = Data(#"[{"id":"\#(idA)","name":"a","port":1},{"id":"bad","name":"b","port":2}]"#.utf8)
        XCTAssertEqual(WireGuardDeviceTable.decodeReport(mixed).dropped, 1)
        XCTAssertTrue(WireGuardDeviceTable.decodeReport(Data("{".utf8)).unreadable)
    }

    // MARK: - 迁移

    func testMigrationPlan() {
        let device = WireGuardDevice(id: idA, name: "设备 1", port: 51820)
        // 新装：没有旧文件，什么都不做。
        XCTAssertEqual(WireGuardMigration.plan(tableExists: false, devices: [], legacyValid: false, keyFileExists: { _ in false }),
                       .nothing)
        // 有旧文件、没有设备表：迁。
        XCTAssertEqual(WireGuardMigration.plan(tableExists: false, devices: [], legacyValid: true, keyFileExists: { _ in false }),
                       .migrate)
        // 设备表写了、旧文件还在、第一台还没有钥匙：上次迁到一半，接着搬。
        XCTAssertEqual(WireGuardMigration.plan(tableExists: true, devices: [device], legacyValid: true, keyFileExists: { _ in false }),
                       .finishMove(deviceID: idA))
        // 都迁完了（旧文件已经搬走）。
        XCTAssertEqual(WireGuardMigration.plan(tableExists: true, devices: [device], legacyValid: false, keyFileExists: { _ in true }),
                       .nothing)
        // 旧文件坏了：不迁（也不当成钥匙搬过去）。
        XCTAssertEqual(WireGuardMigration.plan(tableExists: false, devices: [], legacyValid: false, keyFileExists: { _ in false }),
                       .nothing)
        // 设备表和旧文件都在、第一台也有钥匙：不动旧文件（不知道它是谁的，留着不碍事）。
        XCTAssertEqual(WireGuardMigration.plan(tableExists: true, devices: [device], legacyValid: true, keyFileExists: { _ in true }),
                       .nothing)
    }

    private func tempFiles() -> (WireGuardDeviceFiles, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wgdev-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (WireGuardDeviceFiles(folder: root.appendingPathComponent("wireguard"),
                                     legacyKeyURL: root.appendingPathComponent("wireguard.json")), root)
    }

    /// 旧的单份密钥变成第一台设备：钥匙、端口不变，名字用给的；设备表写好、旧文件搬走、权限还是 600。
    func testMigrationKeepsTheKeyAndPort() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try WireGuardKeyFile.replace(at: files.legacyKeyURL)

        let result = try files.load(migratedName: "我的 vivo", legacyPort: 51830)
        let device = try XCTUnwrap(result.devices.first)
        XCTAssertEqual(result.devices.count, 1)
        XCTAssertEqual(device.name, "我的 vivo")
        XCTAssertEqual(device.port, 51830)
        XCTAssertEqual(result.migrated, device)
        XCTAssertEqual(result.keys[device.id], old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.legacyKeyURL.path))
        XCTAssertEqual(files.readTable(), [device])
        let mode = try FileManager.default.attributesOfItem(atPath: files.keyURL(id: device.id).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        // 再启动一次：不再迁，读到的一样。
        let again = try files.load(migratedName: "别的名字", legacyPort: 1)
        XCTAssertEqual(again.devices, [device])
        XCTAssertNil(again.migrated)
        XCTAssertEqual(again.keys[device.id], old)
    }

    /// 上次写了设备表、没来得及搬文件：这次接着搬，钥匙没丢。
    func testMigrationResumesAfterACrash() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try WireGuardKeyFile.replace(at: files.legacyKeyURL)
        let device = WireGuardDevice(id: idA, name: "设备 1", port: 51820)
        try files.writeTable([device])

        let result = try files.load(migratedName: "不该用到", legacyPort: 1)
        XCTAssertEqual(result.devices, [device])
        XCTAssertEqual(result.migrated, device)
        XCTAssertEqual(result.keys[idA], old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.legacyKeyURL.path))
    }

    /// 新装：没有设备表、没有旧文件，什么都不写。
    func testFreshInstallWritesNothing() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try files.load(migratedName: "设备 1", legacyPort: 51820)
        XCTAssertEqual(result.devices, [])
        XCTAssertNil(result.migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.tableURL.path))
    }

    /// 密钥文件缺了或坏了的设备照样在表里，只是没有钥匙（界面上提示删掉重新添加）。
    func testMissingKeysAreReported() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try files.writeTable([WireGuardDevice(id: idA, name: "a", port: 1), WireGuardDevice(id: idB, name: "b", port: 2),
                              WireGuardDevice(id: idC, name: "c", port: 3)])
        let keysA = try files.createKeys(id: idA)
        try Data("broken".utf8).write(to: files.keyURL(id: idC))
        let result = try files.load(migratedName: "", legacyPort: 1)
        XCTAssertEqual(result.devices.map(\.id), [idA, idB, idC])
        XCTAssertEqual(result.keys, [idA: keysA])
        try files.removeKeys(id: idA)
        XCTAssertNil(files.readKeys(id: idA))
    }

    // MARK: - 最近活动

    func testSeen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = Date(timeIntervalSince1970: 1_795_250_000)   // 08:33 UTC
        XCTAssertEqual(WireGuardActivity.seen(nil, now: now, calendar: calendar), .never)
        XCTAssertEqual(WireGuardActivity.seen(now.addingTimeInterval(-5), now: now, calendar: calendar), .justNow)
        XCTAssertEqual(WireGuardActivity.seen(now.addingTimeInterval(5), now: now, calendar: calendar), .justNow)
        XCTAssertEqual(WireGuardActivity.seen(now.addingTimeInterval(-180), now: now, calendar: calendar), .minutes(3))
        XCTAssertEqual(WireGuardActivity.seen(now.addingTimeInterval(-7300), now: now, calendar: calendar), .hours(2))
        XCTAssertEqual(WireGuardActivity.seen(now.addingTimeInterval(-86_400 - 60), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(WireGuardActivity.seen(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar), .days(3))
        XCTAssertTrue(WireGuardActivity.isRecent(now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(WireGuardActivity.isRecent(now.addingTimeInterval(-600), now: now))
        XCTAssertFalse(WireGuardActivity.isRecent(nil, now: now))
    }

    // MARK: - 审查后的修正

    /// 有条目被丢、或者整个文件坏了：原文件先复制一份 `devices.broken-<时间>.json` 再继续（下次写盘就盖掉了）。
    func testBrokenTableIsBackedUp() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
        let original = Data(#"[{"id":"\#(idA)","name":"vivo","port":51820},{"id":"oops"}]"#.utf8)
        try original.write(to: files.tableURL)
        XCTAssertEqual(files.readTable()?.map(\.id), [idA])
        let backups = try FileManager.default.contentsOfDirectory(atPath: files.folder.path).filter { $0.hasPrefix("devices.broken-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: files.folder.appendingPathComponent(backups[0])), original)

        // 好的文件不备份。
        let (clean, cleanRoot) = tempFiles()
        defer { try? FileManager.default.removeItem(at: cleanRoot) }
        try clean.writeTable([WireGuardDevice(id: idA, name: "a", port: 1)])
        _ = clean.readTable()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: clean.folder.path).contains { $0.hasPrefix("devices.broken-") })
    }

    /// 两个 Baobox 同时迁移：表里是 B，钥匙却搬到了 A 名下。下次读的时候把这把没人认的钥匙还给 B。
    func testOrphanKeyGoesBackToTheDeviceMissingOne() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try WireGuardKeyFile.replace(at: files.legacyKeyURL)
        try files.writeTable([WireGuardDevice(id: idA, name: "设备 1", port: 51820)])          // 进程 A 写表
        try files.writeTable([WireGuardDevice(id: idB, name: "设备 1", port: 51820)])          // 进程 B 写表（盖掉 A）
        XCTAssertEqual(rename(files.legacyKeyURL.path, files.keyURL(id: idA).path), 0)       // 进程 A 搬走了旧钥匙

        let result = try files.load(migratedName: "x", legacyPort: 1)
        XCTAssertEqual(result.devices.map(\.id), [idB])
        XCTAssertEqual(result.keys[idB], legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.keyURL(id: idB).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.keyURL(id: idA).path))
    }

    /// 没人认的钥匙不止一把、或者缺钥匙的不止一台：分不清是谁的，不动。
    func testReclaimOnlyOneToOne() {
        XCTAssertEqual(WireGuardMigration.reclaim(missing: [idB], orphans: [idA]), [idB: idA])
        XCTAssertEqual(WireGuardMigration.reclaim(missing: [idB], orphans: [idA, idC]), [:])
        XCTAssertEqual(WireGuardMigration.reclaim(missing: [idA, idB], orphans: [idC]), [:])
        XCTAssertEqual(WireGuardMigration.reclaim(missing: [], orphans: [idC]), [:])
    }

    /// 旧钥匙没搬成（目录不让写）：这一次用旧文件出码、开监听（`keyFiles`），报一个写盘问题；钥匙不算丢。
    func testFailedMoveUsesTheOldFileThisTime() throws {
        let (files, root) = tempFiles()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let legacy = try WireGuardKeyFile.replace(at: files.legacyKeyURL)
        try files.writeTable([WireGuardDevice(id: idA, name: "设备 1", port: 51820)])        // 上次写了表、没搬文件
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: files.folder.path)

        let result = try files.load(migratedName: "x", legacyPort: 1)
        XCTAssertEqual(result.keys[idA], legacy)
        XCTAssertEqual(result.keyFiles[idA], files.legacyKeyURL)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.legacyKeyURL.path))
    }

    /// 写设备表失败（迁移时）：抛出去，旧文件原样留着，下次再迁。
    func testMigrationTableWriteFailureKeepsTheOldFile() throws {
        let (files, root) = tempFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try WireGuardKeyFile.replace(at: files.legacyKeyURL)
        try Data("not a folder".utf8).write(to: files.folder)                                  // 目录的位置被一个文件占着
        XCTAssertThrowsError(try files.load(migratedName: "x", legacyPort: 51820))
        XCTAssertTrue(files.legacyKeysExist)
        try FileManager.default.removeItem(at: files.folder)
        let retry = try files.load(migratedName: "设备 1", legacyPort: 51820)
        XCTAssertEqual(retry.devices.map(\.port), [51820])
        XCTAssertFalse(files.legacyKeysExist)
    }

    /// 删钥匙失败要报出来，不能吞掉；本来就没有不算错。
    func testRemoveKeysReportsFailure() throws {
        let (files, root) = tempFiles()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNoThrow(try files.removeKeys(id: idA))
        _ = try files.createKeys(id: idA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: files.folder.path)
        XCTAssertThrowsError(try files.removeKeys(id: idA))
    }
}
