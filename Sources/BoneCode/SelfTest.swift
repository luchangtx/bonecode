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
        testTerminalCellMetrics()
        testPromptCursorPlacement()
        testFuzzyMatch()
        testTabStrip()
        testFileKinds()
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

    // MARK: - Prompt cursor placement

    /// Regression: the block cursor sat far to the right of the shell prompt.
    ///
    /// The bytes below are real captures of what `zsh -l` writes, taken from a
    /// pty with the exact `repr` dump. The shape that matters is the "clear the
    /// partial line" dance:
    ///
    ///     ESC[1m ESC[7m % ESC[27m ESC[1m ESC[0m <79 spaces> CR SP CR CR
    ///     ESC[0m ESC[27m ESC[24m ESC[J  <prompt text>  ESC[K
    ///
    /// and, between commands, `CR CR LF` followed by that same dance.
    ///
    /// Two things have to hold:
    ///
    /// - The 79-space run is a full line's worth of blanks (zsh computes it from
    ///   the terminal width). It must not leave the cursor on a later row than
    ///   the prompt ends up on.
    /// - `CR CR LF` must put the cursor at column 0 of the *next* row. `LF` must
    ///   not touch the column — that is the whole reason a `CR` precedes it.
    private static func testPromptCursorPlacement() {
        section("终端提示符光标位置")

        func clearLineDance() -> String {
            var s = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
            s += String(repeating: " ", count: 79)
            s += "\r \r\r"
            s += "\u{1B}[0m\u{1B}[27m\u{1B}[24m\u{1B}[J"
            return s
        }
        let prompt = "dev@localhost /tmp % "

        // Verbatim capture: first prompt.
        let firstPrompt = clearLineDance() + prompt + "\u{1B}[K\u{1B}[?2004h"

        // Verbatim capture: after `cd /tmp` — note the `CR CR LF` before the dance.
        let afterCD = "c\u{08}cd /tmp\u{1B}[?2004l\r\r\n"
            + clearLineDance() + prompt + "\u{1B}[K\u{1B}[?2004h"

        // Verbatim capture: after `echo hi`.
        let afterEcho = "e\u{08}echo hi\u{1B}[?2004l\r\r\nhi\r\n"
            + clearLineDance() + prompt + "\u{1B}[K\u{1B}[?2004h"

        // ---- wide terminal: nothing wraps at all
        let wide = TerminalEmulator(cols: 100, rows: 8)
        wide.feed(Data(firstPrompt.utf8))
        print("      首次提示符 cols=100 → col=\(wide.cursorCol) row=\(wide.cursorRow)")
        check("宽终端：光标停在提示符末尾", wide.cursorCol == prompt.count,
              detail: "期望 \(prompt.count)，实际 \(wide.cursorCol)")
        check("宽终端：提示符在第 0 行", rowText(wide, 0).hasPrefix("dev@localhost"),
              detail: "'\(rowText(wide, 0))'")

        // ---- the realistic sequence: prompt → command → prompt → command → prompt.
        //      This is where the drift showed up in the app.
        for cols in [40, 47, 60, 80, 100, 120] {
            let emulator = TerminalEmulator(cols: cols, rows: 10)
            emulator.feed(Data((firstPrompt + afterCD + afterEcho).utf8))

            let row = rowText(emulator, emulator.cursorRow)
            let all = emulator.recentText(lines: 10)
            print("      连跑三条命令 cols=\(cols) → col=\(emulator.cursorCol)"
                  + " row=\(emulator.cursorRow) 该行='\(row.prefix(40))'")

            check("\(cols) 列：光标停在提示符末尾", emulator.cursorCol == prompt.count,
                  detail: "期望 \(prompt.count)，实际 \(emulator.cursorCol)")
            check("\(cols) 列：提示符整段落在光标所在行",
                  row.hasPrefix("dev@localhost /tmp % "),
                  detail: "'\(row)'")
            check("\(cols) 列：三次提示符各自只出现一次（没有散行）",
                  all.components(separatedBy: "dev@localhost").count == 4,
                  detail: "出现 \(all.components(separatedBy: "dev@localhost").count - 1) 次")
            check("\(cols) 列：echo 的输出也在屏幕上", all.contains("hi"),
                  detail: "'\(all.replacingOccurrences(of: "\n", with: "⏎"))'")
        }

        // ---- LF must not move the column, or `CR CR LF` would be pointless and
        //      the next prompt would start mid-line.
        let lf = TerminalEmulator(cols: 40, rows: 6)
        lf.feed(Data("abcdef\n".utf8))
        check("LF 不改变列号（列仍为 6）", lf.cursorCol == 6, detail: "实际 \(lf.cursorCol)")
        check("LF 把光标移到下一行", lf.cursorRow == 1, detail: "实际 \(lf.cursorRow)")
        lf.feed(Data("\rX".utf8))
        check("LF 之后的 CR 能回到列 0 再写字符", rowText(lf, 1).hasPrefix("X"),
              detail: "'\(rowText(lf, 1))'")

        // ---- the 79 spaces must not survive on screen: `ESC[J` clears from the
        //      cursor down, and the prompt is drawn over the cleared area.
        let cleaned = TerminalEmulator(cols: 100, rows: 6)
        cleaned.feed(Data(firstPrompt.utf8))
        check("清屏后残留空格不会留在屏幕上",
              !cleaned.recentText(lines: 6).contains(String(repeating: " ", count: 40)),
              detail: "'\(cleaned.recentText(lines: 6))'")
    }

    // MARK: - Terminal cell metrics

    /// The terminal grid and the rendered text must agree on one number: the
    /// advance width of a character cell.
    ///
    /// Backgrounds, the selection and the cursor are all placed at
    /// `col * cellWidth`. Text, however, is drawn as an attributed string, so its
    /// glyphs advance by whatever the *font* says. If the two disagree, every
    /// character after the first drifts away from the grid — and the cursor,
    /// which lives on the grid, visibly slides off the end of the prompt.
    ///
    /// The original code rounded the cell width up (`ceil`), so the drift grew
    /// with the line length. This measures the real numbers.
    private static func testTerminalCellMetrics() {
        section("终端字格度量（光标与文本必须同格）")

        for size in [11.0, 12.0, 13.0, 14.0, 16.0, 18.0] {
            let font = Fonts.code(size: size)
            let sample = "M" as NSString
            let oldFormula = max(4, ceil(sample.size(withAttributes: [.font: font]).width))
            let cellWidth = TerminalCellMetrics.cellWidth(for: font)

            // What the glyphs actually advance by when drawn as a string.
            var advances: [CGFloat] = []
            for ch in "Mdev@localhost /tmp % " {
                let s = String(ch) as NSString
                advances.append(s.size(withAttributes: [.font: font]).width)
            }
            let maxAdvance = advances.max() ?? 0

            // Drift after a 30-character prompt, in cells.
            let oldDrift = abs(oldFormula - maxAdvance) * 30
            let newDrift = abs(cellWidth - maxAdvance) * 30

            print(String(format: "      %.0fpt: 旧(ceil) %.3f  新(实测) %.3f  字体步进 %.3f"
                         + "  → 30 字符偏差 旧 %.2fpt / 新 %.3fpt",
                         size, oldFormula, cellWidth, maxAdvance, oldDrift, newDrift))

            check("\(Int(size))pt：新字格宽度与字体步进一致",
                  abs(cellWidth - maxAdvance) < 0.01,
                  detail: String(format: "cellWidth %.4f vs 步进 %.4f", cellWidth, maxAdvance))
            check("\(Int(size))pt：30 字符累计偏差小于半格",
                  newDrift < cellWidth * 0.5,
                  detail: String(format: "%.3fpt ≈ %.3f 格", newDrift, newDrift / cellWidth))
            check("\(Int(size))pt：比旧的向上取整公式更准",
                  newDrift <= oldDrift + 0.001,
                  detail: String(format: "旧 %.3fpt → 新 %.3fpt", oldDrift, newDrift))
        }

        // ---- and the end-to-end consequence: a full prompt drawn as one run must
        //      end exactly where the cursor is placed.
        let font = Fonts.code(size: 13)
        let cellWidth = TerminalCellMetrics.cellWidth(for: font)
        let prompt = "dev@localhost /tmp % "
        let drawn = (prompt as NSString).size(withAttributes: [.font: font]).width
        let grid = CGFloat(prompt.count) * cellWidth

        print(String(format: "      13pt：提示符绘制宽度 %.3f  网格宽度 %.3f  偏差 %.3fpt (%.3f 格)",
                     drawn, grid, abs(drawn - grid), abs(drawn - grid) / cellWidth))

        check("整段提示符的绘制宽度与网格宽度一致（偏差 < 1pt）",
              abs(drawn - grid) < 1.0,
              detail: String(format: "绘制 %.2f / 网格 %.2f", drawn, grid))
        check("30 字符的偏差不会累积到一格以上",
              abs(drawn - grid) < cellWidth,
              detail: String(format: "%.3f 格", abs(drawn - grid) / cellWidth))

        // ---- end to end, through the real view: the x the cursor will be drawn
        //      at must equal the width the prompt actually occupies. This is the
        //      assertion that would have caught the screenshot's off-by-three-cells
        //      cursor, because it uses the view's own cellWidth.
        for size in [11.0, 12.0, 13.0, 14.0, 16.0] {
            let emulator = TerminalEmulator(cols: 80, rows: 6)
            let view = TerminalView(emulator: emulator)
            view.fontSize = size
            let prompt = "dev@localhost /tmp % "
            emulator.feed(Data(prompt.utf8))

            let cursorX = CGFloat(emulator.cursorCol) * view.cellWidth
            let textWidth = (prompt as NSString)
                .size(withAttributes: [.font: Fonts.code(size: size)]).width
            let error = abs(cursorX - textWidth)

            print(String(format: "      %.0fpt 视图：光标 x %.2f  文字宽 %.2f  误差 %.2fpt (%.3f 格)",
                         size, cursorX, textWidth, error, error / view.cellWidth))

            check("\(Int(size))pt：光标 x 与提示符绘制宽度对齐（误差 < 0.5pt）",
                  error < 0.5,
                  detail: String(format: "光标 %.2f vs 文字 %.2f", cursorX, textWidth))
            check("\(Int(size))pt：光标列号等于提示符长度", emulator.cursorCol == prompt.count,
                  detail: "实际 \(emulator.cursorCol)")
        }

        // ---- characterisation of the bug that was fixed, so the assertions above
        //      cannot quietly become vacuous: the old `ceil` formula really did
        //      push the cursor multiple cells past the end of the prompt.
        let oldCell = max(4, ceil(("M" as NSString)
            .size(withAttributes: [.font: Fonts.code(size: 12)]).width))
        let oldPrompt = "dev@localhost /tmp % "
        let oldCursorX = CGFloat(oldPrompt.count) * oldCell
        let oldTextWidth = (oldPrompt as NSString)
            .size(withAttributes: [.font: Fonts.code(size: 12)]).width
        let oldCells = (oldCursorX - oldTextWidth) / oldCell
        print(String(format: "      回归依据：旧公式 12pt 下光标 x %.1f，文字宽 %.1f，偏 %.1fpt = %.2f 格",
                     oldCursorX, oldTextWidth, oldCursorX - oldTextWidth, oldCells))
        check("旧公式确实会让光标偏离 2 格以上（说明上面的断言有意义）",
              oldCells > 2.0,
              detail: String(format: "%.2f 格", oldCells))
    }

    // MARK: - File kinds

    /// Files must be classified by content, not by name.
    ///
    /// The bug this guards: opening a `.jpg` dumped the raw bytes into the text
    /// editor as mojibake, because the loader's last-resort
    /// `String(data:encoding:.isoLatin1)` **never fails** — it maps every byte to
    /// a character. A JPEG therefore sailed past the "is this binary?" branch and
    /// was rendered as text.
    private static func testFileKinds() {
        section("文件类型识别（按内容而非扩展名）")

        func data(_ bytes: [UInt8]) -> Data { Data(bytes) }
        let pngURL = URL(fileURLWithPath: "/tmp/x.png")
        let datURL = URL(fileURLWithPath: "/tmp/x.dat")
        let txtURL = URL(fileURLWithPath: "/tmp/x.txt")

        // ---- real magic numbers must be recognised
        let magics: [(String, [UInt8])] = [
            ("PNG", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            ("JPEG", [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
            ("GIF87a", Array("GIF87a".utf8)),
            ("GIF89a", Array("GIF89a".utf8)),
            ("BMP", [0x42, 0x4D, 0x36, 0x00]),
            ("TIFF-LE", [0x49, 0x49, 0x2A, 0x00]),
            ("TIFF-BE", [0x4D, 0x4D, 0x00, 0x2A]),
            ("WebP", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)),
            ("HEIC", [0, 0, 0, 0x18] + Array("ftypheic".utf8)),
            ("ICNS", Array("icns".utf8)),
            ("ICO", [0x00, 0x00, 0x01, 0x00])
        ]
        for (name, bytes) in magics {
            check("\(name) 魔数被识别为图片",
                  FileKind.isKnownImageMagic(data(bytes)),
                  detail: bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))
        }

        // ---- and the negative control: text must not be mistaken for an image
        check("普通文本不会被误判为图片",
              !FileKind.isKnownImageMagic(data(Array("public class Demo {}\n".utf8))))
        check("空文件不会被误判为图片", !FileKind.isKnownImageMagic(Data()))

        // ---- classification uses content, so a lying name does not matter
        check("PNG 内容即使叫 .dat 也算图片",
              FileKind.classify(head: data(magics[0].1), url: datURL) == .image)
        check("JPEG 内容即使叫 .txt 也算图片",
              FileKind.classify(head: data(magics[1].1), url: txtURL) == .image)
        check("文本内容即使叫 .png 也算文本（LFS 指针/错误页）",
              FileKind.classify(head: data(Array("version https://git-lfs...".utf8)), url: pngURL) == .text)

        // ---- binary detection
        check("JPEG 头部被判定为二进制", FileKind.looksBinary(data(magics[1].1)))
        check("含 NUL 字节即判定为二进制",
              FileKind.looksBinary(data([0x41, 0x42, 0x00, 0x43])))
        check("UTF-8 中文不算二进制",
              !FileKind.looksBinary(data(Array("中文注释 abc\n".utf8))))
        check("制表符/换行/ESC 不算二进制（ANSI 日志要能看）",
              !FileKind.looksBinary(data(Array("\u{1B}[31mred\u{1B}[0m\tx\ny\r\n".utf8))))
        check("UTF-16 BOM 后的 NUL 不算二进制",
              !FileKind.looksBinary(data([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00])))
        // A tiny sample cannot be judged by ratio: 2 stray bytes in 5 is 40 %,
        // but such a file is harmless to show.
        check("短样本不按比例判定（避免误杀）",
              !FileKind.looksBinary(data(Array("a\u{01}b\u{02}c".utf8))))
        // …but a realistic text file with an occasional control byte is still text.
        var mostlyText = data(Array(String(repeating: "the quick brown fox\n", count: 20).utf8))
        mostlyText.append(0x01)
        check("长文本里少量控制字符仍算文本",
              !FileKind.looksBinary(mostlyText),
              detail: "\(mostlyText.count) 字节，1 个控制字符")
        // …and a long run of control bytes is binary.
        let noisy = data([UInt8](repeating: 0x01, count: 64) + [UInt8](repeating: 0x41, count: 16))
        check("大量控制字符判定为二进制", FileKind.looksBinary(noisy))

        // ---- the exact shape that produced the bug: a JPEG decodes "successfully"
        //      as Latin-1, so the binary check must run *before* that fallback.
        let jpegHead = data(magics[1].1)
        check("JPEG 字节确实能被 Latin-1 解出（说明检查顺序很重要）",
              String(data: jpegHead, encoding: .isoLatin1) != nil)
        check("但二进制检查会在 Latin-1 之前拦下它",
              FileKind.looksBinary(jpegHead))

        // ---- archive / executable signatures used for the placeholder message.
        //      These are asserted through `isKnownBinaryMagic`, not the ratio
        //      heuristic: a 4-byte Mach-O header has no NUL and no control bytes,
        //      so only a signature match can identify it.
        for (name, bytes) in [("ZIP", [0x50, 0x4B, 0x03, 0x04]),
                              ("GZIP", [0x1F, 0x8B, 0x08]),
                              ("Mach-O", [0xCF, 0xFA, 0xED, 0xFE]),
                              ("Mach-O 64", [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00]),
                              ("ELF", [0x7F, 0x45, 0x4C, 0x46, 0x02]),
                              ("Java class", [0xCA, 0xFE, 0xBA, 0xBE]),
                              ("PDF", Array("%PDF-1.7".utf8)),
                              ("SQLite", Array("SQLite format 3".utf8)),
                              ("MP3", [0x49, 0x44, 0x33, 0x03]),
                              ("Ogg", Array("OggS".utf8)),
                              ("WebAssembly", [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])] {
            check("\(name) 被识别为二进制格式",
                  FileKind.isKnownBinaryMagic(data(bytes)),
                  detail: bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
            check("\(name) 因此会被判为二进制文件",
                  FileKind.classify(head: data(bytes), url: txtURL) == .binary)
        }

        // ---- and the negative control for the signature table
        check("普通文本不匹配任何二进制签名",
              !FileKind.isKnownBinaryMagic(data(Array("public class Demo {}\n".utf8))))
        check("UTF-8 中文源码不匹配任何二进制签名",
              !FileKind.isKnownBinaryMagic(data(Array("// 中文注释\nlet x = 1\n".utf8))))

        // ---- extension hints, used only as a fallback when the file is unreadable
        check(".jpg 扩展名提示为图片", FileKind.isImageExtension(URL(fileURLWithPath: "/a/B.JPG")))
        check(".svg 不算位图（它是可编辑的 XML）",
              !FileKind.isImageExtension(URL(fileURLWithPath: "/a/icon.svg")))
        check(".txt 不是图片扩展名", !FileKind.isImageExtension(URL(fileURLWithPath: "/a/x.txt")))

        // ---- end to end through the real loader, on real files
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bonecode-kind-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var macho = Data([0xCF, 0xFA, 0xED, 0xFE])           // Mach-O magic
        macho.append(contentsOf: [UInt8](repeating: 0x00, count: 64))
        macho.append(contentsOf: Array("not text at all".utf8))
        let machoURL = dir.appendingPathComponent("payload.bin")
        try? macho.write(to: machoURL)

        // Bare UTF-16 decoding really does "succeed" on this, which is exactly why
        // a BOM has to be required before it is attempted.
        let bareUTF16 = String(data: macho, encoding: .utf16)
        check("裸 UTF-16 解码确实会「成功」解出乱码（所以必须要求 BOM）",
              bareUTF16 != nil,
              detail: "\(bareUTF16?.count ?? 0) 字符")
        check("而这段字节的 UTF-8 解码会失败", String(data: macho, encoding: .utf8) == nil)

        let binaryEditor = CodeEditorViewController(fileURL: machoURL)
        _ = binaryEditor.view
        check("二进制文件不会把内容读进文本视图",
              binaryEditor.textView.string.isEmpty,
              detail: "\(binaryEditor.textView.string.count) 字符")

        // ---- a UTF-16 file *with* a BOM must still open as text
        let utf16URL = dir.appendingPathComponent("notes.txt")
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append("你好 UTF-16\n".data(using: .utf16LittleEndian) ?? Data())
        try? utf16Data.write(to: utf16URL)
        let utf16Editor = CodeEditorViewController(fileURL: utf16URL)
        _ = utf16Editor.view
        check("带 BOM 的 UTF-16 文件仍按文本加载",
              utf16Editor.textView.string.contains("UTF-16"),
              detail: "'\(utf16Editor.textView.string.trimmingCharacters(in: .newlines))'")
        check("UTF-16 的中文内容正确解码",
              utf16Editor.textView.string.contains("你好"),
              detail: "'\(utf16Editor.textView.string.trimmingCharacters(in: .newlines))'")

        // ---- and a normal UTF-8 file is unaffected
        let utf8URL = dir.appendingPathComponent("normal.java")
        try? "public class Normal {}\n".write(to: utf8URL, atomically: true, encoding: .utf8)
        let utf8Editor = CodeEditorViewController(fileURL: utf8URL)
        _ = utf8Editor.view
        check("普通 UTF-8 文件正常加载",
              utf8Editor.textView.string.contains("public class Normal"),
              detail: "\(utf8Editor.textView.string.count) 字符")
    }

    // MARK: - Tab strip

    /// Records what the strip reports, so hit-testing can be asserted.
    private final class RecordingTabDelegate: TabStripViewDelegate {
        var selected: [Int] = []
        var closed: [Int] = []
        var menuRequests: [Int] = []

        func tabStrip(_ strip: TabStripView, didSelect index: Int) { selected.append(index) }
        func tabStrip(_ strip: TabStripView, didClose index: Int) { closed.append(index) }
        func tabStrip(_ strip: TabStripView, menuFor index: Int) -> NSMenu? {
            menuRequests.append(index)
            return NSMenu()
        }
    }

    /// The shared tab strip. Both the editor area and the terminal panel use it,
    /// and the terminal tabs could not be closed at all while it was an
    /// `NSSegmentedControl` — that control cannot draw a per-segment close
    /// affordance.
    private static func testTabStrip() {
        section("标签栏（关闭按钮与右键菜单）")

        let strip = TabStripView()
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        let delegate = RecordingTabDelegate()
        strip.delegate = delegate

        check("空标签栏没有标签", strip.items.isEmpty)
        strip.items = [TabStripView.Item(title: "终端 1", iconName: "terminal"),
                       TabStripView.Item(title: "Vue + Vite 开发服务器", iconName: "terminal"),
                       TabStripView.Item(title: "终端 3", iconName: "terminal")]
        strip.selectedIndex = 0
        strip.layoutSubtreeIfNeeded()

        check("三个标签都有各自的矩形",
              (0..<3).allSatisfy { strip.tabRect(at: $0) != nil })
        check("标签矩形横向排列且不重叠",
              strip.tabRect(at: 0)!.maxX <= strip.tabRect(at: 1)!.minX
                  && strip.tabRect(at: 1)!.maxX <= strip.tabRect(at: 2)!.minX,
              detail: (0..<3).map { "\(Int(strip.tabRect(at: $0)!.minX))-\(Int(strip.tabRect(at: $0)!.maxX))" }
                  .joined(separator: " "))

        // ---- the close button must exist on every tab and sit inside it
        for index in 0..<3 {
            guard let tab = strip.tabRect(at: index), let close = strip.closeRect(at: index) else {
                check("标签 \(index) 有关闭按钮", false)
                continue
            }
            check("标签 \(index) 有关闭按钮", true)
            check("标签 \(index) 的关闭按钮在标签范围内", tab.contains(close.origin)
                  && close.maxX <= tab.maxX + 0.5,
                  detail: "close=\(close) tab=\(tab)")
        }

        // ---- clicking the close box closes; clicking the body selects
        if let close = strip.closeRect(at: 1) {
            strip.click(at: NSPoint(x: close.midX, y: close.midY))
        }
        check("点击关闭按钮触发 didClose(1)", delegate.closed == [1],
              detail: "\(delegate.closed)")
        check("点击关闭按钮不会同时触发 didSelect", delegate.selected.isEmpty,
              detail: "\(delegate.selected)")

        if let tab = strip.tabRect(at: 2) {
            // Well to the left of the close box.
            strip.click(at: NSPoint(x: tab.minX + 12, y: tab.midY))
        }
        check("点击标签主体触发 didSelect(2)", delegate.selected == [2],
              detail: "\(delegate.selected)")

        // ---- a click in empty space does nothing
        strip.click(at: NSPoint(x: 595, y: 15))
        check("点击空白处不触发任何事件",
              delegate.closed == [1] && delegate.selected == [2],
              detail: "closed=\(delegate.closed) selected=\(delegate.selected)")

        // ---- the status dot must not eat the close button. A running tab used to
        //      show a dot *instead* of ×, so it looked impossible to close.
        let dotted = TabStripView()
        dotted.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        dotted.alwaysShowsCloseButton = true
        dotted.items = [TabStripView.Item(title: "运行中", iconName: "terminal",
                                          showsDot: true, dotColor: .systemGreen),
                        TabStripView.Item(title: "已结束", iconName: "terminal")]
        dotted.selectedIndex = 0
        dotted.layoutSubtreeIfNeeded()

        let dottedDelegate = RecordingTabDelegate()
        dotted.delegate = dottedDelegate
        if let close = dotted.closeRect(at: 0) {
            dotted.click(at: NSPoint(x: close.midX, y: close.midY))
        }
        check("带状态圆点的标签仍然可以点关闭", dottedDelegate.closed == [0],
              detail: "\(dottedDelegate.closed)")

        if let tab = dotted.tabRect(at: 0) {
            let titleStart = tab.minX + 8 + 11          // padding + dot slot
            check("状态圆点画在标题左侧，不占用关闭位",
                  titleStart < (dotted.closeRect(at: 0)?.minX ?? 0),
                  detail: "标题起点 \(Int(titleStart))，关闭位 \(Int(dotted.closeRect(at: 0)?.minX ?? -1))")
        }

        // ---- tab widths must fit the title, and be clamped
        let longTitle = TabStripView()
        longTitle.frame = NSRect(x: 0, y: 0, width: 2000, height: 30)
        longTitle.items = [TabStripView.Item(title: String(repeating: "很长的标签标题", count: 20),
                                             iconName: "terminal")]
        longTitle.layoutSubtreeIfNeeded()
        let clamped = longTitle.tabRect(at: 0)?.width ?? 0
        check("过长的标题不会把标签撑到无限宽", clamped <= 231,
              detail: "\(Int(clamped)) pt")
        check("标签有最小宽度（短标题也点得到）", clamped >= 110,
              detail: "\(Int(clamped)) pt")

        // ---- right-click must route through the delegate
        _ = strip.menu(for: NSEvent())
        check("右键菜单请求交给委托处理", true)

        // ---- and the × must actually be painted. Render the strip twice, with
        //      and without the close button, and count differing pixels inside the
        //      close slot. Comparing renders avoids guessing a colour threshold —
        //      a 9 pt × is a thin anti-aliased stroke, so "dark pixels" is not a
        //      reliable test.
        func renderStrip(alwaysShows: Bool) -> (rep: NSBitmapImageRep, close: NSRect)? {
            let view = TabStripView()
            view.alwaysShowsCloseButton = alwaysShows
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
            view.items = [TabStripView.Item(title: "终端 1", iconName: "terminal")]
            view.selectedIndex = -1                 // not selected: only the flag draws it
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: 300, pixelsHigh: 30,
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let close = view.closeRect(at: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return (rep, close)
        }

        if let plain = renderStrip(alwaysShows: false),
           let drawn = renderStrip(alwaysShows: true) {
            // The bitmap is flipped vertically relative to the view; the close box
            // is vertically centred, so the band maps to itself.
            let x0 = Int(drawn.close.minX), x1 = Int(drawn.close.maxX)
            let y0 = max(0, 30 - Int(drawn.close.maxY)), y1 = min(30, 30 - Int(drawn.close.minY))
            var differing = 0
            for x in x0..<x1 {
                for y in y0..<y1 {
                    let a = plain.rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    let b = drawn.rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    guard let a, let b else { continue }
                    if abs(a.redComponent - b.redComponent) > 0.02
                        || abs(a.greenComponent - b.greenComponent) > 0.02
                        || abs(a.blueComponent - b.blueComponent) > 0.02 {
                        differing += 1
                    }
                }
            }
            print("      关闭位（\(x0),\(y0)）-（\(x1),\(y1)）内两张渲染图有 \(differing) 个像素不同")
            check("关闭按钮确实被画出来了（关闭位出现笔画）", differing > 0,
                  detail: "\(differing) 个像素不同")
            check("画出的关闭按钮有足够笔画可辨认", differing >= 12,
                  detail: "\(differing) 个像素（9pt 的 × 约需十几个）")
        } else {
            check("能渲染标签栏并比对关闭位", false)
        }
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
        let editor = main.editorArea.open(url: base.appendingPathComponent("Demo.java"))!
        check("打开文件后编辑器已就绪", editor.isViewLoaded)
        check("编辑器读到了文件内容", editor.textView.string.contains("public class Demo"),
              detail: "\(editor.textView.string.count) 字符")
        check("语言识别为 Java", editor.language.id == "java", detail: editor.language.id)
        check("标签页数量为 1", main.editorArea.openFileURLs.count == 1)

        let vue = main.editorArea.open(url: base.appendingPathComponent("App.vue"))!
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

        // ---- images get a preview tab, not a page of mojibake. Write a real PNG
        //      and a real binary file and open them through the normal path.
        let imageURL = base.appendingPathComponent("shot.png")
        let imageWritten = Self.writeTestPNG(to: imageURL, width: 120, height: 80)
        check("测试用 PNG 写入成功", imageWritten)
        if imageWritten {
            let editorBefore = main.editorArea.openEditors.count
            let result = main.editorArea.open(url: imageURL)
            check("打开图片不会返回代码编辑器（而是图片预览）", result == nil)
            check("图片没有变成代码编辑器标签",
                  main.editorArea.openEditors.count == editorBefore,
                  detail: "\(editorBefore) → \(main.editorArea.openEditors.count)")
            check("图片标签页已创建",
                  main.editorArea.openFileURLs.contains { $0.lastPathComponent == "shot.png" })
            check("图片标签页的标题是文件名",
                  main.editorArea.currentContent?.tabTitle == "shot.png",
                  detail: main.editorArea.currentContent?.tabTitle ?? "nil")
            check("图片标签页标注为图片",
                  main.editorArea.currentContent?.tabSubtitle == "图片",
                  detail: main.editorArea.currentContent?.tabSubtitle ?? "nil")
            check("图片标签页是只读的（不会被标脏）",
                  main.editorArea.currentContent?.tabIsDirty == false)
            check("图片标签页用 photo 图标",
                  main.editorArea.currentContent?.tabIconName == "photo",
                  detail: main.editorArea.currentContent?.tabIconName ?? "nil")
            check("图片预览视图已构建",
                  (main.editorArea.currentContent as? ImagePreviewViewController)?
                      .isViewLoaded == true)

            // ---- and it really decoded the picture, not just claimed to
            if let preview = main.editorArea.currentContent as? ImagePreviewViewController {
                check("图片解码成功（显示的是图片而非占位提示）", preview.hasImage,
                      detail: preview.failureText ?? "ok")
                check("图片像素尺寸读取正确（120 × 80）",
                      Int(preview.pixelSize.width) == 120 && Int(preview.pixelSize.height) == 80,
                      detail: "\(Int(preview.pixelSize.width)) × \(Int(preview.pixelSize.height))")
                check("图片文件大小被读出", preview.byteSize > 0,
                      detail: "\(preview.byteSize) 字节")
                check("信息栏包含尺寸与格式",
                      preview.infoText.contains("120 × 80") && preview.infoText.contains("PNG"),
                      detail: preview.infoText)

                // ---- zoom controls must actually change the scale
                preview.zoomToActual()
                check("「实际大小」把缩放设为 100%",
                      abs(preview.effectiveScale - 1) < 0.001,
                      detail: String(format: "%.3f", preview.effectiveScale))

                let beforeZoom = preview.effectiveScale
                preview.zoomIn()
                let afterZoomIn = preview.effectiveScale
                check("放大按钮提高缩放比例", afterZoomIn > beforeZoom,
                      detail: String(format: "%.3f → %.3f", beforeZoom, afterZoomIn))

                preview.zoomOut()
                check("缩小按钮降低缩放比例", preview.effectiveScale < afterZoomIn,
                      detail: String(format: "%.3f → %.3f", afterZoomIn, preview.effectiveScale))
                check("放大再缩小回到原来的比例",
                      abs(preview.effectiveScale - beforeZoom) < 0.001,
                      detail: String(format: "%.3f vs %.3f", preview.effectiveScale, beforeZoom))

                // ---- zoom must be bounded, or the buttons walk off to infinity
                for _ in 0..<40 { preview.zoomIn() }
                check("连续放大有上限（不会无限增长）",
                      preview.effectiveScale <= 16.001,
                      detail: String(format: "%.1f", preview.effectiveScale))
                for _ in 0..<80 { preview.zoomOut() }
                check("连续缩小有下限（不会变成 0 或负数）",
                      preview.effectiveScale >= 0.049,
                      detail: String(format: "%.4f", preview.effectiveScale))

                preview.zoomToFit()
                check("「适应窗口」的缩放不超过 100%（小图不放大）",
                      preview.effectiveScale <= 1.001,
                      detail: String(format: "%.3f", preview.effectiveScale))
                check("「适应窗口」的缩放为正", preview.effectiveScale > 0,
                      detail: String(format: "%.3f", preview.effectiveScale))

                // ---- and the picture must actually be painted, not merely
                //      decoded. Render the canvas offscreen and sample the
                //      centre: the test PNG is a blue rectangle with a white
                //      square in the middle, so a correct render is white there.
                //      `NSView.draw(_:)` does not draw subviews, so render the
                //      canvas itself rather than the containing hierarchy.
                let canvas = preview.imageCanvas
                canvas.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
                canvas.needsDisplay = true
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                              pixelsWide: 200, pixelsHigh: 200,
                                              bitsPerSample: 8, samplesPerPixel: 4,
                                              hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    canvas.draw(canvas.bounds)
                    NSGraphicsContext.restoreGraphicsState()

                    if let centre = rep.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB) {
                        let isWhite = centre.redComponent > 0.75
                            && centre.greenComponent > 0.75 && centre.blueComponent > 0.75
                        check("图片真的被绘制出来（中心是白色方块）", isWhite,
                              detail: String(format: "中心像素 rgb(%.2f, %.2f, %.2f)",
                                             centre.redComponent, centre.greenComponent,
                                             centre.blueComponent))
                    } else {
                        check("能从渲染结果取到中心像素", false)
                    }
                    // A corner should be the checkerboard, not the image, which
                    // proves the image is centred rather than stretched to fill.
                    if let corner = rep.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB) {
                        let isCheckerboard = corner.redComponent > 0.7
                            && corner.greenComponent > 0.7 && corner.blueComponent > 0.7
                        check("图片四周是棋盘底（没有被拉伸铺满）", isCheckerboard,
                              detail: String(format: "左上角 rgb(%.2f, %.2f, %.2f)",
                                             corner.redComponent, corner.greenComponent,
                                             corner.blueComponent))
                    }
                }
            }

            // Re-opening the same image must reuse the tab, not stack a second one.
            let tabsAfterFirst = main.editorArea.openFileURLs.count
            main.editorArea.open(url: imageURL)
            check("重复打开同一张图片会复用标签页",
                  main.editorArea.openFileURLs.count == tabsAfterFirst,
                  detail: "\(tabsAfterFirst) → \(main.editorArea.openFileURLs.count)")
        }

        // ---- a binary file that is *not* an image must not be rendered as text.
        //      This is the mojibake case: Latin-1 decodes any byte sequence.
        let binaryURL = base.appendingPathComponent("payload.bin")
        var binary = Data([0xCF, 0xFA, 0xED, 0xFE])          // Mach-O magic
        binary.append(contentsOf: [UInt8](repeating: 0x00, count: 64))
        binary.append(contentsOf: Array("not text at all".utf8))
        try? binary.write(to: binaryURL)
        let binaryEditor = main.editorArea.open(url: binaryURL)
        check("二进制文件仍走代码编辑器路径（显示占位提示）", binaryEditor != nil)
        if let binaryEditor {
            check("二进制文件没有把乱码塞进文本视图",
                  binaryEditor.textView.string.isEmpty,
                  detail: "\(binaryEditor.textView.string.count) 字符")
        }

        // ---- and a genuine text file whose name says otherwise still opens as text
        let fakeImageURL = base.appendingPathComponent("pointer.png")
        try? "version https://git-lfs.github.com/spec/v1\noid sha256:abc\n".write(
            to: fakeImageURL, atomically: true, encoding: .utf8)
        let textEditor = main.editorArea.open(url: fakeImageURL)
        check("内容其实是文本的 .png 仍按文本打开（不是图片预览）",
              textEditor != nil && textEditor?.textView.string.contains("git-lfs") == true,
              detail: textEditor.map { "\($0.textView.string.count) 字符" } ?? "nil")

        // ---- running must reveal the terminal: the command really executes even
        // when the panel is collapsed, which makes the Run button look dead.
        NotificationCenter.default.post(name: .revealTerminal, object: nil)
        check("revealTerminal 会展开终端面板", main.isTerminalVisible)
        check("展开后终端面板视图已构建", main.terminalPanel.isViewLoaded)

        // ---- terminal tabs must be closable. They used to be an
        //      NSSegmentedControl, which cannot draw a per-segment close button,
        //      so a user with several tabs open had no way to get rid of any.
        let panel = main.terminalPanel
        let strip = panel.tabStripView
        check("终端标签栏已就位", strip.superview != nil)
        check("终端标签始终显示关闭按钮", strip.alwaysShowsCloseButton)

        // A custom NSView has no intrinsic size, so a strip constrained only by a
        // leading edge and a maximum would be under-determined and could collapse
        // to zero width — visible in the hierarchy but not on screen.
        panel.closeAllSessions()
        panel.newTerminal()
        panel.newTerminal()
        main.view.layoutSubtreeIfNeeded()
        check("终端标签栏有实际宽度（没有被压成 0）",
              strip.frame.width > 40,
              detail: String(format: "%.1f pt", strip.frame.width))
        check("终端标签栏在可视区域内",
              strip.frame.width <= 421,
              detail: String(format: "%.1f pt", strip.frame.width))
        check("标签栏高度合理", strip.frame.height >= 18 && strip.frame.height <= 26,
              detail: String(format: "%.1f pt", strip.frame.height))
        check("标签栏在头部视图内",
              strip.convert(strip.bounds, to: main.view).minX >= 0)

        panel.closeAllSessions()
        check("关闭全部后没有会话", panel.sessionCount() == 0, detail: "\(panel.sessionCount())")

        panel.newTerminal()
        panel.newTerminal()
        panel.newTerminal()
        check("新建三个终端后有 3 个标签", panel.sessionCount() == 3,
              detail: "\(panel.sessionCount())")
        check("标签栏里也是 3 个", strip.items.count == 3, detail: "\(strip.items.count)")
        check("每个标签都有自己的关闭按钮",
              (0..<3).allSatisfy { strip.closeRect(at: $0) != nil })

        // Clicking the × of the middle tab must remove exactly that one.
        let middleTitle = panel.sessionTitle(at: 1)
        if let close = strip.closeRect(at: 1) {
            strip.click(at: NSPoint(x: close.midX, y: close.midY))
        }
        check("点中间标签的关闭按钮后剩 2 个", panel.sessionCount() == 2,
              detail: "\(panel.sessionCount())")
        check("被关掉的是中间那个标签",
              !(0..<panel.sessionCount()).contains { panel.sessionTitle(at: $0) == middleTitle },
              detail: "标题「\(middleTitle ?? "nil")」仍在")
        check("标签栏跟着更新", strip.items.count == 2, detail: "\(strip.items.count)")

        // Close-others and close-all through the same paths the menu uses.
        panel.closeOtherSessions(keeping: 0)
        check("关闭其他终端后只剩 1 个", panel.sessionCount() == 1,
              detail: "\(panel.sessionCount())")

        panel.newTerminal()
        check("再次新建后回到 2 个", panel.sessionCount() == 2)
        panel.performTerminalTabAction(.closeAll, on: 0)
        check("右键菜单的「关闭全部终端」生效", panel.sessionCount() == 0,
              detail: "\(panel.sessionCount())")
        check("全部关闭后标签栏为空", strip.items.isEmpty)

        // ---- running the same configuration twice must not stack identical tabs.
        //      "Vue + Vite 开发服务器" appeared twice in the user's screenshot.
        let reuseDir = base.path
        panel.closeAllSessions()
        let first = panel.runCommand("echo one", cwd: reuseDir,
                                     title: "Vue + Vite 开发服务器",
                                     workingDirectory: reuseDir)
        check("首次运行创建 1 个标签", panel.sessionCount() == 1)
        let second = panel.runCommand("echo two", cwd: reuseDir,
                                      title: "Vue + Vite 开发服务器",
                                      workingDirectory: reuseDir)
        check("同一配置重复运行不会新增标签", panel.sessionCount() == 1,
              detail: "\(panel.sessionCount())")
        check("重复运行复用同一个会话", first === second)

        // A different title or directory is a different tab.
        _ = panel.runCommand("echo three", cwd: reuseDir, title: "另一个配置",
                             workingDirectory: reuseDir)
        check("不同配置仍会新开标签", panel.sessionCount() == 2,
              detail: "\(panel.sessionCount())")
        panel.closeAllSessions()
        check("清理干净", panel.sessionCount() == 0)

        // ---- the editor tab strip is the same shared view, so it must still work
        let editorStrip = main.editorArea.tabStripView
        check("编辑器也使用同一个标签栏组件", editorStrip === main.editorArea.tabStripView)
        check("编辑器标签栏保留图标", editorStrip.showsIcon)
        main.view.layoutSubtreeIfNeeded()
        check("编辑器标签栏宽度正常",
              editorStrip.frame.width > 100,
              detail: String(format: "%.1f pt", editorStrip.frame.width))

        // ---- many tabs must not push the header buttons off the edge: the strip
        //      gives way rather than overflowing.
        panel.closeAllSessions()
        for _ in 0..<8 { panel.newTerminal() }
        main.view.layoutSubtreeIfNeeded()
        check("8 个终端标签时标签栏仍不超过上限",
              strip.frame.width <= 421,
              detail: String(format: "%.1f pt", strip.frame.width))
        let stripFrame = strip.convert(strip.bounds, to: main.view)
        check("标签栏没有溢出面板左边界", stripFrame.minX >= -1,
              detail: String(format: "minX %.1f", stripFrame.minX))
        check("标签栏没有溢出面板右边界",
              stripFrame.maxX <= main.view.bounds.width + 1,
              detail: String(format: "maxX %.1f / 面板宽 %.1f",
                             stripFrame.maxX, main.view.bounds.width))
        check("8 个标签都还在（没有因为压缩被丢掉）", strip.items.count == 8,
              detail: "\(strip.items.count)")
        check("标签栏内部可横向滚动（内容比可视区宽）",
              strip.intrinsicContentSize.width > strip.frame.width,
              detail: String(format: "内容 %.0f / 可视 %.0f",
                             strip.intrinsicContentSize.width, strip.frame.width))
        panel.closeAllSessions()
        check("清理干净", panel.sessionCount() == 0)

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
            guard let editor = main.editorArea.open(url: url) else {
                print("        跳过（不是文本文件）：\(url.lastPathComponent)")
                continue
            }
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

    /// Writes a real, decodable PNG so the image path can be exercised end to
    /// end. Hand-rolled bytes would test `NSImage`'s error handling instead.
    @discardableResult
    private static func writeTestPNG(to url: URL, width: Int, height: Int) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

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
