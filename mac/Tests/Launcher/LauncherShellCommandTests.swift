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
        for text in ["git", "ls", "docker", "npm", "", " ", "$", "$ ", "hello world", "swift build",
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
        XCTAssertFalse(LauncherShellCommand.allowsEveryCharacter("a\u{200F}b"))
    }

    // MARK: - 允许名单（第 10 步复查后定）

    /// 验证者的例子：宽字形、组合符号、双向重排、看不见的空格和格式符 —— 都不算命令。
    func testCharactersOutsideTheAllowlistAreNeverCommands() {
        let cases = [
            "echo " + String(repeating: "\u{FDFD}", count: 20) + ";rm -rf ~",          // ﷽：一个字形十来列宽，把尾巴推出面板
            "ls -la Z\u{0351}\u{0352}\u{0357}\u{035B}\u{0346}a\u{0300}\u{0301}l\u{0302}g\u{0303}o", // zalgo：组合符号往下画
            "ls -la e\u{0301}.txt",                                                   // 组合的 é（不是预组合的）
            "echo \u{05D0}>\u{05D1} -n",                                              // 希伯来字母：不用控制符也会重排
            "cat \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}.txt",                     // 阿拉伯字母
            "rm\u{00A0}-rf /tmp/x",                                                    // NBSP
            "ls\u{3000}-la",                                                          // 全角空格
            "r\u{00AD}m -rf /tmp/x",                                                   // 软连字符
            "ls -la a\u{FE0F}.txt",                                                    // 变体选择符
            "ls -la \u{E0041}\u{E0042}",                                               // 标签字符
            "git commit -m 'done \u{1F389}'",                                          // emoji
            "echo 3\u{00D7}4 -n", "echo 8\u{00F7}2 -n",                                // × ÷ 不收
            "cat \u{201C}a.txt\u{201D}",                                               // 弯引号
            "$ ls\u{200B} -la",                                                        // `$ ` 开头的也查
            // 第三轮：CJK 声调符号（组合符号）挂在一个字上；全角 / CJK 符号冒充 shell 的引号、注释、转义。
            "ls -la /tmp/a" + String(repeating: "\u{302E}", count: 60) + ";rm -rf ~",
            "ls -la \u{FF02}; rm -rf ~/ \u{FF02}",                                     // ＂
            "ls -la \u{FF07}; rm -rf ~/ \u{FF07}",                                     // ＇
            "ls -la \u{FF03} ; rm -rf ~/",                                             // ＃
            "ls -la \u{FF3C}; rm -rf ~/",                                              // ＼
            "ls -la \u{FF40}rm -rf ~/\u{FF40}",                                        // ｀
            "ls -la \u{301D}; rm -rf ~/\u{301E}",                                      // 〝〞
            "ls -la ./a \u{FF5C} sh", "ls -la ./a \u{FF06}", "echo \u{FF04}HOME ./a",   // ｜ ＆ ＄
            "cat \u{3003}a.txt", "cat \u{3012}a.txt",                                  // 〃 〒
            "ls 「; rm -rf ~/」", "ls 『; rm -rf ~/』", "$ cat 「说明」.md",              // 第四轮：「」『』也是引号
        ]
        for text in cases {
            XCTAssertNil(LauncherShellCommand.detect(text), text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))
        }
    }

    /// 中文路径、日文文件名、韩文、带变音符的拉丁字母（预组合）、全角字符：照算。
    func testAllowedScriptsStillMakeCommands() {
        for text in ["cd ~/文档/项目", "cat ~/書類/メモ.txt", "cat café.txt", "cat ~/문서/a.txt", "cd 中文目录/子目录",
                     "git commit -m \"修复登录：完成。\"", "cat ./ｆｉｌｅ.txt", "mv naïve.txt naive.txt", "$ cat 《说明》.md",
                     "git commit -m \"修复：登录（第２版），完成！对吗？是；\"", "cat ~/文档/《报告》【终版】.txt",
                     "cat ./ＲＥＰＯＲＴ１２.txt", "cd ~/项目〔旧〕", "mv a.txt 【b】〖c〗〈d〉.txt", "cat ~/资料、备份。txt", "cd ~/照片/二〇二六年"] {
            let expected = text.hasPrefix("$ ") ? String(text.dropFirst(2)) : text
            XCTAssertEqual(LauncherShellCommand.detect(text), expected, text)
        }
    }

    func testAllowlistRanges() {
        func allowed(_ value: UInt32) -> Bool { Unicode.Scalar(value).map(LauncherShellCommand.isAllowed) ?? false }
        for value: UInt32 in [0x20, 0x7E, 0xC0, 0xD6, 0xD8, 0xE9, 0xF6, 0xF8, 0x24F, 0x3001, 0x3002, 0x3007, 0x3008, 0x300B, 0x3010, 0x3011, 0x3014,
                              0x3017, 0x3041, 0x3096, 0x30A1, 0x30FA, 0x30FC, 0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xAC00, 0xD7A3,
                              0xFF01, 0xFF08, 0xFF09, 0xFF0C, 0xFF10, 0xFF19, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF21, 0xFF3A, 0xFF41,
                              0xFF5A] {
            XCTAssertTrue(allowed(value), String(format: "U+%04X", value))
        }
        for value: UInt32 in [0x09, 0x0A, 0x1F, 0x7F, 0x85, 0xA0, 0xAD, 0xBF, 0xD7, 0xF7, 0x250, 0x0301, 0x05D0, 0x0627,
                              0x200B, 0x200F, 0x202E, 0x2066, 0x3000, 0x3003, 0x3006, 0x300C, 0x300D, 0x300E, 0x300F, 0x3012, 0x3013, 0x3018, 0x301D, 0x301E,
                              0x302A, 0x302E, 0x302F, 0x303F, 0x3040, 0x3097, 0x30FB, 0x30FD, 0xFDFD, 0xFE0F, 0xFEFF, 0xFF00,
                              0xFF02, 0xFF03, 0xFF04, 0xFF06, 0xFF07, 0xFF0D, 0xFF0E, 0xFF0F, 0xFF20, 0xFF3C, 0xFF40, 0xFF5C,
                              0xFF5E, 0xFF5F, 0x1F389, 0xE0041] {
            XCTAssertFalse(allowed(value), String(format: "U+%04X", value))
        }
    }

    /// 整张允许名单逐个标量过一遍：每个都独立成字、看得见 —— 以后有人往表里加范围，这个测试会拦住组合符号、格式符这类。
    func testEveryAllowedScalarStandsAlone() {
        let forbidden: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark, .format, .control,
                                                       .spaceSeparator, .unassigned, .privateUse, .surrogate]
        var count = 0
        for range in LauncherShellCommand.allowedRanges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else {
                    XCTFail(String(format: "U+%04X 不是合法的标量", value))
                    continue
                }
                count += 1
                XCTAssertTrue(LauncherShellCommand.isAllowed(scalar))
                if value == 0x20 { continue }
                let properties = scalar.properties
                XCTAssertFalse(forbidden.contains(properties.generalCategory),
                               String(format: "U+%04X 的类别是 \(properties.generalCategory)", value))
                // 类别检查拦不住「修饰字母」这类会并进前一个字的（半角浊音符 U+FF9E 是 Lm）—— 第四轮加。
                XCTAssertFalse(properties.isGraphemeExtend, String(format: "U+%04X 会并进前一个字", value))
                XCTAssertFalse(properties.isDefaultIgnorableCodePoint, String(format: "U+%04X 默认不显示", value))
            }
        }
        // 这两条检查拦得住表外的那类字符：半角浊音符的类别是 Lm（类别检查放过），但它是 Grapheme_Extend。
        let voicedMark = Unicode.Scalar(0xFF9E)
        XCTAssertEqual(voicedMark?.properties.generalCategory, .modifierLetter)
        XCTAssertEqual(voicedMark?.properties.isGraphemeExtend, true)
        XCTAssertEqual(Unicode.Scalar(0x200B)?.properties.isDefaultIgnorableCodePoint, true)
        XCTAssertEqual(count, 39_508, "改了表就要改这个数（汉字占大头）—— 改之前先想清楚新加的字符是不是都独立成字、不比估的宽")
    }

    // MARK: - 第 10 步验证后定

    /// 验证者列的误判：一句英文、一句广告，不是命令。
    func testVerifierFalsePositivesAreRejected() {
        for text in ["cat and/or dog", "find and/or replace text", "python is great for data/science",
                     "find the U.S. embassy", "cd e.g. somewhere", "make sure i.e. it works", "cat videos on youtube.com",
                     "ps: I love you", "git gud", "npm i love you", "$ 5 off your first order", "$ 100 is a lot",
                     "brew coffee", "cp a b", "open the U.S. site", "cat my/your notes", "find it in Downloads/",
                     "kill the process", "open a.txt and b.txt", "$ -rf /", "$ 3.5 percent"] {
            XCTAssertNil(LauncherShellCommand.detect(text), text)
        }
    }

    /// 验证者列的漏判里该补的：make 的常见目标、ssh / scp 带 `@`。`echo hello`、`ssh host` 照旧不认。
    func testVerifierFalseNegativesThatAreNowCommands() {
        for text in ["make build", "make install", "make test", "make clean", "make all", "make run", "make dev", "make lint",
                     "ssh me@host", "ssh root@10.0.0.1", "scp me@host:notes notes", "npm --version", "tail -f log",
                     "ls ~/Desktop", "mv old.txt new.txt", "open google.com", "export const a=1", "npm i lodash",
                     "$ ./run.sh", "$ ~/bin/deploy --dry-run", "$ _build", "$ .venv/bin/python app.py", "$ g++ -O2 a.cpp"] {
            XCTAssertEqual(LauncherShellCommand.detect(text), text.hasPrefix("$ ") ? String(text.dropFirst(2)) : text, text)
        }
        for text in ["echo hello", "ssh host", "make it work", "make me a sandwich"] {
            XCTAssertNil(LauncherShellCommand.detect(text), text)
        }
    }

    /// 虚词只看引号外的词；有选项形状的词时不查；子命令位置上的那个子命令不查。
    func testFunctionWordRule() {
        XCTAssertEqual(LauncherShellCommand.detect("git commit \"fix the bug in my app\""),
                       "git commit \"fix the bug in my app\"", "引号里的虚词不算")
        XCTAssertEqual(LauncherShellCommand.detect("git commit -m fix the bug"), "git commit -m fix the bug", "有选项时不查")
        XCTAssertEqual(LauncherShellCommand.detect("git merge the-branch"), "git merge the-branch", "the-branch 不是 the")
        XCTAssertEqual(LauncherShellCommand.detect("git push origin main"), "git push origin main")
        XCTAssertNil(LauncherShellCommand.detect("git push it to me"))
        XCTAssertFalse(LauncherShellCommand.isFunctionWord("and/or"), "含 / 的词不拆开查（复查后定）")
        XCTAssertTrue(LauncherShellCommand.isFunctionWord("The"))
        XCTAssertTrue(LauncherShellCommand.isFunctionWord("me,"))
        XCTAssertFalse(LauncherShellCommand.isFunctionWord("it's"))
        XCTAssertFalse(LauncherShellCommand.isFunctionWord("main"))
        XCTAssertEqual(LauncherShellCommand.words("a 'b c' \"d\" e").map(\.quoted), [false, true, true, true, false])
        XCTAssertEqual(LauncherShellCommand.words("it's fine").map(\.quoted), [false, false], "词中间的撇号不开引号")
    }

    /// 含 `/` 的词：不拆开查虚词，但要拆开后不全是虚词或空串才算路径证据（第 10 步复查后定）。
    func testSlashWords() {
        for text in ["cd my/project", "cat in/out.log", "cp a.txt to/", "ls src/app", "cd /", "open ./a", "cat ../x"] {
            XCTAssertEqual(LauncherShellCommand.detect(text), text, text)
        }
        for text in ["cat and/or dog", "find and/or replace text", "python is great for data/science", "cat to/ from",
                     "open and/or close"] {
            XCTAssertNil(LauncherShellCommand.detect(text), text)
        }
        // 已知限制：参数里正好有英文虚词的认不出；加 `$ ` 就认。
        XCTAssertNil(LauncherShellCommand.detect("grep the file.txt"))
        XCTAssertEqual(LauncherShellCommand.detect("$ grep the file.txt"), "grep the file.txt")
        XCTAssertFalse(LauncherShellCommand.isPath("and/or"))
        XCTAssertFalse(LauncherShellCommand.isPath("to/"))
        XCTAssertTrue(LauncherShellCommand.isPath("/and/or"), "以 / 开头的照算")
        XCTAssertTrue(LauncherShellCommand.isPath("my/project"))
        XCTAssertTrue(LauncherShellCommand.isPath("in/out.log"))
        XCTAssertTrue(LauncherShellCommand.isPath("src/app"))
        XCTAssertFalse(LauncherShellCommand.isPath("and//or"), "只有虚词和空串")
    }

    func testDollarPromptNeedsACommandName() {
        XCTAssertTrue(LauncherShellCommand.looksLikeCommandName("npm"))
        XCTAssertTrue(LauncherShellCommand.looksLikeCommandName("./run.sh"))
        XCTAssertTrue(LauncherShellCommand.looksLikeCommandName("~/bin/x"))
        XCTAssertTrue(LauncherShellCommand.looksLikeCommandName("g++"))
        XCTAssertFalse(LauncherShellCommand.looksLikeCommandName("5"))
        XCTAssertFalse(LauncherShellCommand.looksLikeCommandName("$5"))
        XCTAssertFalse(LauncherShellCommand.looksLikeCommandName("-rf"))
        XCTAssertFalse(LauncherShellCommand.looksLikeCommandName("修复"))
        XCTAssertFalse(LauncherShellCommand.looksLikeCommandName("a;b"))
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
        XCTAssertFalse(LauncherShellCommand.isPath("U.S."), "以 . 结尾的不算")
        XCTAssertFalse(LauncherShellCommand.isPath("e.g."))
        XCTAssertTrue(LauncherShellCommand.isPath(".."))
        XCTAssertTrue(LauncherShellCommand.isPath("a/b."), "含 / 照算")
        XCTAssertTrue(LauncherShellCommand.isAssignment("a=b"))
        XCTAssertFalse(LauncherShellCommand.isAssignment("=b"))
        XCTAssertFalse(LauncherShellCommand.isAssignment("a="))
    }
}
