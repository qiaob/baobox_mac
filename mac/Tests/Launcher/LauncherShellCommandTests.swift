import Foundation
import XCTest

/// 输入像不像一条终端命令（docs/launcher/TECH_DESIGN.md §5.4「像命令」）：保守，宁可漏认，不要把英文句子当命令。
final class LauncherShellCommandTests: XCTestCase {

    func testCommandsWithOptionsPathsOrAssignments() {
        let commands = [
            "ls -la", "ls -1", "cd ~/Downloads", "cd ~", "cd ..", "open .", "cat README.md", "cat .env",
            "python3 main.py", "node index.js", "swift build -c release", "xcodebuild -scheme Baobox build",
            "docker run -it ubuntu bash", "kubectl --context=ali-ack-staging get pods -n pv-workers",
            "export PATH=/usr/local/bin:$PATH", "make DEBUG=1", "curl https://example.com", "wget http://x.org/a.zip",
            "ssh deploy@10.0.0.1", "scp a.txt host:/tmp", "chmod +x run.sh", "chmod 755 run.sh", "mkdir -p a/b",
            "rm -rf build", "mv a.txt b.txt", "cp -r src dst", "grep -rn TODO .", "find . -name '*.swift'",
            "tail -f /var/log/system.log", "kill -9 1234", "pip install -r requirements.txt",
            "git commit -m \"修复登录\"", "npx create-react-app my-app --template typescript",
        ]
        for command in commands {
            XCTAssertEqual(LauncherShellCommand.detect(command), command, command)
        }
    }

    func testCommonSubcommandsCountWithoutOptions() {
        for command in ["git status", "git push", "git pull", "git clone x", "docker ps", "docker images",
                        "kubectl get pods", "kubectl logs worker", "brew install wget", "brew upgrade",
                        "npm install", "npm run dev", "yarn install", "pnpm dev", "git cherry-pick abc"] {
            XCTAssertEqual(LauncherShellCommand.detect(command), command, command)
        }
    }

    func testDollarPromptIsStripped() {
        XCTAssertEqual(LauncherShellCommand.detect("$ npm run build"), "npm run build")
        XCTAssertEqual(LauncherShellCommand.detect("$ ls"), "ls", "$ 开头的不看命令表")
        XCTAssertEqual(LauncherShellCommand.detect("$   uptime  "), "uptime")
        XCTAssertEqual(LauncherShellCommand.detect("  git status  "), "git status", "去首尾空白")
    }

    func testSudoLooksAtTheCommandItRuns() {
        XCTAssertEqual(LauncherShellCommand.detect("sudo brew services restart"), "sudo brew services restart")
        XCTAssertEqual(LauncherShellCommand.detect("sudo rm -rf /tmp/x"), "sudo rm -rf /tmp/x")
        XCTAssertNil(LauncherShellCommand.detect("sudo make me a sandwich"))
        XCTAssertNil(LauncherShellCommand.detect("sudo apt update"), "apt 不在命令表里，后面也没有选项、路径")
    }

    func testEnglishSentencesAreNotCommands() {
        for text in ["open the door", "make it work", "find my phone", "find my phone.", "make it work...",
                     "kill time", "export data", "cat videos are funny", "open the door.", "find out why!",
                     "Find my phone", "Open the door", "Make it work -now"] {
            XCTAssertNil(LauncherShellCommand.detect(text), text)
        }
    }

    func testSingleWordsAndNonCommandsAreRejected() {
        for text in ["git", "ls", "docker", "npm", "", " ", "$", "$ ", "hello world", "swift build", "make install",
                     "ps aux", "git 怎么回滚", "cd 到桌面", "docker 是什么", "open 3.5 files", "rm 1.5",
                     "怎么用 git status"] {
            XCTAssertNil(LauncherShellCommand.detect(text), text)
        }
    }

    func testOnlySingleLines() {
        XCTAssertNil(LauncherShellCommand.detect("git status\ngit push"))
        XCTAssertNil(LauncherShellCommand.detect("$ ls\n$ pwd"))
        XCTAssertNil(LauncherShellCommand.detect("git " + String(repeating: "-a ", count: 1_000)), "太长")
    }

    /// 看不见、或让看到的和实际的不一样的字符：不认成命令（第 10 步验证后定，确认时显示的必须就是要跑的）。
    func testHiddenCharactersAreNeverCommands() {
        let cases = [
            "echo \u{202E}olleh",            // 从右往左覆盖
            "r\u{200B}m -rf /tmp/x",          // 零宽空格
            "git status\u{200D}",             // 零宽连接符
            "\u{FEFF}ls -la",                 // BOM
            "ls -la \u{2066}x\u{2069}",        // 方向隔离
            "rm -rf /tmp/x\u{0}",             // NUL
            "ls\t-la",                        // 中间的制表符
            "echo \u{7}hi -n",                // BEL
            "ls -la \u{1B}[31m",              // ESC 转义序列
            "echo \u{85}x -n",                // C1（NEL）
            "ls -la \u{061C}",                // 阿拉伯字母标记
            "git status\u{2028}rm -rf ~",     // 行分隔符：不止一行
            "git status\rrm -rf ~",
        ]
        for text in cases {
            XCTAssertNil(LauncherShellCommand.detect(text), text.debugDescription)
        }
        XCTAssertEqual(LauncherShellCommand.detect("\tls -la\t"), "ls -la", "首尾的制表符是空白，去掉")
        XCTAssertTrue(LauncherShellCommand.hasHiddenCharacters("a\u{200F}b"))
        XCTAssertFalse(LauncherShellCommand.hasHiddenCharacters("git commit -m \"修复登录 🎉\""))
    }

    func testTokenRules() {
        XCTAssertTrue(LauncherShellCommand.isOption("-x"))
        XCTAssertTrue(LauncherShellCommand.isOption("--force"))
        XCTAssertTrue(LauncherShellCommand.isOption("-9"))
        XCTAssertFalse(LauncherShellCommand.isOption("-"))
        XCTAssertFalse(LauncherShellCommand.isOption("--"))
        XCTAssertFalse(LauncherShellCommand.isOption("---x"))
        XCTAssertFalse(LauncherShellCommand.isOption("now"))
        XCTAssertTrue(LauncherShellCommand.isPath("a/b"))
        XCTAssertTrue(LauncherShellCommand.isPath("README.md"))
        XCTAssertTrue(LauncherShellCommand.isPath(".env"))
        XCTAssertTrue(LauncherShellCommand.isPath("~"))
        XCTAssertFalse(LauncherShellCommand.isPath("door."))
        XCTAssertFalse(LauncherShellCommand.isPath("work..."))
        XCTAssertFalse(LauncherShellCommand.isPath("3.5"))
        XCTAssertTrue(LauncherShellCommand.isAssignment("a=b"))
        XCTAssertFalse(LauncherShellCommand.isAssignment("=b"))
        XCTAssertFalse(LauncherShellCommand.isAssignment("a="))
    }
}
