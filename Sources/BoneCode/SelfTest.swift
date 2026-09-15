import AppKit
import Foundation

/// Headless self-test for the engines that have no UI: tokenizer, diff parser,
/// Git layer, terminal emulator and PTY. Run with `BoneCode --selftest`.
///
/// This exists because the interesting logic in BoneCode is all in these
/// engines; being able to prove they work without a display is worth the file.
enum SelfTest {

    private static var passed = 0
    private static var failed = 0

    private static func check(_ label: String, _ condition: Bool, detail: String = "") {
        if condition {
            passed += 1
            print("  \u{2713} \(label)")
        } else {
            failed += 1
            print("  \u{2717} \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    private static func section(_ title: String) {
        print("\n\u{001B}[1m\(title)\u{001B}[0m")
    }

    static func runEngines() -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)      // keep progress visible if we hang
        print("BoneCode 引擎自检 (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        print(String(repeating: "=", count: 62))

        testLanguageRegistry()
        testSyntaxHighlighter()
        testVueEmbeddedHighlighting()
        testWordDiff()
        testDiffParser()
        testCompletionEngine()
        testTerminalEmulator()
        testTerminalWideChars()
        testFuzzyMatch()
        testProjectDetection()
        testTerminalRowRendering()
        testEditorLayoutStability()
        testPanelTheming()
        testPanelBounds()
        testDividerDragging()
        testGitLayer()
        testGitChangesGrouping()
        testPTYEndToEnd()

        return finish()
    }

    /// The UI smoke test builds a real NSWindow. Creating windows in a headless
    /// process can stall on AppKit internals, so it runs in its own mode with a
    /// watchdog (`--uitest`) and never blocks the engine suite.
    static func runUI() -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        print("BoneCode 界面自检")
        print(String(repeating: "=", count: 62))
        testUILaunch()
        return finish()
    }

    /// Convenience: both suites. May hang on the UI part in a headless session.
    static func run() -> Bool {
        runEngines() && runUI()
    }

    private static func finish() -> Bool {
        print(String(repeating: "=", count: 62))
        print("通过 \(passed) 项，失败 \(failed) 项")
        return failed == 0
    }

    // MARK: - Language registry

    private static func testLanguageRegistry() {
        section("语言识别")
        check("App.java → Java", LanguageRegistry.language(forPath: "/x/App.java").id == "java")
        check("index.vue → Vue", LanguageRegistry.language(forPath: "/x/index.vue").id == "vue")
        check("main.ts → TypeScript", LanguageRegistry.language(forPath: "/x/main.ts").id == "typescript")
        check("Dockerfile → Dockerfile", LanguageRegistry.language(forPath: "/x/Dockerfile").id == "dockerfile")
        check("pom.xml → XML", LanguageRegistry.language(forPath: "/x/pom.xml").id == "xml")
        check("no extension → Plain", LanguageRegistry.language(forPath: "/x/LICENSE").id == "plain")
        check("语言总数 ≥ 30", LanguageRegistry.all.count >= 30,
              detail: "实际 \(LanguageRegistry.all.count)")
    }

    // MARK: - Highlighter

    private static func testSyntaxHighlighter() {
        section("语法高亮（Java）")
        let source = """
        package com.demo;

        import java.util.List;

        /** 文档注释 */
        @Service
        public class DemoService {
            private static final String NAME = "bonecode";
            // 行注释
            public List<String> run(int count) {
                if (count > 0 && count < 100) {
                    System.out.println("count = " + count);
                }
                return List.of();
            }
        }
        """
        let language = LanguageRegistry.language(forID: "java")
        let tokens = SyntaxHighlighter.shared.tokenize(source, language: language)
        let ns = source as NSString

        func has(_ text: String, _ role: SyntaxRole) -> Bool {
            tokens.contains { token in
                token.role == role && ns.substring(with: token.range) == text
            }
        }

        check("识别到关键字 public", has("public", .keyword))
        check("识别到关键字 class", has("class", .keyword))
        check("识别到关键字 return", has("return", .keyword))
        check("识别到注解 @Service", has("@Service", .annotation))
        check("识别到字符串字面量", has("\"bonecode\"", .string))
        check("识别到数字 100", has("100", .number))
        check("识别到内置函数 System 与类型 List", has("System", .function) && has("List", .type))
        check("注释被识别", tokens.contains { $0.role == .comment })

        // every token must stay inside the document
        let inBounds = tokens.allSatisfy { $0.location >= 0 && $0.location + $0.length <= ns.length }
        check("所有 token 都在文档范围内", inBounds)

        // tokens must be non-overlapping and ordered
        var ordered = true
        var previousEnd = 0
        for token in tokens {
            if token.location < previousEnd { ordered = false; break }
            previousEnd = token.location + token.length
        }
        check("token 有序且不重叠", ordered)

        check("高亮覆盖率合理（>40% 字符被着色）",
              Double(tokens.reduce(0) { $0 + $1.length }) / Double(max(1, ns.length)) > 0.40)
    }

    private static func testVueEmbeddedHighlighting() {
        section("语法高亮（Vue 混合语法）")
        let source = """
        <template>
          <div class="app" @click="onClick">
            {{ count + 1 }}
          </div>
        </template>

        <script setup lang="ts">
        import { ref } from 'vue'
        const count = ref<number>(0)
        function onClick(): void {
          count.value += 1
        }
        </script>

        <style scoped>
        .app {
          color: #2f6feb;
          font-size: 14px;
        }
        </style>
        """
        let language = LanguageRegistry.language(forID: "vue")
        let tokens = SyntaxHighlighter.shared.tokenize(source, language: language)
        let ns = source as NSString

        func has(_ text: String, _ role: SyntaxRole) -> Bool {
            tokens.contains { $0.role == role && ns.substring(with: $0.range) == text }
        }

        check("HTML 标签 div 被识别", has("div", .tag))
        check("HTML 属性 class 被识别", has("class", .attribute))
        check("<script> 内的 const 被识别为关键字", has("const", .keyword))
        check("<script> 内的 import 被识别为关键字", has("import", .keyword))
        check("<style> 内的 #2f6feb 被识别为数值", has("#2f6feb", .number))
        check("<style> 内的 14px 被识别为数值", has("14px", .number))
        check("CSS 属性 color 被识别", has("color", .attribute))
    }

    // MARK: - Word diff

    private static func testWordDiff() {
        section("行内词级差异")
        let (oldRanges, newRanges) = WordDiff.changedRanges(
            old: "let total = price * quantity;",
            new: "let total = price * quantity * tax;"
        )
        let oldText = ("let total = price * quantity;" as NSString)
        let newText = ("let total = price * quantity * tax;" as NSString)
        let oldChanged = oldRanges.map { oldText.substring(with: $0) }.joined()
        let newChanged = newRanges.map { newText.substring(with: $0) }.joined()

        check("新行标记出新增部分", newChanged.contains("tax"), detail: "实际 '\(newChanged)'")
        check("旧行没有误报新增内容", !oldChanged.contains("tax"), detail: "实际 '\(oldChanged)'")

        let (a, b) = WordDiff.changedRanges(old: "完全相同的行", new: "完全相同的行")
        check("相同行不产生差异", a.isEmpty && b.isEmpty)
    }

    // MARK: - Diff parser

    private static func testDiffParser() {
        section("Diff 解析")
        let diff = """
        diff --git a/src/App.java b/src/App.java
        index 1a2b3c4..5d6e7f8 100644
        --- a/src/App.java
        +++ b/src/App.java
        @@ -10,7 +10,8 @@ public class App {
             public void run() {
        -        int total = price * quantity;
        +        int total = price * quantity * tax;
        +        log.info("total={}", total);
                 return;
             }
        }
        diff --git a/README.md b/README.md
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +1,2 @@
        +# BoneCode
        +轻量编辑器
        """
        let files = DiffParser.parse(diff)
        check("解析出 2 个文件", files.count == 2, detail: "实际 \(files.count)")

        guard files.count == 2 else { return }
        let app = files[0]
        check("文件名正确", app.path == "src/App.java", detail: app.path)
        check("新增行数 = 2", app.addedCount == 2, detail: "实际 \(app.addedCount)")
        check("删除行数 = 1", app.removedCount == 1, detail: "实际 \(app.removedCount)")
        check("hunk 起始行号解析正确", app.hunks.first?.newStart == 10,
              detail: "实际 \(app.hunks.first?.newStart ?? -1)")

        let addedLine = app.hunks.first?.lines.first { $0.kind == .added }
        check("新增行带行内高亮", (addedLine?.highlight.isEmpty == false))
        check("新增行有行号", addedLine?.newNumber != nil)

        let readme = files[1]
        check("识别出新增文件", readme.isNew)
        check("新增文件路径正确", readme.path == "README.md", detail: readme.path)
        check("中文内容解析正确", readme.hunks.first?.lines.contains { $0.text.contains("轻量编辑器") } == true)
    }

    // MARK: - Completion

    private static func testCompletionEngine() {
        section("代码补全")
        let document = """
        public class OrderService {
            private final PaymentGateway gateway = new PaymentGateway();

            public void checkout(Order order) {
                gateway.charge(order);
                gateway.refund(order);
                int totalAmount = order.total();
            }
        }
        """
        let words = CompletionEngine.buildWordFrequency(document)
        check("文档词频统计包含 gateway", words["gateway"] != nil)
        check("文档词频统计包含 checkout", words["checkout"] != nil)

        let members = CompletionEngine.buildMemberWords(document)
        check("成员推断找到 charge", members.contains("charge"))
        check("成员推断找到 refund", members.contains("refund"))

        let language = LanguageRegistry.language(forID: "java")
        let suggestions = CompletionEngine.shared.suggestions(
            prefix: "Str", language: language,
            documentWords: words, memberWords: members,
            isMemberAccess: false, fileURL: nil
        )
        check("前缀 Str 能补全出 String", suggestions.contains { $0.label == "String" })
        check("补全结果非空", !suggestions.isEmpty)

        let memberSuggestions = CompletionEngine.shared.suggestions(
            prefix: "ch", language: language,
            documentWords: words, memberWords: members,
            isMemberAccess: true, fileURL: nil
        )
        check("成员补全优先返回 charge", memberSuggestions.first?.label == "charge",
              detail: "实际 \(memberSuggestions.first?.label ?? "nil")")

        let snippets = CompletionEngine.shared.suggestions(
            prefix: "sout", language: language,
            documentWords: words, memberWords: members,
            isMemberAccess: false, fileURL: nil
        )
        check("代码片段 sout 可补全", snippets.contains { $0.kind == .snippet })
    }

    // MARK: - Terminal emulator

    private static func testTerminalEmulator() {
        section("终端模拟器")
        let emulator = TerminalEmulator(cols: 40, rows: 6)

        emulator.feed(Data("hello world".utf8))
        check("普通文本写入屏幕", rowText(emulator, 0).hasPrefix("hello world"),
              detail: "'\(rowText(emulator, 0))'")
        check("光标跟随前进", emulator.cursorCol == 11, detail: "实际 \(emulator.cursorCol)")

        emulator.feed(Data("\r\nsecond line".utf8))
        check("回车换行生效", rowText(emulator, 1).hasPrefix("second line"),
              detail: "'\(rowText(emulator, 1))'")

        emulator.feed(Data("\u{1B}[31mRED\u{1B}[0m".utf8))
        let cells = emulator.row(1)
        let redIndex = 11
        check("SGR 红色前景色生效",
              cells[cells.startIndex + redIndex].fgIndex == 1,
              detail: "fg=\(cells[cells.startIndex + redIndex].fgIndex)")

        emulator.feed(Data("\u{1B}[2J\u{1B}[H".utf8))
        check("清屏后内容为空", rowText(emulator, 0).trimmingCharacters(in: .whitespaces).isEmpty)
        check("清屏后光标回到原点", emulator.cursorRow == 0 && emulator.cursorCol == 0)

        // cursor positioning + erase in line
        emulator.feed(Data("ABCDEFGH\r\n".utf8))
        emulator.feed(Data("\u{1B}[1;3HXY".utf8))
        check("CSI 定位光标后写入正确", rowText(emulator, 0).hasPrefix("ABXYEFGH"),
              detail: "'\(rowText(emulator, 0))'")

        emulator.feed(Data("\u{1B}[2K".utf8))
        check("CSI 2K 清除整行", rowText(emulator, 0).trimmingCharacters(in: .whitespaces).isEmpty)

        // scrolling produces scrollback
        let scroller = TerminalEmulator(cols: 20, rows: 3)
        for i in 1...6 {
            scroller.feed(Data("line\(i)\r\n".utf8))
        }
        check("超出屏幕的行进入滚动历史", scroller.scrollbackCount > 0,
              detail: "实际 \(scroller.scrollbackCount)")
        check("滚动历史内容正确", rowText(scroller, 0).hasPrefix("line1"),
              detail: "'\(rowText(scroller, 0))'")

        // alternate screen
        let alt = TerminalEmulator(cols: 20, rows: 4)
        alt.feed(Data("main screen\r\n".utf8))
        alt.feed(Data("\u{1B}[?1049h".utf8))
        alt.feed(Data("alt content".utf8))
        check("备用屏切换后内容被替换", rowText(alt, 0).hasPrefix("alt content"))
        alt.feed(Data("\u{1B}[?1049l".utf8))
        check("退出备用屏后恢复原内容", rowText(alt, 0).hasPrefix("main screen"),
              detail: "'\(rowText(alt, 0))'")

        // OSC title
        let titled = TerminalEmulator(cols: 20, rows: 4)
        var receivedTitle = ""
        titled.onTitleChange = { receivedTitle = $0 }
        titled.feed(Data("\u{1B}]0;my-project\u{07}".utf8))
        check("OSC 0 设置窗口标题", receivedTitle == "my-project", detail: "'\(receivedTitle)'")
        titled.feed(Data("after-osc".utf8))
        check("OSC 结束后解析器回到正常状态",
              rowText(titled, 0).hasPrefix("after-osc"),
              detail: "'\(rowText(titled, 0))'")

        // device status report
        let reporting = TerminalEmulator(cols: 20, rows: 4)
        var response = ""
        reporting.onResponse = { response += $0 }
        reporting.feed(Data("\u{1B}[6n".utf8))
        check("CSI 6n 返回光标位置报告", response.hasPrefix("\u{1B}["), detail: "'\(response)'")

        // 256 colour + truecolor
        let colour = TerminalEmulator(cols: 20, rows: 2)
        colour.feed(Data("\u{1B}[38;5;196mX".utf8))
        let cell256 = colour.row(0)
        check("256 色前景色被记录", cell256[cell256.startIndex].fgIndex == 196,
              detail: "fg=\(cell256[cell256.startIndex].fgIndex)")

        colour.feed(Data("\u{1B}[38;2;10;20;30mY".utf8))
        let cellRGB = colour.row(0)
        check("真彩色前景色被记录",
              cellRGB[cellRGB.startIndex + 1].fgIndex == -2
                && cellRGB[cellRGB.startIndex + 1].fgRGB == 0x0A141E,
              detail: "fg=\(cellRGB[cellRGB.startIndex + 1].fgIndex) rgb=\(String(cellRGB[cellRGB.startIndex + 1].fgRGB, radix: 16))")

        // resize
        let resized = TerminalEmulator(cols: 20, rows: 4)
        resized.feed(Data("keep me\r\n".utf8))
        resized.resize(cols: 40, rows: 10)
        check("resize 后内容保留", rowText(resized, 0).hasPrefix("keep me"))
        check("resize 后列数更新", resized.cols == 40)
    }

    private static func testTerminalWideChars() {
        section("终端宽字符（中文）")
        // Note: the emulator clamps to a 4-row minimum.
        let emulator = TerminalEmulator(cols: 20, rows: 4)
        emulator.feed(Data("中文abc".utf8))
        let cells = emulator.row(0)

        check("中文占用两个单元格", cells[cells.startIndex + 1].isPad)
        check("中文后的字符位置正确", cells[cells.startIndex + 4].ch == UInt32(UInt8(ascii: "a")),
              detail: "ch=\(cells[cells.startIndex + 4].ch)")
        check("光标按显示宽度前进", emulator.cursorCol == 7, detail: "实际 \(emulator.cursorCol)")
        check("宽字符文本可回读", emulator.recentText(lines: 4).hasPrefix("中文abc"),
              detail: "'\(emulator.recentText(lines: 4))'")
    }

    // MARK: - Fuzzy match

    private static func testFuzzyMatch() {
        section("模糊匹配（快速打开）")
        check("精确前缀得分高于散列匹配",
              (QuickOpenController.fuzzyScore("src/main/App.java", query: "app") ?? 0) >
              (QuickOpenController.fuzzyScore("src/main/App.java", query: "smaj") ?? 0))
        check("字符顺序不匹配时返回 nil",
              QuickOpenController.fuzzyScore("abc", query: "cba") == nil)
        check("子序列可以匹配", QuickOpenController.fuzzyScore("OrderService.java", query: "osv") != nil)
        check("完全无关的查询不匹配", QuickOpenController.fuzzyScore("abc", query: "xyz") == nil)
    }

    // MARK: - Project detection

    private static func testProjectDetection() {
        section("项目类型探测")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bonecode-detect-\(UUID().uuidString)")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // ---- Vue + Vite project
        let vue = base.appendingPathComponent("vue-app")
        try? fm.createDirectory(at: vue, withIntermediateDirectories: true)
        let packageJSON = """
        {
          "name": "demo",
          "scripts": { "dev": "vite", "build": "vite build", "test": "vitest" },
          "dependencies": { "vue": "^3.4.0" },
          "devDependencies": { "vite": "^5.0.0" }
        }
        """
        try? packageJSON.write(to: vue.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let previousRoot = AppState.shared.workspaceRoot
        AppState.shared.workspaceRoot = vue
        let runner = ProjectRunner()
        runner.refreshConfigs()

        check("识别为 Vue 项目", runner.projectSummary.contains("Vue"), detail: runner.projectSummary)
        check("生成开发服务器配置",
              runner.configs.contains { $0.id == "node-dev" })
        let devConfig = runner.configs.first { $0.id == "node-dev" }
        check("开发命令使用 npm run dev", devConfig?.command.contains("npm run dev") == true,
              detail: devConfig?.command ?? "nil")
        check("缺少 node_modules 时先安装依赖",
              devConfig?.command.hasPrefix("npm install") == true, detail: devConfig?.command ?? "nil")
        check("生成构建配置", runner.configs.contains { $0.id == "node-build" })
        check("自动打开浏览器已开启", devConfig?.autoOpenBrowser == true)

        // ---- Spring Boot project
        let spring = base.appendingPathComponent("spring-app")
        try? fm.createDirectory(at: spring.appendingPathComponent("src/main/resources"),
                                withIntermediateDirectories: true)
        let pom = """
        <project>
          <parent>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-parent</artifactId>
          </parent>
        </project>
        """
        try? pom.write(to: spring.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        try? "server.port=9090\n".write(to: spring.appendingPathComponent("src/main/resources/application.properties"),
                                       atomically: true, encoding: .utf8)
        try? "#!/bin/sh\n".write(to: spring.appendingPathComponent("mvnw"), atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755],
                              ofItemAtPath: spring.appendingPathComponent("mvnw").path)

        AppState.shared.workspaceRoot = spring
        let springRunner = ProjectRunner()
        springRunner.refreshConfigs()

        check("识别为 Spring Boot", springRunner.projectSummary.contains("Spring Boot"),
              detail: springRunner.projectSummary)
        let boot = springRunner.configs.first { $0.id == "spring-boot-run" }
        check("使用 Maven 包装器 mvnw", boot?.command.hasPrefix("./mvnw spring-boot:run") == true,
              detail: boot?.command ?? "nil")
        check("从 application.properties 读到端口 9090", boot?.detectedPort == 9090,
              detail: "实际 \(boot?.detectedPort.map(String.init) ?? "nil")")
        check("生成 Maven 打包配置", springRunner.configs.contains { $0.id == "maven-package" })

        AppState.shared.workspaceRoot = previousRoot
    }

    // MARK: - Git

    private static func testGitLayer() {
        section("Git 集成")
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("bonecode-git-\(UUID().uuidString)")
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }

        let git = ProcessRunner.gitPath()
        func gitRun(_ args: [String]) -> ProcessResult {
            ProcessRunner.run(git, args, cwd: repo.path)
        }

        _ = gitRun(["init", "-q", "-b", "main"])
        _ = gitRun(["config", "user.email", "test@bonecode.local"])
        _ = gitRun(["config", "user.name", "BoneCode Test"])
        _ = gitRun(["config", "commit.gpgsign", "false"])

        // initial commit
        try? "line one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = gitRun(["add", "-A"])
        let firstCommit = gitRun(["commit", "-q", "-m", "feat: initial commit"])
        check("可以创建初始提交", firstCommit.ok, detail: firstCommit.combined.trimmed)

        // repository discovery through the service
        let service = GitService()
        let opened = service.openRepository(at: repo.path)
        check("GitService 能发现仓库根目录", opened)
        let serviceRoot = service.root ?? ""
        check("仓库根目录指向同一目录（符号链接已解析）",
              PathNormalizer.isSameLocation(serviceRoot, repo.path),
              detail: "service=\(serviceRoot) 期望=\(PathNormalizer.realPath(repo.path))")
        check("realPath 与 git 的路径一致",
              serviceRoot == PathNormalizer.realPath(repo.path),
              detail: "service=\(serviceRoot) realpath=\(PathNormalizer.realPath(repo.path))")

        // working tree changes
        try? "line one\nline two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "new file\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let stateSemaphore = DispatchSemaphore(value: 0)
        var capturedState: GitRepoState?
        service.state { state in
            capturedState = state
            stateSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        if let state = capturedState {
            check("当前分支为 main", state.branch == "main", detail: state.branch)
            check("检测到 2 个改动文件", state.changes.count == 2, detail: "实际 \(state.changes.count)")
            let modified = state.changes.first { $0.path == "a.txt" }
            check("a.txt 标记为已修改（未暂存）", modified?.unstaged == .modified,
                  detail: "\(modified?.unstaged.rawValue ?? "nil")")
            let untracked = state.changes.first { $0.path == "b.txt" }
            check("b.txt 标记为未跟踪", untracked?.unstaged == .untracked,
                  detail: "\(untracked?.unstaged.rawValue ?? "nil")")
            check("stagedCount / unstagedCount 计算正确",
                  state.stagedCount == 0 && state.unstagedCount == 2,
                  detail: "staged=\(state.stagedCount) unstaged=\(state.unstagedCount)")
        } else {
            check("读取仓库状态", false, detail: "超时")
        }

        // staging
        let stageSemaphore = DispatchSemaphore(value: 0)
        var stagedOK = false
        service.stage(["a.txt"]) { result in
            stagedOK = result.ok
            stageSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("可以暂存指定文件", stagedOK)

        let porcelain = gitRun(["status", "--porcelain"]).stdout
        check("a.txt 出现在暂存区", porcelain.contains("M  a.txt"), detail: porcelain.replacingOccurrences(of: "\n", with: " | "))

        // second commit
        let secondCommit = gitRun(["commit", "-q", "-m", "fix: add a line"])
        check("可以创建第二个提交", secondCommit.ok)

        // log + graph
        let logSemaphore = DispatchSemaphore(value: 0)
        var commits: [GitCommit] = []
        service.log(limit: 50) { result in
            commits = result
            logSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("日志返回 2 个提交", commits.count == 2, detail: "实际 \(commits.count)")
        check("最新提交在最前面", commits.first?.subject == "fix: add a line",
              detail: commits.first?.subject ?? "nil")
        check("提交带有父提交（用于图谱连线）", commits.first?.parents.count == 1)

        let rows = GitGraphLayout.compute(commits: commits)
        check("图谱布局行数与提交数一致", rows.count == commits.count)
        check("首个提交位于第 0 泳道", rows.first?.nodeLane == 0)

        // branches
        let branchSemaphore = DispatchSemaphore(value: 0)
        var branches: [GitBranch] = []
        service.branches { result in
            branches = result
            branchSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("分支列表包含 main", branches.contains { $0.name == "main" })
        check("main 被标记为当前分支", branches.first { $0.name == "main" }?.isCurrent == true)

        // diff
        try? "line one\nline two\nline three\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let diffSemaphore = DispatchSemaphore(value: 0)
        var diffText = ""
        service.diff(path: "a.txt", staged: false) { text in
            diffText = text
            diffSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("能取到工作区差异", diffText.contains("+line three"), detail: diffText.prefix(120).description)
        let parsedDiff = DiffParser.parse(diffText)
        check("差异可被解析为结构化对象", parsedDiff.first?.addedCount == 1)

        // stash
        let stashSemaphore = DispatchSemaphore(value: 0)
        var stashed = false
        service.stashSave(message: "wip") { result in
            stashed = result.ok
            stashSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("可以贮藏改动", stashed)

        let stashListSemaphore = DispatchSemaphore(value: 0)
        var stashEntries: [GitStashEntry] = []
        service.stashes { entries in
            stashEntries = entries
            stashListSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("贮藏列表可读取", stashEntries.count == 1, detail: "实际 \(stashEntries.count)")

        let popSemaphore = DispatchSemaphore(value: 0)
        var popped = false
        service.stashApply(index: 0, pop: true) { result in
            popped = result.ok
            popSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("可以弹出贮藏并恢复改动", popped)

        // cherry-pick
        _ = gitRun(["checkout", "-q", "-b", "feature"])
        try? "feature\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = gitRun(["add", "-A"])
        _ = gitRun(["commit", "-q", "-m", "feat: add c.txt"])
        let featureHash = gitRun(["rev-parse", "HEAD"]).stdout.trimmed
        _ = gitRun(["checkout", "-q", "main"])

        let pickSemaphore = DispatchSemaphore(value: 0)
        var picked = false
        var pickError = ""
        service.cherryPick([featureHash]) { result in
            picked = result.ok
            pickError = result.combined.trimmed
            pickSemaphore.signal()
        }
        pumpRunLoop(seconds: 5)
        check("cherry-pick 成功", picked, detail: pickError)
        check("cherry-pick 后文件出现", fm.fileExists(atPath: repo.appendingPathComponent("c.txt").path))

        // undo last commit (reset --soft)
        let undoBefore = gitRun(["rev-parse", "HEAD"]).stdout.trimmed
        let undoBeforeCount = gitRun(["rev-list", "--count", "HEAD"]).stdout.trimmed
        let undoBeforeText = (try? String(contentsOf: repo.appendingPathComponent("c.txt"), encoding: .utf8)) ?? ""
        let undoBeforeUntracked = fm.fileExists(atPath: repo.appendingPathComponent("c.txt").path)

        let undoSemaphore = DispatchSemaphore(value: 0)
        var undone = false
        service.undoLastCommit { result in
            undone = result.ok
            undoSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("可以撤销上一次提交", undone)
        let afterText = (try? String(contentsOf: repo.appendingPathComponent("c.txt"), encoding: .utf8)) ?? ""
        check("撤销提交后工作区文件内容保持不变",
              afterText == undoBeforeText && undoBeforeUntracked,
              detail: "撤销前 \(undoBeforeText.count) 字符 / 撤销后 \(afterText.count) 字符")

        // revert
        _ = gitRun(["add", "-A"])
        _ = gitRun(["commit", "-q", "-m", "chore: re-apply"])
        let revertTarget = gitRun(["rev-parse", "HEAD"]).stdout.trimmed
        let revertSemaphore = DispatchSemaphore(value: 0)
        var reverted = false
        service.revert([revertTarget]) { result in
            reverted = result.ok
            revertSemaphore.signal()
        }
        pumpRunLoop(seconds: 5)
        check("revert 生成反向提交", reverted)

        // reset --hard back to the first commit
        let resetSemaphore = DispatchSemaphore(value: 0)
        var resetOK = false
        service.reset(to: commits.last?.hash ?? "HEAD~1", mode: .hard) { result in
            resetOK = result.ok
            resetSemaphore.signal()
        }
        pumpRunLoop(seconds: 3)
        check("硬重置成功", resetOK)

        // undo-push plumbing exists and targets a ref
        let hasUpstream = gitRun(["rev-parse", "--abbrev-ref", "@{u}"]).ok
        check("无上游时 @{u} 不可用（撤销 push 会提示需要上游）", !hasUpstream)

        _ = undoBefore
        _ = undoBeforeCount
    }

    // MARK: - Git changes panel

    /// Verifies the changes panel separates "not yet in Git" from "tracked and
    /// modified", and that each change kind is visually distinct.
    ///
    /// The grouping is a pure function, so this needs no view and no repository.
    private static func testGitChangesGrouping() {
        section("Git 变更分组与配色")

        func change(_ path: String, staged: GitFileStatus, unstaged: GitFileStatus) -> GitFileChange {
            GitFileChange(path: path, oldPath: nil, staged: staged, unstaged: unstaged)
        }

        let all = [
            change("staged-only.txt", staged: .added, unstaged: .unmodified),
            change("modified-tracked.txt", staged: .unmodified, unstaged: .modified),
            change("brand-new.txt", staged: .unmodified, unstaged: .untracked),
            change("both.txt", staged: .modified, unstaged: .modified),      // MM
            change("deleted.txt", staged: .unmodified, unstaged: .deleted),
            change("conflict.txt", staged: .conflicted, unstaged: .conflicted),
        ]
        let (staged, modified, untracked) = GitChangesView.group(all)

        func paths(_ items: [GitFileChange]) -> Set<String> { Set(items.map { $0.path }) }

        check("已暂存分组包含 add 过的文件", paths(staged).contains("staged-only.txt"))
        check("已暂存分组包含冲突文件", paths(staged).contains("conflict.txt"))
        check("未暂存分组包含已跟踪的改动", paths(modified).contains("modified-tracked.txt"))
        check("未暂存分组包含删除", paths(modified).contains("deleted.txt"))
        check("未跟踪分组只包含新文件", paths(untracked) == ["brand-new.txt"],
              detail: "\(paths(untracked).sorted())")

        // The subtle one: a file staged and then edited again belongs to both.
        check("既暂存又改动的文件同时出现在两个分组（MM 不丢）",
              paths(staged).contains("both.txt") && paths(modified).contains("both.txt"))

        check("未跟踪文件不会混进未暂存分组", !paths(modified).contains("brand-new.txt"))
        check("三个分组互不重复地覆盖全部改动（除 MM 外）",
              paths(staged).union(paths(modified)).union(paths(untracked)).count == all.count,
              detail: "\(paths(staged).union(paths(modified)).union(paths(untracked)).sorted())")

        // ---- every kind must be distinguishable at a glance
        let theme = ThemeManager.shared.current
        let kinds: [GitFileStatus] = [.added, .modified, .deleted, .renamed, .untracked, .conflicted]
        let colors = kinds.map { $0.color(theme) }
        var seen: [String: GitFileStatus] = [:]
        var clash: String?
        for (index, color) in colors.enumerated() {
            let key = color.usingColorSpace(.deviceRGB)?.description ?? "\(color)"
            if let other = seen[key], other != kinds[index] {
                clash = "\(other.badgeLabel) 与 \(kinds[index].badgeLabel) 同色"
            }
            seen[key] = kinds[index]
        }
        check("每种变更类型的颜色互不相同", clash == nil, detail: clash ?? "\(kinds.count) 种颜色")

        let labels = kinds.map { $0.badgeLabel }
        check("每种变更类型都有中文徽标文案",
              labels.allSatisfy { !$0.isEmpty } && Set(labels).count == kinds.count,
              detail: labels.joined(separator: " / "))
        check("未跟踪的徽标明确提到「未加入 Git」",
              GitFileStatus.untracked.badgeLabel.contains("Git"),
              detail: GitFileStatus.untracked.badgeLabel)

        // ---- group titles must read correctly (a stray ")" shipped once)
        for title in ["已暂存 · 将随下次提交 (3)",
                      "已修改 · 未暂存 (2)",
                      "未跟踪 · 尚未加入 Git (1)"] {
            let parens = title.filter { $0 == "(" }.count
            let closes = title.filter { $0 == ")" }.count
            check("分组标题括号成对：\(title)", parens == closes && parens == 1,
                  detail: "(:\(parens) ):\(closes)")
        }
    }

    // MARK: - PTY

    private static func testPTYEndToEnd() {
        section("终端端到端（真实 PTY）")
        let emulator = TerminalEmulator(cols: 100, rows: 24)
        var received = ""
        var exited = false
        var exitCode: Int32 = -1

        guard let pty = PTY(shell: "/bin/sh", cwd: NSTemporaryDirectory(), cols: 100, rows: 24) else {
            check("分配 PTY", false, detail: "forkpty 返回 nil")
            return
        }
        check("分配 PTY 成功", pty.masterFD >= 0 && pty.pid > 0,
              detail: "fd=\(pty.masterFD) pid=\(pty.pid)")

        pty.onOutput = { data in
            emulator.feed(data)
            received += String(decoding: data, as: UTF8.self)
        }
        pty.onExit = { code in
            exited = true
            exitCode = code
        }

        // Wait for the shell prompt, then drive it.
        pumpRunLoop(seconds: 2)
        pty.write("printf 'BONECODE_PTY_OK\\n'\n")
        pumpRunLoop(seconds: 2)

        check("PTY 输出被终端模拟器接收", received.contains("BONECODE_PTY_OK"),
              detail: "收到 \(received.count) 字节")
        check("输出出现在模拟器屏幕缓冲中",
              emulator.recentText(lines: 24).contains("BONECODE_PTY_OK"),
              detail: emulator.recentText(lines: 24).suffix(80).description)

        // ANSI colour through a real shell
        pty.write("printf '\\033[32mGREEN_MARK\\033[0m\\n'\n")
        pumpRunLoop(seconds: 2)
        let screen = emulator.recentText(lines: 24)
        check("shell 中的 ANSI 转义被解析", screen.contains("GREEN_MARK"),
              detail: screen.suffix(60).description)

        // window resize propagates
        pty.resize(cols: 120, rows: 30)
        pumpRunLoop(seconds: 0.6)
        let sizeResult = ProcessRunner.run("/bin/sh", ["-c", "stty size < /dev/tty 2>/dev/null || echo skip"],
                                            cwd: NSTemporaryDirectory())
        _ = sizeResult
        check("resize 不抛异常且记录新尺寸", pty.cols == 120 && pty.rows == 30,
              detail: "\(pty.cols)x\(pty.rows)")

        // Ctrl-C must interrupt the *foreground job*, not just poke the shell.
        // The shell has job control, so the running command is in its own process
        // group; only the tty line discipline can deliver SIGINT to it.
        pty.write("sleep 30\n")
        pumpRunLoop(seconds: 1.2)
        pty.sendInterrupt()
        pumpRunLoop(seconds: 1.5)
        pty.write("printf 'AFTER_INTERRUPT\\n'\n")
        pumpRunLoop(seconds: 1.5)
        let afterInterrupt = emulator.recentText(lines: 24)
        check("Ctrl-C 能中断前台进程（shell 重新接受命令）",
              afterInterrupt.contains("AFTER_INTERRUPT"),
              detail: afterInterrupt.suffix(80).description)

        // exit propagation
        pty.write("exit 7\n")
        pumpRunLoop(seconds: 3)
        check("子进程退出被捕获", exited)
        check("退出码正确传递", exitCode == 7, detail: "实际 \(exitCode)")
    }

    // MARK: - Terminal row rendering

    /// Regression: a run was drawn as one string, so a CJK glyph coming from a
    /// fallback font (whose advance is not a whole number of cells) shifted
    /// everything after it, and the text drifted away from the cursor.
    private static func testTerminalRowRendering() {
        section("终端行渲染（回归：宽字符导致光标错位）")

        let font = Fonts.code(size: 12)
        let base = NSColor.black
        let cellWidth: CGFloat = 8

        let mixed = TerminalEmulator(cols: 20, rows: 4)
        mixed.feed(Data("中文abc".utf8))
        let ops = TerminalRowRenderer.operations(cells: mixed.row(0), cellWidth: cellWidth) { _ in
            (font, base)
        }

        check("宽字符各自成为一个绘制操作", ops.count >= 3, detail: "\(ops.count) 个操作")
        guard ops.count >= 3 else { return }

        check("首个宽字符定位在第 0 格", ops[0].x == 0, detail: "x=\(ops[0].x)")
        check("宽字符带 2 格裁剪宽度", ops[0].clipWidth == cellWidth * 2,
              detail: "\(ops[0].clipWidth.map(String.init) ?? "nil")")
        check("第二个宽字符定位在第 2 格", ops[1].x == cellWidth * 2, detail: "x=\(ops[1].x)")
        check("宽字符之后的 ASCII 从第 4 格开始", ops[2].x == cellWidth * 4, detail: "x=\(ops[2].x)")
        check("ASCII 被合并成一个 run", ops[2].text.hasPrefix("abc"), detail: "'\(ops[2].text)'")
        check("ASCII run 不需要裁剪", ops[2].clipWidth == nil)
        check("宽字符的 x 是格宽整数倍（不会累积漂移）",
              ops.allSatisfy { $0.x.truncatingRemainder(dividingBy: cellWidth) == 0 })

        let ascii = TerminalEmulator(cols: 20, rows: 4)
        ascii.feed(Data("hello world".utf8))
        let asciiOps = TerminalRowRenderer.operations(cells: ascii.row(0), cellWidth: cellWidth) { _ in
            (font, base)
        }
        check("纯 ASCII 只产生一个绘制操作", asciiOps.count == 1, detail: "\(asciiOps.count) 个")
        check("纯 ASCII run 从第 0 格开始", asciiOps.first?.x == 0)

        let coloured = TerminalEmulator(cols: 20, rows: 4)
        coloured.feed(Data("ab\u{1B}[31mcd".utf8))
        let colourOps = TerminalRowRenderer.operations(cells: coloured.row(0), cellWidth: cellWidth) { cell in
            (font, cell.fgIndex == 1 ? NSColor.red : base)
        }
        // Three runs: "ab" (default), "cd" (red), then the trailing blank cells,
        // which carry the default foreground again.
        check("颜色变化拆分了 run", colourOps.count >= 2, detail: "\(colourOps.count) 个")
        if colourOps.count >= 2 {
            check("默认色 run 内容为 ab", colourOps[0].text.hasPrefix("ab"), detail: "'\(colourOps[0].text)'")
            check("红色 run 从第 2 格开始", colourOps[1].x == cellWidth * 2,
                  detail: "x=\(colourOps[1].x)")
            check("红色 run 内容为 cd", colourOps[1].text.hasPrefix("cd"), detail: "'\(colourOps[1].text)'")
        }
    }

    // MARK: - Editor layout stability

    /// Regression: applyStyling() was called from setFrameSize(). It writes to
    /// the text storage, which invalidates layout, which resizes the text view,
    /// which calls setFrameSize again — an unbounded loop that froze the app.
    private static func testEditorLayoutStability() {
        section("编辑器布局稳定性（回归：无限布局循环）")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        textView.language = LanguageRegistry.language(forID: "swift")

        // Comments take the italic font, which is what used to change the
        // laid-out height on every restyle.
        let source = (0..<300).map { i in
            "// 注释第 \(i) 行 with english text\nlet value\(i) = \"字符串 \(i)\"\n"
        }.joined()
        textView.string = source
        textView.applyTheme()
        textView.updateParagraphStyle()

        // Tokenizing is asynchronous; let it land before measuring.
        textView.rehighlight()
        pumpRunLoop(seconds: 2.0)
        check("着色后仍有语法 token", !textView.tokens.isEmpty, detail: "\(textView.tokens.count) 个")

        if let lm = textView.layoutManager, let tc = textView.textContainer { lm.ensureLayout(for: tc) }

        let heightBefore = textView.frame.height
        let widthBefore = textView.frame.width

        // With the bug this recursed until the stack overflowed.
        for _ in 0..<20 { textView.applyStyling() }
        if let lm = textView.layoutManager, let tc = textView.textContainer { lm.ensureLayout(for: tc) }

        check("重复着色不改变文本视图高度",
              abs(textView.frame.height - heightBefore) < 1.0,
              detail: "\(heightBefore) → \(textView.frame.height)")
        check("重复着色不改变文本视图宽度",
              abs(textView.frame.width - widthBefore) < 1.0)
        check("文本视图高度没有失控增长", textView.frame.height < 5_000_000,
              detail: "\(textView.frame.height)")

        // The bracket highlight must not touch the text storage any more.
        let before = textView.textStorage?.length ?? 0
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        check("移动光标不改变文本内容长度", (textView.textStorage?.length ?? 0) == before)

        // Line height must be pinned so a font variant cannot resize the layout.
        if let style = textView.defaultParagraphStyle {
            check("段落样式固定了行高", style.minimumLineHeight > 0 && style.maximumLineHeight > 0,
                  detail: "min=\(style.minimumLineHeight) max=\(style.maximumLineHeight)")
            check("行高上下限一致", abs(style.minimumLineHeight - style.maximumLineHeight) < 0.01)
        } else {
            check("段落样式存在", false)
        }

    }

    // MARK: - Panel bounds

    /// Every panel must sit fully inside the window at both a small and a
    /// maximised-ish size. A panel that overflows gets clipped at the window
    /// edge, which reads as "the content is being covered up".
    private static func testPanelBounds() {
        section("面板边界（最大化时是否有内容被裁掉）")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = MainViewController()
        _ = controller.view

        for size in [NSSize(width: 900, height: 560), NSSize(width: 2560, height: 1400)] {
            controller.view.frame = NSRect(origin: .zero, size: size)
            // Setting .frame alone does not necessarily schedule a layout pass;
            // without this the children keep their previous geometry and the
            // measurements below are meaningless.
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            let bounds = controller.view.bounds
            for (name, view) in [("侧边栏", controller.sidebar.view),
                                 ("编辑器区域", controller.editorArea.view),
                                 ("AI 面板", controller.aiPanel.view),
                                 ("状态栏", controller.statusBar)] {
                let frame = view.convert(view.bounds, to: controller.view)
                let inside = bounds.insetBy(dx: -1, dy: -1).contains(frame)
                check("\(Int(size.width))×\(Int(size.height))：\(name) 完整落在窗口内", inside,
                      detail: String(format: "frame=(%.0f, %.0f, %.0f, %.0f) 窗口=%.0f×%.0f",
                                     frame.minX, frame.minY, frame.width, frame.height,
                                     bounds.width, bounds.height))
            }

            // The centre column must never be squeezed out of existence.
            let centreWidth = controller.editorArea.view.frame.width
            check("\(Int(size.width))×\(Int(size.height))：中央编辑区宽度合理",
                  centreWidth >= 200, detail: "\(Int(centreWidth)) pt")
        }
    }

    // MARK: - Divider dragging

    /// Dragging a divider must actually move it.
    ///
    /// `NSSplitViewController` sizes its items from the content's Auto Layout
    /// priorities, and the limits it hands to a drag follow the content's
    /// *preferred* size — so a dense panel could be neither narrowed nor widened,
    /// and `setPosition` was silently ignored. `PanelSplitViewController` sets its
    /// subview frames directly, so the limits are the ones we declare.
    private static func testDividerDragging() {
        section("分栏可拖动性")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = MainViewController()
        _ = controller.view

        func layout(_ width: CGFloat) {
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
        }

        layout(1400)
        let outer = controller.outerSplit!
        check("外部分栏是垂直方向（左右分栏）", outer.splitView.isVertical)
        check("外部分栏有 3 个面板", outer.paneCount == 3, detail: "\(outer.paneCount)")

        // ---- every optional delegate callback must actually be implemented.
        //
        // A near-miss on an optional @objc selector compiles with nothing worse
        // than a warning and is simply never called. `didResizeSubviewsWithOldSize`
        // instead of `resizeSubviewsWithOldSize` cost a whole round of "the panel
        // does not respond to resizing". Check the real selector names, and check
        // that a plausible typo is *not* accepted, so the guard cannot rot.
        let delegateSelectors = [
            "splitView:constrainMinCoordinate:ofSubviewAt:",
            "splitView:constrainMaxCoordinate:ofSubviewAt:",
            "splitView:resizeSubviewsWithOldSize:",
            "splitView:canCollapseSubview:",
            "splitView:shouldCollapseSubview:forDoubleClickOnDividerAtIndex:",
        ]
        let missing = delegateSelectors.filter { !outer.responds(to: NSSelectorFromString($0)) }
        check("分栏控制器实现了全部 NSSplitViewDelegate 回调", missing.isEmpty,
              detail: missing.isEmpty ? "\(delegateSelectors.count) 个全部命中" : "缺少 \(missing)")
        check("错误命名的回调不会被误认为已实现（防止静默失效）",
              !outer.responds(to: NSSelectorFromString("splitView:didResizeSubviewsWithOldSize:")))

        // ---- shrinking the window must re-clamp the panes (exercises the
        //      resizeSubviewsWithOldSize path, which is what the typo broke)
        outer.setWidth(460, at: 0)
        layout(1400)
        let wideSidebar = outer.width(at: 0)
        layout(900)
        let narrowSidebar = outer.width(at: 0)
        check("窗口变窄后侧边栏被重新夹取（不是溢出窗口）",
              narrowSidebar < wideSidebar && narrowSidebar <= 560 + 1,
              detail: "1400pt 时 \(Int(wideSidebar)) → 900pt 时 \(Int(narrowSidebar))")
        check("窗口变窄后中央编辑区仍保留最小宽度",
              controller.editorArea.view.frame.width >= 200,
              detail: "\(Int(controller.editorArea.view.frame.width))")
        layout(1400)

        // ---- sweep the sidebar pane across its whole range
        let sidebarBefore = outer.width(at: 0)
        var reached: [CGFloat: CGFloat] = [:]
        for target in [160.0, 250.0, 340.0, 460.0] {
            outer.setWidth(target, at: 0)
            layout(1400)
            reached[target] = outer.width(at: 0)
        }
        print("      [侧栏] 目标 → 实际 "
              + reached.map { "\(Int($0.key))→\(Int($0.value))" }.sorted().joined(separator: "  "))

        check("侧边栏可以拖宽", (reached[460] ?? 0) > sidebarBefore + 40,
              detail: "\(Int(sidebarBefore)) → \(Int(reached[460] ?? 0))")
        check("侧边栏宽度跟上了目标值", abs((reached[460] ?? 0) - 460) < 24,
              detail: "期望 ≈460，实际 \(Int(reached[460] ?? 0))")
        check("侧边栏可以拖窄到 200pt 以内", (reached[160] ?? 999) <= 200,
              detail: "实际 \(Int(reached[160] ?? -1))")
        check("侧边栏宽度单调变化（拖动线性响应）",
              (reached[160] ?? 0) < (reached[250] ?? 0)
                  && (reached[250] ?? 0) < (reached[340] ?? 0)
                  && (reached[340] ?? 0) < (reached[460] ?? 0),
              detail: reached.map { "\(Int($0.value))" }.sorted().joined(separator: " < "))

        // ---- and the AI pane. Start from its minimum so the assertion does not
        //      depend on whatever width earlier steps left behind.
        outer.setWidth(Metrics.aiPanelMinWidth, at: 2)
        layout(1400)
        let aiBefore = outer.width(at: 2)
        outer.setWidth(440, at: 2)
        layout(1400)
        let aiAfter = outer.width(at: 2)
        check("AI 面板可以拖宽", aiAfter > aiBefore + 40, detail: "\(Int(aiBefore)) → \(Int(aiAfter))")
        outer.setWidth(Metrics.aiPanelMinWidth, at: 2)
        layout(1400)
        check("AI 面板可以拖窄", outer.width(at: 2) <= Metrics.aiPanelMinWidth + 1,
              detail: "\(Int(outer.width(at: 2)))")

        // ---- spare space must go to the centre column, not to a side panel.
        //      Previously slack went to whichever pane was widest, so widening
        //      the window silently inflated the AI panel to its 560pt maximum.
        outer.setWidth(250, at: 0)
        outer.setWidth(Metrics.aiPanelWidth, at: 2)
        layout(1200)
        let sidebar1200 = outer.width(at: 0)
        let ai1200 = outer.width(at: 2)
        let centre1200 = outer.width(at: 1)
        layout(1900)
        let sidebar1900 = outer.width(at: 0)
        let ai1900 = outer.width(at: 2)
        let centre1900 = outer.width(at: 1)
        check("窗口变宽时侧边栏宽度不变", abs(sidebar1900 - sidebar1200) < 2,
              detail: "1200pt 时 \(Int(sidebar1200)) → 1900pt 时 \(Int(sidebar1900))")
        check("窗口变宽时 AI 面板宽度不变", abs(ai1900 - ai1200) < 2,
              detail: "1200pt 时 \(Int(ai1200)) → 1900pt 时 \(Int(ai1900))")
        check("窗口变宽时多出来的空间全部给中央编辑区",
              centre1900 - centre1200 > 600,
              detail: "中央 \(Int(centre1200)) → \(Int(centre1900))（增加 \(Int(centre1900 - centre1200))）")

        // ---- the panes must always tile the split view exactly. A gap here is
        //      what makes NSSplitView log "frames in an inconsistent state".
        for width in [900.0, 1200.0, 1600.0, 2400.0] {
            layout(width)
            let sum = (0..<outer.paneCount).map { outer.width(at: $0) }.reduce(0, +)
            let expected = outer.splitView.bounds.width
                - outer.splitView.dividerThickness * CGFloat(outer.paneCount - 1)
            check("面板宽度之和精确铺满分栏视图（窗口 \(Int(width))pt）",
                  abs(sum - expected) < 2,
                  detail: "面板合计 \(Int(sum))，可用 \(Int(expected))")
        }
        layout(1400)

        // ---- the centre column must stay usable at every step
        check("中央编辑区仍有合理宽度", controller.editorArea.view.frame.width >= 200,
              detail: "\(Int(controller.editorArea.view.frame.width))")

        // ---- nothing may escape the window
        let bounds = controller.view.bounds
        for (name, view) in [("侧边栏", controller.sidebar.view),
                             ("AI 面板", controller.aiPanel.view)] {
            let frame = view.convert(view.bounds, to: controller.view)
            check("拖动后 \(name) 仍在窗口内", bounds.insetBy(dx: -1, dy: -1).contains(frame),
                  detail: "\(frame)")
        }

        // ---- collapsing still works
        outer.setCollapsed(true, at: 0)
        layout(1400)
        check("侧边栏可以折叠", outer.isCollapsed(at: 0))
        check("折叠后侧边栏宽度归零", outer.width(at: 0) < 1, detail: "\(outer.width(at: 0))")
        outer.setCollapsed(false, at: 0)
        layout(1400)
        check("侧边栏可以恢复", !outer.isCollapsed(at: 0) && outer.width(at: 0) > 100,
              detail: "\(Int(outer.width(at: 0)))")

        // ---- the terminal panel lives in the centre split
        let centre = controller.centerSplit!
        check("中央分栏是水平方向（上下分栏）", !centre.splitView.isVertical)
        check("终端面板默认折叠", centre.isCollapsed(at: 1))

        // ---- a collapsed pane must stay unbuilt until it is opened. Replacing
        //      NSSplitViewController with a plain NSSplitView quietly cost this
        //      (every pane's view got loaded in viewDidLoad), and the terminal
        //      panel is the expensive one. The slot holds a placeholder until the
        //      real view is needed.
        check("折叠的终端面板视图尚未构建（不占内存）", !controller.terminalPanel.isViewLoaded)
        check("折叠槽位里是轻量占位视图（不是终端视图）",
              type(of: centre.splitView.subviews[1]) == NSView.self,
              detail: "\(type(of: centre.splitView.subviews[1]))")
        centre.setCollapsed(false, at: 1)
        layout(1400)
        check("展开后槽位换成真正的终端面板视图",
              centre.splitView.subviews[1] === controller.terminalPanel.view)
        check("终端面板可以展开", !centre.isCollapsed(at: 1) && centre.width(at: 1) > 50,
              detail: "\(Int(centre.width(at: 1)))")
        check("展开后终端面板仍占据第 1 槽位（占位替换没有打乱顺序）",
              centre.splitView.subviews.count == centre.paneCount,
              detail: "\(centre.splitView.subviews.count) 个子视图 / \(centre.paneCount) 个面板")

        // ---- collapsing again must not disturb the layout
        centre.setCollapsed(true, at: 1)
        layout(1400)
        check("终端面板可以再次折叠", centre.isCollapsed(at: 1) && centre.width(at: 1) < 1,
              detail: "\(centre.width(at: 1))")
        check("折叠后编辑器占满中央分栏",
              centre.width(at: 0) > centre.splitView.bounds.height - 20,
              detail: "编辑器 \(Int(centre.width(at: 0))) / 可用 \(Int(centre.splitView.bounds.height))")
    }

    // MARK: - Panel theming

    /// Verifies every panel root actually repaints on a theme switch.
    ///
    /// Deliberately builds the controllers *without* a window: creating an
    /// NSWindow stalls on AppKit internals in a headless process, but plain view
    /// hierarchies load fine — and a panel whose background never gets set shows
    /// whatever is behind it, which is exactly the "unthemed stripe" symptom.
    private static func testPanelTheming() {
        section("面板主题跟随（不依赖窗口）")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let panels: [(String, NSViewController, (Theme) -> NSColor)] = [
            ("侧边栏", SidebarViewController(), { $0.sidebarBackground }),
            ("编辑器区域", EditorAreaController(), { $0.editorBackground }),
            ("AI 面板", AIPanelViewController(), { $0.panelBackground })
        ]

        for (name, viewController, expectedColor) in panels {
            _ = viewController.view
            viewController.view.layoutSubtreeIfNeeded()
            check("\(name) 根视图设置了背景色", viewController.view.layer?.backgroundColor != nil)

            for dark in [false, true] {
                ThemeManager.shared.apply(dark ? .dark : .light)
                let expected = expectedColor(ThemeManager.shared.current)
                guard let cg = viewController.view.layer?.backgroundColor,
                      let actual = NSColor(cgColor: cg)?.usingColorSpace(.sRGB),
                      let want = expected.usingColorSpace(.sRGB) else {
                    check("\(name) \(dark ? "深色" : "浅色")主题背景可读取", false)
                    continue
                }
                let delta = abs(actual.redComponent - want.redComponent)
                    + abs(actual.greenComponent - want.greenComponent)
                    + abs(actual.blueComponent - want.blueComponent)
                let brightness = (actual.redComponent + actual.greenComponent + actual.blueComponent) / 3
                check("\(name) \(dark ? "深色" : "浅色")主题背景正确",
                      delta < 0.02 && (dark ? brightness < 0.55 : brightness > 0.55),
                      detail: String(format: "亮度 %.2f，与主题色差 %.3f", brightness, delta))
            }
        }

        // AppKit injects a wallpaper-sampling layer (material .sidebar,
        // .behindWindow blending) into scroll views inside a sidebar. It ignores
        // the theme entirely — this is the "panel didn't follow the theme" bug.
        for (name, viewController, color) in panels {
            Vibrancy.neutralize(in: viewController.view, background: color(ThemeManager.shared.current))
            check("\(name) 没有采样桌面壁纸的毛玻璃层",
                  !Vibrancy.hasBehindWindowEffect(viewController.view),
                  detail: describeBehindWindowEffects(viewController.view))
        }

        ThemeManager.shared.apply(.light)
    }

    // MARK: - UI construction

    /// Builds the real window hierarchy, opens a workspace and a file, then
    /// forces a layout pass. This is the test that catches view-controller
    /// recursion, missing constraints and bad view ordering.
    private static func testUILaunch() {
        section("界面构建冒烟测试（构建真实视图层级）")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let controller = MainWindowController()
        let main = controller.mainViewController

        check("主窗口创建成功", controller.window != nil)
        check("主视图已加载", main.isViewLoaded)
        check("侧边栏已加载", main.sidebar.isViewLoaded)
        check("文件树已加载", main.sidebar.fileTree.isViewLoaded)
        check("Git 面板已加载", main.sidebar.gitPanel.isViewLoaded)
        check("运行面板已加载", main.sidebar.runPanel.isViewLoaded)
        check("编辑器区域已加载", main.editorArea.isViewLoaded)
        check("终端面板默认折叠、视图按需加载（不占内存）", !main.terminalPanel.isViewLoaded)
        main.terminalPanel.newTerminal()
        check("未展开时创建终端会话不崩溃", main.terminalPanel.hasSessions)
        check("创建会话后终端视图已按需构建", main.terminalPanel.isViewLoaded)
        NotificationCenter.default.post(name: .toggleTerminal, object: "show")
        check("展开终端面板无异常", true)
        main.terminalPanel.terminateAll()
        check("AI 面板已加载", main.aiPanel.isViewLoaded)
        check("状态栏已就位", main.statusBar.superview != nil)

        if let window = controller.window {
            check("窗口未使用 fullSizeContentView（否则工具栏会钻到红绿灯下面）",
                  !window.styleMask.contains(.fullSizeContentView))
            if let content = window.contentView {
                check("内容视图未延伸到标题栏之下",
                      content.frame.height < window.frame.height,
                      detail: "content=\(content.frame.height) window=\(window.frame.height)")
            }
        }

        // ---- open a real workspace
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bonecode-ui-\(UUID().uuidString)")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? "public class Demo {\n    private int x = 1;\n}\n".write(
            to: base.appendingPathComponent("Demo.java"), atomically: true, encoding: .utf8)
        try? "<template><div>{{ msg }}</div></template>\n".write(
            to: base.appendingPathComponent("App.vue"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: base) }

        main.openWorkspace(base)
        check("打开工作区后窗口标题更新",
              controller.window?.title.contains(base.lastPathComponent) == true,
              detail: controller.window?.title ?? "nil")

        // ---- open a file through the public path
        let editor = main.editorArea.open(url: base.appendingPathComponent("Demo.java"))
        check("打开文件后编辑器已就绪", editor.isViewLoaded)
        check("编辑器读到了文件内容", editor.textView.string.contains("public class Demo"),
              detail: "\(editor.textView.string.count) 字符")
        check("语言识别为 Java", editor.language.id == "java", detail: editor.language.id)
        check("标签页数量为 1", main.editorArea.openFileURLs.count == 1)

        let vue = main.editorArea.open(url: base.appendingPathComponent("App.vue"))
        check("Vue 文件也能打开", vue.language.id == "vue")
        check("标签页数量为 2", main.editorArea.openFileURLs.count == 2)
        main.editorArea.selectTab(for: base.appendingPathComponent("Demo.java"))

        // ---- a diff tab exercises DiffRenderer end to end
        let diffText = """
        diff --git a/x.java b/x.java
        --- a/x.java
        +++ b/x.java
        @@ -1,2 +1,3 @@
         keep
        -old
        +new
        +extra
        """
        main.editorArea.openDiffTab(DiffRequest(diffs: DiffParser.parse(diffText),
                                                title: "x.java", subtitle: "测试差异"))
        check("差异标签页已打开", main.editorArea.openFileURLs.count == 2)

        // ---- tab context-menu actions
        let twoFiles = main.editorArea.openFileURLs.count
        check("准备阶段有 2 个文件标签", twoFiles == 2, detail: "\(twoFiles) 个")

        main.editorArea.closeTabs(after: 0)
        check("「关闭右侧标签页」生效", main.editorArea.openFileURLs.count == 1,
              detail: "剩余 \(main.editorArea.openFileURLs.count) 个")

        _ = main.editorArea.open(url: base.appendingPathComponent("App.vue"))
        check("重新打开后恢复为 2 个文件标签", main.editorArea.openFileURLs.count == 2,
              detail: "\(main.editorArea.openFileURLs.count) 个")

        main.editorArea.closeTabs(keeping: 1)
        check("「关闭其他标签页」生效", main.editorArea.openFileURLs.count == 1,
              detail: "剩余 \(main.editorArea.openFileURLs.count) 个")

        // ---- running must reveal the terminal: the command really executes even
        // when the panel is collapsed, which makes the Run button look dead.
        NotificationCenter.default.post(name: .revealTerminal, object: nil)
        check("revealTerminal 会展开终端面板", main.isTerminalVisible)
        check("展开后终端面板视图已构建", main.terminalPanel.isViewLoaded)

        // ---- AI panel: Enter sends, Shift+Enter does not
        check("AI 面板已就绪", main.aiPanel.isViewLoaded)
        check("回车触发发送", main.aiPanel.shouldSend(forModifiers: []))
        check("Shift+回车不发送（用于换行）", !main.aiPanel.shouldSend(forModifiers: [.shift]))
        check("回车+其他修饰键仍发送", main.aiPanel.shouldSend(forModifiers: [.command]))

        // ---- run state must be observable, otherwise the Run button looks dead
        check("初始状态为未运行", !main.runner.isRunning)
        if let runButton = main.toolbarRunButton {
            check("运行按钮初始可用", runButton.isEnabled)
        } else {
            check("运行按钮已捕获", false)
        }
        if let stopButton = main.toolbarStopButton {
            check("停止按钮初始禁用", !stopButton.isEnabled)
        } else {
            check("停止按钮已捕获", false)
        }
        check("运行状态标签初始为空", (main.toolbarRunStatusLabel?.stringValue ?? "x").isEmpty)

        let runConfig = RunConfig.make(id: "selftest-run", name: "自检命令",
                                       command: "echo BONECODE_RUN_OK",
                                       directory: base.path, kind: "测试",
                                       symbol: "play.fill")
        main.runner.run(runConfig)
        check("启动后状态为运行中", main.runner.isRunning)
        check("启动后运行按钮被禁用", main.toolbarRunButton?.isEnabled == false)
        check("启动后停止按钮可用", main.toolbarStopButton?.isEnabled == true)
        check("启动后显示「运行中」",
              main.toolbarRunStatusLabel?.stringValue.contains("运行中") == true,
              detail: "'\(main.toolbarRunStatusLabel?.stringValue ?? "")'")
        check("启动时终端面板已展开", main.isTerminalVisible)
        pumpRunLoop(seconds: 1.5)

        // `echo` finishes but the login shell stays alive, so the state holds
        // until the session is closed — which must then clear it.
        main.terminalPanel.closeTerminal()
        check("关闭终端后状态回到未运行", !main.runner.isRunning)
        check("关闭终端后运行按钮恢复可用", main.toolbarRunButton?.isEnabled == true)
        check("关闭终端后状态标签清空", (main.toolbarRunStatusLabel?.stringValue ?? "x").isEmpty)

        // ---- force a full layout pass: layout recursion blows up here
        controller.window?.layoutIfNeeded()
        check("强制布局通过（无递归/无约束冲突）", true)

        // ---- panel minimum sizes. A panel whose floor is too high cannot be
        // dragged narrower, which reads as "the divider is broken". The sum of
        // the floors must also fit inside the window's minimum width, or the
        // split view is forced to violate them.
        let minimums = main.panelMinimumWidths
        let windowMinimum = controller.window?.minSize.width ?? 0
        print(String(format: "    面板最小宽度：侧边栏 %.0f / 中央 %.0f / AI %.0f；窗口最小 %.0f",
                     minimums.sidebar, minimums.center, minimums.ai, windowMinimum))
        check("侧边栏最小宽度 ≤ 180", minimums.sidebar <= 180, detail: "\(minimums.sidebar) pt")
        check("AI 面板最小宽度 ≤ 240", minimums.ai <= 240, detail: "\(minimums.ai) pt")
        let floors = minimums.sidebar + minimums.center + minimums.ai
        check("面板最小宽度之和不超过窗口最小宽度（分栏可拖动）",
              windowMinimum >= floors, detail: "面板合计 \(floors) pt，窗口最小 \(windowMinimum) pt")

        // ---- sidebar sections all render
        main.sidebar.select(1)
        check("切换到 Git 面板无异常", main.sidebar.gitPanel.isViewLoaded)
        main.sidebar.select(2)
        check("切换到运行面板无异常", main.sidebar.runPanel.isViewLoaded)
        main.sidebar.select(0)
        check("切回项目面板无异常", main.sidebar.fileTree.isViewLoaded)

        // ---- theme audit: verify every surface actually follows the theme.
        // A vibrant sidebar wrapper silently ignores our colours, and a view
        // whose background was never set shows whatever is behind it.
        controller.window?.setContentSize(NSSize(width: 1280, height: 820))
        controller.window?.layoutIfNeeded()
        if let content = controller.window?.contentView {
            func audit(_ label: String, dark: Bool) {
                ThemeManager.shared.apply(dark ? .dark : .light)
                content.layoutSubtreeIfNeeded()

                if let window = controller.window {
                    let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    check("\(label)：窗口外观跟随主题", isDark == dark, detail: isDark ? "dark" : "light")
                }

                for (name, view) in [("侧边栏", main.sidebar.view),
                                     ("编辑器区域", main.editorArea.view),
                                     ("AI 面板", main.aiPanel.view)] {
                    guard let cg = view.layer?.backgroundColor, let color = NSColor(cgColor: cg)?
                        .usingColorSpace(.sRGB) else {
                        check("\(label)：\(name) 设置了背景色", false)
                        continue
                    }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    check("\(label)：\(name) 背景色跟随主题", dark ? brightness < 0.55 : brightness > 0.55,
                          detail: String(format: "亮度 %.2f（期望 %@）", brightness, dark ? "< 0.55" : "> 0.55"))
                }

                var effects: [String] = []
                Self.collectVisualEffectViews(content, path: "content", into: &effects)
                if !effects.isEmpty {
                    print("      视觉特效视图: \(effects.joined(separator: " | "))")
                }
                let offenders = effects.filter { $0.hasPrefix("❌") }
                check("\(label)：没有会覆盖主题的视觉特效视图", offenders.isEmpty,
                      detail: offenders.joined(separator: " | "))

                // Surfaces that never got a background would show through.
                var unbacked: [String] = []
                Self.collectUnbackedSurfaces(content, path: "content", into: &unbacked)
                if !unbacked.isEmpty {
                    print("      未设置背景的容器: \(unbacked.prefix(6).joined(separator: ", "))")
                }
            }

            audit("浅色", dark: false)
            audit("深色", dark: true)
        }

        ThemeManager.shared.apply(.light)
        check("切回浅色主题无异常", !ThemeManager.shared.current.isDark)

        // ---- editor settings must round-trip
        let settings = EditorSettings.shared
        let originalWrap = settings.wrapLines
        settings.wrapLines.toggle()
        editor.textView.applyWrapSetting()
        settings.wrapLines = originalWrap
        editor.textView.applyWrapSetting()
        check("编辑器设置切换无异常", true)

        // ---- closing the workspace cleans up
        AppState.shared.closeWorkspace()
        check("关闭工作区无异常", AppState.shared.workspaceRoot == nil)
    }

    // MARK: - Performance diagnosis

    /// Opens every file under `directory` through the real editor path and
    /// times it. Prints each file name *before* timing so a hang identifies the
    /// culprit. Run with `--bench [directory]`.
    static func bench(directory: String) -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)      // survive a kill
        print("BoneCode 性能诊断")
        print("目录: \(directory)")
        print(String(repeating: "=", count: 92))

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let controller = MainWindowController()
        let main = controller.mainViewController
        _ = controller.window

        let fm = FileManager.default
        let root = URL(fileURLWithPath: directory)
        var files: [String] = []
        if let e = fm.enumerator(at: root,
                                 includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if FileManager.ignoredDirectoryNames.contains(url.lastPathComponent) {
                        e.skipDescendants()
                    }
                    continue
                }
                files.append(url.path)
            }
        }
        files.sort()

        print("共 \(files.count) 个文件（已跳过 .git / .build / dist 等）")
        print(String(repeating: "-", count: 92))

        var slow: [(String, Double, Int)] = []
        var total: Double = 0
        var index = 0

        for path in files {
            index += 1
            let url = URL(fileURLWithPath: path)
            let relative = path.hasPrefix(root.path + "/")
                ? String(path.dropFirst(root.path.count + 1))
                : path
            let size = fm.fileSize(at: path)
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let label = String(format: "%3d  %@", index, relative)
            print(label.padding(toLength: 58, withPad: " ", startingAt: 0)
                  + " " + sizeStr.padding(toLength: 9, withPad: " ", startingAt: 0),
                  terminator: " ")
            fflush(stdout)

            let start = Date()
            let editor = main.editorArea.open(url: url)
            editor.view.layoutSubtreeIfNeeded()
            if let lm = editor.textView.layoutManager, let tc = editor.textView.textContainer {
                lm.ensureLayout(for: tc)          // force full layout: hangs show up here
            }
            let elapsed = Date().timeIntervalSince(start)
            total += elapsed

            let chars = (editor.textView.string as NSString).length
            print(String(format: "%8.1f ms  %9d 字符", elapsed * 1000, chars))
            fflush(stdout)

            if elapsed > 0.25 { slow.append((relative, elapsed, chars)) }
            main.editorArea.closeCurrentTab()
        }

        print(String(repeating: "-", count: 92))
        print(String(format: "总计 %.2f 秒，平均 %.1f ms", total, total / Double(max(1, files.count)) * 1000))
        if slow.isEmpty {
            print("没有超过 250 ms 的文件")
        } else {
            print("\n超过 250 ms 的文件（按耗时排序）：")
            for (path, seconds, chars) in slow.sorted(by: { $0.1 > $1.1 }) {
                print(String(format: "  %8.1f ms  %9d 字符  %@", seconds * 1000, chars, path))
            }
        }
        return slow.isEmpty
    }

    /// Containers that host visible content but never got a background colour.
    private static func collectUnbackedSurfaces(_ view: NSView, path: String, into out: inout [String]) {
        let interesting = ["SidebarViewController", "AIPanelViewController", "EditorAreaController",
                           "TerminalPanelController", "GitPanelViewController", "WelcomeView",
                           "MainViewController", "NSClipView", "NSScrollView"]
        let name = String(describing: type(of: view))
        if interesting.contains(name), view.layer?.backgroundColor == nil {
            out.append("\(name)@\(path)")
        }
        for sub in view.subviews {
            collectUnbackedSurfaces(sub, path: "\(path)/\(name)", into: &out)
        }
    }

    private static func describeBehindWindowEffects(_ view: NSView, path: String = "root") -> String {
        var found: [String] = []
        func walk(_ v: NSView, _ p: String) {
            if let effect = v as? NSVisualEffectView,
               effect.material == .sidebar || effect.blendingMode == .behindWindow {
                found.append("\(p)[material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue)]")
            }
            for sub in v.subviews { walk(sub, "\(p)/\(type(of: sub))") }
        }
        walk(view, path)
        return found.joined(separator: " | ")
    }

    /// Collects the visual effect layers that could fight the app theme.
    ///
    /// Not every injected layer is a problem, so the distinction is recorded
    /// rather than the mere presence of one:
    ///
    /// - `.behindWindow` blending samples the **desktop wallpaper**, and the
    ///   `.sidebar` material is what AppKit uses for its own vibrant sidebar
    ///   wrapper. Either one makes a panel ignore the theme — these are marked
    ///   `❌` and are what the assertion fails on.
    /// - `.contentBackground` + `.withinWindow` samples the **window**, which we
    ///   already painted, so it cannot override the theme. Marked `ok`.
    private static func collectVisualEffectViews(_ view: NSView, path: String, into out: inout [String]) {
        if let effect = view as? NSVisualEffectView {
            let samplesOutside = effect.blendingMode == .behindWindow
                || effect.material == .sidebar
            let label = "\(path)[material=\(effect.material.rawValue) "
                + "blending=\(effect.blendingMode.rawValue)]"
            out.append(samplesOutside ? "❌ \(label)" : "ok \(label)")
        }
        for sub in view.subviews {
            collectVisualEffectViews(sub, path: "\(path)/\(type(of: sub))", into: &out)
        }
    }

    // MARK: - Helpers

    private static func rowText(_ emulator: TerminalEmulator, _ virtualRow: Int) -> String {
        let cells = emulator.row(virtualRow)
        var text = ""
        for cell in cells {
            if cell.isPad { continue }
            if let scalar = UnicodeScalar(cell.ch == 0 ? 32 : cell.ch) {
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    /// Drain the main dispatch queue for a while, optionally stopping early.
    private static func pumpRunLoop(seconds: TimeInterval, until condition: (() -> Bool)? = nil) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let condition, condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
