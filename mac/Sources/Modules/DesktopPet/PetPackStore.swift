import CryptoKit
import Foundation

/// 可下载形象的下载 / 删除（设计见 docs/desktop-pet/PACKS.md §3）。
/// 素材都很小（几十 KB），不做断点续传：逐文件按源顺序尝试，大小 + SHA-256 双重校验，
/// 先写进隐藏的暂存目录，全部通过才整体挪成 `Pets/<id>/`，中途失败不留半个包。
@MainActor
final class PetPackStore: ObservableObject {
    static let shared = PetPackStore()

    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case installed
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private init() {
        refresh()
    }

    func state(of pack: PetPackInfo) -> State {
        states[pack.id] ?? .notInstalled
    }

    /// 按磁盘现状重算（正在下载的不动）。
    func refresh() {
        for pack in PetCatalog.downloadable {
            if case .downloading = states[pack.id] { continue }
            states[pack.id] = Self.isInstalled(pack) ? .installed : .notInstalled
        }
    }

    func download(_ pack: PetPackInfo) {
        if case .downloading = state(of: pack) { return }
        states[pack.id] = .downloading(progress: 0)
        tasks[pack.id] = Task { [weak self] in
            await self?.run(pack)
        }
    }

    func delete(_ pack: PetPackInfo) {
        tasks[pack.id]?.cancel()
        tasks[pack.id] = nil
        try? FileManager.default.removeItem(at: Self.installURL(pack))
        states[pack.id] = .notInstalled
        PetController.shared.reloadCharacter()
    }

    // MARK: - 下载

    private func run(_ pack: PetPackInfo) async {
        let fm = FileManager.default
        let staging = PetPackageLoader.userPetsDirectory
            .appendingPathComponent(".download-\(pack.id)", isDirectory: true)
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var done: Int64 = 0
            for file in pack.files {
                let data = try await fetch(file, of: pack)
                try data.write(to: staging.appendingPathComponent(file.name), options: .atomic)
                done += file.size
                states[pack.id] = .downloading(progress: Double(done) / Double(max(pack.byteSize, 1)))
            }
            try Task.checkCancellation()
            let destination = Self.installURL(pack)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staging, to: destination)
            tasks[pack.id] = nil
            states[pack.id] = .installed
            // 下载就是想用它：装好直接换上。
            PetController.shared.selectCharacter(pack.id, reload: true)
        } catch {
            try? fm.removeItem(at: staging)
            // 删除时会取消任务，状态已由 delete 设好。
            guard !Task.isCancelled else { return }
            tasks[pack.id] = nil
            states[pack.id] = .failed(error.localizedDescription)
        }
    }

    /// 一个源整个连不上 / 返回非 200 / 校验不过都换下一个源；全部失败抛最后一个错误。
    private func fetch(_ file: PetPackInfo.File, of pack: PetPackInfo) async throws -> Data {
        var lastError: Error = PetPackError.failed
        for base in PetCatalog.mirrors {
            guard let url = URL(string: base + pack.id + "/" + file.name) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw PetPackError.http(status) }
                guard Int64(data.count) == file.size, Self.sha256(data) == file.sha256 else {
                    throw PetPackError.checksum
                }
                return data
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - 磁盘

    private static func installURL(_ pack: PetPackInfo) -> URL {
        PetPackageLoader.userPetsDirectory.appendingPathComponent(pack.id, isDirectory: true)
    }

    /// 文件都在且大小对得上就算装好（启动时不重算哈希）。
    private static func isInstalled(_ pack: PetPackInfo) -> Bool {
        let dir = installURL(pack)
        return pack.files.allSatisfy { file in
            let path = dir.appendingPathComponent(file.name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return size == file.size
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PetPackError: LocalizedError {
    case http(Int)
    case checksum
    case failed

    var errorDescription: String? {
        switch self {
        case .http(let status): return L("pet.download.error.http \(status)")
        case .checksum: return L("pet.download.error.checksum")
        case .failed: return L("pet.download.error.failed")
        }
    }
}
