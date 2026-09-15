import AppKit

struct SearchHit {
    let path: String
    let relativePath: String
    let line: Int
    let text: String
}

final class QuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Cmd-P file switcher and Cmd-Shift-F project search, in one floating panel.
final class QuickOpenController: NSObject {

    private enum Mode {
        case files
        case search
    }

    private var panel: QuickOpenPanel?
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let activity = NSProgressIndicator()

    private var mode: Mode = .files
    private var root: URL?
    private var allFiles: [String] = []
    private var fileResults: [String] = []
    private var searchResults: [SearchHit] = []
    private var searchWorkItem: DispatchWorkItem?
    private var lastQuery = ""
    private var resignObserver: NSObjectProtocol?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged),
                                               name: .workspaceDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func workspaceChanged() {
        root = AppState.shared.workspaceRoot
        allFiles = []
        fileResults = []
    }

    @objc private func themeChanged() { applyTheme() }

    // MARK: - Panel

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let p = QuickOpenPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isMovableByWindowBackground = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        p.contentView = container

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = Fonts.ui(size: 14)
        searchField.focusRingType = .none
        searchField.delegate = self

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = Fonts.ui(size: 10.5)
        hintLabel.lineBreakMode = .byTruncatingTail

        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.style = .spinning
        activity.controlSize = .small
        activity.isDisplayedWhenStopped = false

        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.action = #selector(rowClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(hintLabel)
        container.addSubview(activity)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),

            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: activity.leadingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
            hintLabel.heightAnchor.constraint(equalToConstant: 14),

            activity.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            activity.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
            activity.widthAnchor.constraint(equalToConstant: 14),
            activity.heightAnchor.constraint(equalToConstant: 14)
        ])

        panel = p
        applyTheme()
    }

    private func applyTheme() {
        guard let panel else { return }
        let theme = ThemeManager.shared.current
        panel.contentView?.layer?.backgroundColor = theme.panelBackground.cgColor
        panel.contentView?.layer?.borderColor = theme.border.cgColor
        hintLabel.textColor = theme.tertiaryText
        searchField.textColor = theme.text
        searchField.backgroundColor = theme.editorBackground
        tableView.backgroundColor = theme.panelBackground
        tableView.reloadData()
    }

    // MARK: - Show

    func show(relativeTo window: NSWindow?) {
        mode = .files
        buildPanelIfNeeded()
        searchField.placeholderString = "输入文件名或路径（支持模糊匹配）"
        searchField.stringValue = ""
        lastQuery = ""
        present(relativeTo: window)
        if allFiles.isEmpty { loadFileList() }
        refreshFileResults(query: "")
        updateHint()
    }

    func showSearch(relativeTo window: NSWindow?) {
        mode = .search
        buildPanelIfNeeded()
        searchField.placeholderString = "在项目中搜索文本"
        searchField.stringValue = ""
        lastQuery = ""
        searchResults = []
        tableView.reloadData()
        present(relativeTo: window)
        hintLabel.stringValue = "输入关键字后自动搜索（使用 grep，支持正则）"
    }

    private func present(relativeTo window: NSWindow?) {
        guard let panel else { return }
        if let parent = window?.frame {
            let width = panel.frame.width
            let x = parent.midX - width / 2
            let y = parent.maxY - panel.frame.height - 140
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        installDismissObservers(for: panel)
    }

    /// Close as soon as focus or a click goes anywhere else.
    ///
    /// The resign-key observer handles clicks inside the app; the global monitor
    /// covers clicks on another app or the desktop, which never reach us as an
    /// event but do take key status away.
    private func installDismissObservers(for panel: NSPanel) {
        removeDismissObservers()

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let current = self.panel, event.window !== current else { return event }
            self.close()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.close()
        }
    }

    private func removeDismissObservers() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    func close() {
        removeDismissObservers()
        panel?.orderOut(nil)
        AppState.shared.mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - File list

    private func loadFileList() {
        root = AppState.shared.workspaceRoot
        guard let root else {
            allFiles = []
            return
        }
        let base = root
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String] = []
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: base,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in enumerator {
                if found.count > 30000 { break }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if FileManager.ignoredDirectoryNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let relative = url.path.hasPrefix(base.path + "/")
                    ? String(url.path.dropFirst(base.path.count + 1))
                    : url.path
                found.append(relative)
            }
            found.sort()
            DispatchQueue.main.async {
                guard let self else { return }
                self.allFiles = found
                self.refreshFileResults(query: self.searchField.stringValue)
                self.updateHint()
            }
        }
    }

    private func refreshFileResults(query: String) {
        guard mode == .files else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            fileResults = Array(allFiles.prefix(200))
        } else {
            var scored: [(String, Int)] = []
            for path in allFiles {
                if let score = Self.fuzzyScore(path, query: trimmed) {
                    scored.append((path, score))
                }
            }
            scored.sort { $0.1 > $1.1 }
            fileResults = scored.prefix(200).map { $0.0 }
        }
        tableView.reloadData()
        if !fileResults.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHint()
    }

    /// Subsequence match: every query character must appear in order.
    /// Higher scores mean a tighter, more meaningful match.
    static func fuzzyScore(_ candidate: String, query: String) -> Int? {
        let lowerCandidate = candidate.lowercased()
        let lowerQuery = query.lowercased()
        let name = (candidate as NSString).lastPathComponent.lowercased()

        var score = 0
        // Exact substring matches are much better than scattered subsequences.
        if name.hasPrefix(lowerQuery) { score += 120 }
        else if name.contains(lowerQuery) { score += 80 }
        else if lowerCandidate.contains(lowerQuery) { score += 40 }

        var index = lowerCandidate.startIndex
        var consecutive = 0
        for character in lowerQuery {
            guard let found = lowerCandidate[index...].firstIndex(of: character) else { return nil }
            if found == index { consecutive += 1 } else { consecutive = 0 }
            score += 1 + consecutive * 2
            // Bonus for matches at path boundaries.
            if found == lowerCandidate.startIndex || lowerCandidate[lowerCandidate.index(before: found)] == "/"
                || lowerCandidate[lowerCandidate.index(before: found)] == "_"
                || lowerCandidate[lowerCandidate.index(before: found)] == "." {
                score += 6
            }
            index = lowerCandidate.index(after: found)
        }
        // Prefer shorter paths when scores are close.
        score -= min(30, candidate.count / 4)
        return score
    }

    private func updateHint() {
        let theme = ThemeManager.shared.current
        _ = theme
        switch mode {
        case .files:
            hintLabel.stringValue = allFiles.isEmpty
                ? "尚未打开项目（⌘⇧O 打开文件夹）"
                : "\(fileResults.count) / \(allFiles.count) 个文件    ↑↓ 选择    ↩ 打开    esc 关闭"
        case .search:
            if searchResults.isEmpty {
                hintLabel.stringValue = "输入关键字后自动搜索"
            } else {
                hintLabel.stringValue = "\(searchResults.count) 个匹配    ↑↓ 选择    ↩ 跳转    esc 关闭"
            }
        }
    }

    // MARK: - Project search

    private func performSearch(query: String) {
        guard let root else {
            hintLabel.stringValue = "尚未打开项目"
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            searchResults = []
            tableView.reloadData()
            hintLabel.stringValue = "至少输入 2 个字符"
            return
        }
        activity.startAnimation(nil)

        searchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var args = [
                "-rn", "--binary-files=without-match", "-I",
                "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=target",
                "--exclude-dir=build", "--exclude-dir=dist", "--exclude-dir=.idea",
                "--exclude-dir=out", "--exclude-dir=.gradle", "--exclude-dir=__pycache__",
                "--exclude-dir=vendor", "--exclude-dir=.next", "--exclude-dir=coverage",
                "-E", "--", trimmed, "."
            ]
            if trimmed.count > 200 { args = [] }
            guard !args.isEmpty else { return }
            let result = ProcessRunner.run("/usr/bin/grep", args, cwd: root.path)
            var hits: [SearchHit] = []
            for line in result.stdout.split(separator: "\n") {
                if hits.count >= 500 { break }
                // ./path/to/file:123:the matched line
                guard let firstColon = line.firstIndex(of: ":") else { continue }
                let pathPart = String(line[line.startIndex..<firstColon])
                let rest = line[line.index(after: firstColon)...]
                guard let secondColon = rest.firstIndex(of: ":") else { continue }
                guard let number = Int(rest[rest.startIndex..<secondColon]) else { continue }
                let text = String(rest[rest.index(after: secondColon)...])
                let relative = pathPart.hasPrefix("./") ? String(pathPart.dropFirst(2)) : pathPart
                hits.append(SearchHit(path: root.appendingPathComponent(relative).path,
                                      relativePath: relative,
                                      line: number,
                                      text: text.trimmingCharacters(in: .whitespaces)))
            }
            DispatchQueue.main.async {
                // `self` is already unwrapped by the enclosing guard.
                self.activity.stopAnimation(nil)
                self.searchResults = hits
                self.tableView.reloadData()
                if !hits.isEmpty {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                self.updateHint()
            }
        }
        searchWorkItem = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    // MARK: - Selection

    private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0 else { close(); return }
        switch mode {
        case .files:
            guard row < fileResults.count, let root else { return }
            let url = root.appendingPathComponent(fileResults[row])
            close()
            AppState.shared.openFile(url)
        case .search:
            guard row < searchResults.count else { return }
            let hit = searchResults[row]
            close()
            let url = URL(fileURLWithPath: hit.path)
            // `open` returns nil when the file turned out to be an image and got
            // a preview tab instead of a code editor.
            if let area = AppState.shared.editorArea, let editor = area.open(url: url) {
                editor.gotoLine(hit.line)
            }
        }
    }

    @objc private func rowClicked() {
        commitSelection()
    }
}

extension QuickOpenController: NSSearchFieldDelegate, NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        switch mode {
        case .files:
            refreshFileResults(query: query)
        case .search:
            if query != lastQuery {
                lastQuery = query
                performSearch(query: query)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = mode == .files ? fileResults.count : searchResults.count
        guard count > 0 else { return }
        var row = tableView.selectedRow
        if row < 0 { row = 0 } else { row = (row + delta + count) % count }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}

extension QuickOpenController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        mode == .files ? fileResults.count : searchResults.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let theme = ThemeManager.shared.current
        let id = NSUserInterfaceItemIdentifier("QuickOpenCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let title = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.lineBreakMode = .byTruncatingMiddle
            let detail = NSTextField(labelWithString: "")
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.font = Fonts.ui(size: 10)
            detail.lineBreakMode = .byTruncatingTail
            detail.alignment = .right
            v.addSubview(title)
            v.addSubview(detail)
            v.textField = title
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
                detail.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
                detail.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                detail.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
            ])
            return v
        }()

        switch mode {
        case .files:
            guard row < fileResults.count else { return nil }
            let path = fileResults[row]
            let name = (path as NSString).lastPathComponent
            let directory = (path as NSString).deletingLastPathComponent
            cell.textField?.stringValue = name
            cell.textField?.font = Fonts.ui(size: 12.5)
            cell.textField?.textColor = theme.text
            if let detail = cell.subviews.last as? NSTextField, detail !== cell.textField {
                detail.stringValue = directory
                detail.textColor = theme.tertiaryText
            }
            cell.toolTip = path
        case .search:
            guard row < searchResults.count else { return nil }
            let hit = searchResults[row]
            let name = (hit.relativePath as NSString).lastPathComponent
            cell.textField?.stringValue = "\(name):\(hit.line)   \(hit.text.prefix(120))"
            cell.textField?.font = Fonts.ui(size: 11.5)
            cell.textField?.textColor = theme.text
            if let detail = cell.subviews.last as? NSTextField, detail !== cell.textField {
                detail.stringValue = (hit.relativePath as NSString).deletingLastPathComponent
                detail.textColor = theme.tertiaryText
            }
            cell.toolTip = "\(hit.relativePath):\(hit.line)\n\(hit.text)"
        }
        return cell
    }
}
