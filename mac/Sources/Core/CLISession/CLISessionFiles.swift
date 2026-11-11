import Foundation

/// 会话文件的列目录与清理（#109）。两种目录布局各一个函数，由格式选用；`FileManager` 的调用、资源键与选项
/// 照搬两个模块原来的写法，同一目录列出来的先后与改动前一致（同时间戳的会话先后也就不变）。后台线程调用。
enum CLISessionFiles {

    /// `root/<子目录>/*.jsonl`：只看一层子目录、不递归，跳过隐藏项（Claude Code：`projects/<项目>/<会话>.jsonl`）。
    /// 直接放在 `root` 下的文件不算；子目录里扩展名是 .jsonl 的都列出（不看是不是普通文件，读不了的由格式的 `scan` 跳过）。
    static func jsonlInSubdirectories(of root: URL) -> [CLISessionFile] {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [CLISessionFile] = []
        for directory in directories {
            let isDir = (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in entries where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append(CLISessionFile(
                    url: file,
                    modified: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                    size: Int64(values?.fileSize ?? 0)
                ))
            }
        }
        return files
    }

    /// `root` 下递归找扩展名是 .jsonl 的普通文件，跳过隐藏项（Codex：`sessions/YYYY/MM/DD/rollout-*.jsonl`）。
    static func jsonlRecursively(under root: URL) -> [CLISessionFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [CLISessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(CLISessionFile(
                url: url,
                modified: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                size: Int64(values?.fileSize ?? 0)
            ))
        }
        return files
    }

    /// 递归删掉 `root` 下修改时间早于 `now` 减 `days` 天的 .jsonl（跳过隐藏项）；取不到修改时间的当作 `now`（不删）。
    /// 返回（删掉的个数，释放的字节）；删不掉的不计。`root` 不存在时返回 (0, 0)。
    static func removeJSONL(under root: URL, olderThanDays days: Int, now: Date = Date()) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var count = 0
        var bytes: Int64 = 0

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? now
            guard mtime < cutoff else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                count += 1
                bytes += size
            }
        }
        return (count, bytes)
    }
}
