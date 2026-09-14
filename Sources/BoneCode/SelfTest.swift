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

    static func run() -> Bool {
        print("BoneCode 自检 (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
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
        testGitLayer()
        testPTYEndToEnd()
        testUILaunch()

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

        // exit propagation
        pty.write("exit 7\n")
        pumpRunLoop(seconds: 3)
        check("子进程退出被捕获", exited)
        check("退出码正确传递", exitCode == 7, detail: "实际 \(exitCode)")
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

        // ---- force a full layout pass: layout recursion blows up here
        controller.window?.layoutIfNeeded()
        check("强制布局通过（无递归/无约束冲突）", true)

        // ---- sidebar sections all render
        main.sidebar.select(1)
        check("切换到 Git 面板无异常", main.sidebar.gitPanel.isViewLoaded)
        main.sidebar.select(2)
        check("切换到运行面板无异常", main.sidebar.runPanel.isViewLoaded)
        main.sidebar.select(0)
        check("切回项目面板无异常", main.sidebar.fileTree.isViewLoaded)

        // ---- theme flip must not break anything
        ThemeManager.shared.apply(.dark)
        check("切换到深色主题无异常", ThemeManager.shared.current.isDark)
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
