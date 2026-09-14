import AppKit

/// Shared, mutable app-wide state. Deliberately small: everything else is owned
/// by the view controller that uses it.
final class AppState {

    static let shared = AppState()

    private init() {}

    var workspaceRoot: URL?

    weak var mainWindow: NSWindow?
    weak var editorArea: EditorAreaController?
    weak var fileTree: FileTreeViewController?
    weak var terminalPanel: TerminalPanelController?
    weak var gitPanel: GitPanelViewController?
    weak var aiPanel: AIPanelViewController?
    weak var sidebar: SidebarViewController?
    weak var runController: ProjectRunner?

    var workspaceName: String { workspaceRoot?.lastPathComponent ?? "未打开项目" }

    // MARK: - Workspace

    func openWorkspace(_ url: URL, window: NSWindow?) {
        let standardized = url.standardizedFileURL
        workspaceRoot = standardized
        RecentProjects.shared.noteFolder(standardized)

        fileTree?.setRoot(standardized)
        GitService.shared.openRepository(at: standardized.path)
        CompletionEngine.shared.indexProject(root: standardized) { [weak self] in
            self?.postStatus("已索引 \(CompletionEngine.shared.indexedFileCount) 个文件")
        }
        runController?.refreshConfigs()

        mainWindow?.title = "\(standardized.lastPathComponent) — BoneCode"
        NotificationCenter.default.post(name: .workspaceDidChange, object: standardized)
        postStatus("已打开项目 \(standardized.lastPathComponent)")
    }

    func openFile(_ url: URL) {
        editorArea?.open(url: url)
    }

    func closeWorkspace() {
        workspaceRoot = nil
        fileTree?.setRoot(nil)
        GitService.shared.close()
        CompletionEngine.shared.invalidateIndex()
        runController?.refreshConfigs()
        mainWindow?.title = "BoneCode"
        NotificationCenter.default.post(name: .workspaceDidChange, object: nil)
    }

    func postStatus(_ message: String) {
        NotificationCenter.default.post(name: .statusMessage, object: message)
    }

    // MARK: - Context for the AI

    /// Short description of the shell environment, injected into prompts.
    func shellContext() -> String {
        var lines: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append("操作系统: macOS (\(os), \(Self.architecture))")
        let cwd = workspaceRoot?.path ?? NSHomeDirectory()
        lines.append("工作目录: \(cwd)")
        if let root = workspaceRoot {
            lines.append("项目名: \(root.lastPathComponent)")
        }
        if GitService.shared.isOpen {
            lines.append("Git 仓库: 是")
        }
        if let session = terminalPanel?.activeSession,
           let pty = session.pty, pty.isRunning {
            let recent = session.emulator.recentText(lines: 20)
            if !recent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("最近终端输出:\n\(recent)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Context for code-related questions: current file, selection, open tabs.
    func codeContext(maxChars: Int = 8000) -> String {
        var parts: [String] = []
        let root = workspaceRoot?.path ?? "（未打开项目）"
        parts.append("工作区: \(root)")

        if let editor = editorArea?.currentCodeEditor {
            parts.append("当前文件: \(editor.fileURL.path)  [语言: \(editor.language.displayName)]")
            let ns = editor.textView.string as NSString
            let selection = editor.textView.selectedRange()
            if selection.length > 0, selection.location + selection.length <= ns.length {
                let selected = ns.substring(with: selection)
                parts.append("用户选中的代码:\n```\(editor.language.id)\n\(selected.prefix(maxChars))\n```")
            } else {
                let head = ns.length > maxChars ? ns.substring(to: maxChars) + "\n…（已截断）" : editor.textView.string
                parts.append("当前文件内容:\n```\(editor.language.id)\n\(head)\n```")
            }
            parts.append("光标位置: 第 \(editor.textView.currentLineNumber) 行，第 \(editor.textView.currentColumn) 列")
        } else {
            parts.append("当前没有打开的文件。")
        }

        let others = (editorArea?.openFileURLs ?? [])
            .filter { $0.path != editorArea?.currentCodeEditor?.fileURL.path }
            .map { $0.lastPathComponent }
        if !others.isEmpty {
            parts.append("其他打开的文件: \(others.joined(separator: ", "))")
        }

        if let tree = fileTree {
            _ = tree
        }

        return parts.joined(separator: "\n\n")
    }

    /// The text the AI should operate on: selection if any, otherwise whole file.
    func editableTarget() -> (text: String, languageID: String, path: String, isSelection: Bool)? {
        guard let editor = editorArea?.currentCodeEditor else { return nil }
        let ns = editor.textView.string as NSString
        let selection = editor.textView.selectedRange()
        if selection.length > 0, selection.location + selection.length <= ns.length {
            return (ns.substring(with: selection), editor.language.id, editor.fileURL.path, true)
        }
        return (editor.textView.string, editor.language.id, editor.fileURL.path, false)
    }
}

// MARK: - Terminal history extraction

extension TerminalEmulator {
    /// The last `lines` rows rendered as plain text, used as AI context.
    func recentText(lines: Int) -> String {
        let total = totalRows
        guard total > 0 else { return "" }
        let start = max(0, total - lines)
        var out: [String] = []
        for v in start..<total {
            let cells = row(v)
            var line = ""
            for cell in cells {
                if cell.isPad { continue }
                if let scalar = UnicodeScalar(cell.ch == 0 ? 32 : cell.ch) {
                    line.unicodeScalars.append(scalar)
                }
            }
            out.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
