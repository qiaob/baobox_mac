import Foundation
import XCTest

/// 本地模型推理进程的 PID 文件（#187）：内容怎么读、哪些文件算 PID 文件、进程名怎么核对。
/// 列目录在临时目录里做，不碰真实的 `Application Support/Baobox/Translation/`。
final class OfflineServerPIDTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baobox-offline-pid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ contents: String = "123") throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 内容

    func testParseAcceptsAPositivePIDWithSurroundingWhitespace() {
        XCTAssertEqual(OfflineServerPID.parse("56594"), 56594)
        XCTAssertEqual(OfflineServerPID.parse("56594\n"), 56594, "写的时候不带换行，手改过的文件可能带")
        XCTAssertEqual(OfflineServerPID.parse("  2 \t\n"), 2)
        XCTAssertEqual(OfflineServerPID.parse(String(Int32.max)), Int32.max)
    }

    func testParseRejectsWhatCouldNotBeALeftoverServer() {
        // 0 = 整个进程组、1 = launchd、负数 = 进程组：kill 这些都不行。
        for text in ["", " ", "0", "1", "-1", "-56594", "abc", "56594x", "56 594", "5.5", "99999999999", "0x10"] {
            XCTAssertNil(OfflineServerPID.parse(text), "「\(text)」")
        }
    }

    func testReadReturnsNilForAMissingOrBadFile() throws {
        XCTAssertNil(OfflineServerPID.read(directory.appendingPathComponent("llama-server.pid")))
        try write("llama-server.pid", "not a pid")
        XCTAssertNil(OfflineServerPID.read(directory.appendingPathComponent("llama-server.pid")))
        try write("llama-server.pid", "4242")
        XCTAssertEqual(OfflineServerPID.read(directory.appendingPathComponent("llama-server.pid")), 4242)
    }

    // MARK: - 哪些文件

    func testPIDFileNames() {
        for name in ["llama-server.pid", "llama-server-corrector.pid", "llama-server-qwen3-4b.pid", "llama-server-my.model.pid"] {
            XCTAssertTrue(OfflineServerPID.isPIDFileName(name), name)
        }
        for name in ["llama-server.log", "llama-server-corrector.log", "llama-server-.pid", "llama-server", "server.pid",
                     "xllama-server.pid", "llama-server.pid.bak", "llama-servercorrector.pid", "models", ""] {
            XCTAssertFalse(OfflineServerPID.isPIDFileName(name), name)
        }
    }

    /// 启动清理扫的就是这些：翻译、纠错和「AI」页装的模型各一个；日志、模型目录、别的文件、同名目录不算。
    func testFilesListsEveryModelsPIDFileAndNothingElse() throws {
        try write("llama-server.pid")
        try write("llama-server-corrector.pid")
        try write("llama-server-qwen3-8b.pid")
        try write("llama-server.log", "log")
        try write("llama-server-corrector.log", "log")
        try write(".llama-server-hidden.pid")
        try write("notes.txt")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("models", isDirectory: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("llama-server-dir.pid", isDirectory: true),
                                                withIntermediateDirectories: true)

        XCTAssertEqual(OfflineServerPID.files(in: directory).map(\.lastPathComponent),
                       ["llama-server-corrector.pid", "llama-server-qwen3-8b.pid", "llama-server.pid"])
    }

    func testFilesIsEmptyWhenTheDirectoryIsMissing() {
        XCTAssertEqual(OfflineServerPID.files(in: directory.appendingPathComponent("missing", isDirectory: true)), [])
    }

    // MARK: - 进程名

    /// `ps -o comm=` 给的是可执行文件的路径：包里的推理进程认得出，PID 被别的进程占了就不认（不误杀）。
    func testServerCommandCheck() {
        XCTAssertTrue(OfflineServerPID.isServerCommand("/Applications/Baobox.app/Contents/Helpers/llama/llama-server"))
        XCTAssertTrue(OfflineServerPID.isServerCommand("llama-server"))
        for command in ["", "/usr/local/bin/ollama", "/bin/sleep", "/Applications/Baobox.app/Contents/MacOS/Baobox",
                        "llama-server-wrapper", "/tmp/llama-server.sh"] {
            XCTAssertFalse(OfflineServerPID.isServerCommand(command), command)
        }
    }
}
