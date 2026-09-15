import AppKit

// MARK: - Shared helpers

private func relativeTime(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func simpleCell(_ tableView: NSTableView, id: String, text: String,
                        color: NSColor, font: NSFont, tooltip: String? = nil) -> NSTableCellView {
    let identifier = NSUserInterfaceItemIdentifier(id)
    let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? {
        let v = NSTableCellView()
        v.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        v.addSubview(label)
        v.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        return v
    }()
    cell.textField?.stringValue = text
    cell.textField?.textColor = color
    cell.textField?.font = font
    cell.toolTip = tooltip
    return cell
}

// MARK: - Changes

final class GitChangesView: NSView {

    struct Section {
        let title: String
        let isStaged: Bool
        let items: [GitFileChange]
    }

    /// Splits a change list into the three groups the panel shows.
    ///
    /// Extracted as a pure function so the grouping rules can be asserted without
    /// building a view. The rules are subtler than they look:
    ///
    /// - A file can be in **two** groups at once. `git add` then edit again gives
    ///   `MM`, and the user must see it both as staged content and as a pending
    ///   modification. An `else if` chain silently drops one of them.
    /// - Conflicts belong with the staged group, because resolving them means
    ///   staging the result.
    /// - Untracked files are their own group: they are invisible to `git diff`
    ///   and to most "what changed" views, so they need a heading of their own.
    static func group(_ changes: [GitFileChange]) -> (staged: [GitFileChange],
                                                      modified: [GitFileChange],
                                                      untracked: [GitFileChange]) {
        let staged = changes.filter { $0.hasStaged || $0.isConflicted }
        let modified = changes.filter {
            $0.hasUnstaged && !$0.isConflicted && $0.unstaged != .untracked
        }
        let untracked = changes.filter { $0.unstaged == .untracked }
        return (staged, modified, untracked)
    }

    var onNeedsRefresh: (() -> Void)?
    var onShowDiff: ((GitFileChange, Bool) -> Void)?
    var onInfo: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let messageView = NSTextView()
    private let messageScroll = NSScrollView()
    private let commitButton = NSButton()
    private let commitPushButton = NSButton()
    private let amendButton = NSButton()
    private let aiButton = NSButton()
    private let stageAllButton = NSButton()
    private let unstageAllButton = NSButton()
    private let discardButton = NSButton()
    private let stageToggleButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private var sections: [Section] = []
    private var allChanges: [GitFileChange] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 10
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.backgroundColor = ThemeManager.shared.current.panelBackground
        outlineView.style = .sourceList
        outlineView.target = self
        outlineView.action = #selector(itemClicked)
        outlineView.menu = buildContextMenu()
        outlineView.allowsMultipleSelection = true

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // commit message
        messageView.font = Fonts.ui(size: 11.5)
        messageView.isRichText = false
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.textContainerInset = NSSize(width: 5, height: 5)
        messageView.delegate = self
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageScroll.drawsBackground = true
        messageScroll.autohidesScrollers = true

        statusLabel.font = Fonts.ui(size: 10.5)
        statusLabel.lineBreakMode = .byTruncatingTail

        let bottomBar = NSStackView.horizontal(spacing: 4)
        for (button, title, symbol, action) in [
            (stageToggleButton, "暂存", "plus.square", #selector(toggleStage)),
            (stageAllButton, "全部暂存", "plus.square.on.square", #selector(stageAll)),
            (unstageAllButton, "取消全部", "minus.square", #selector(unstageAll)),
            (discardButton, "丢弃", "trash", #selector(discardSelected))
        ] as [(NSButton, String, String, Selector)] {
            button.title = title
            button.image = Icons.symbol(symbol, size: 11)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Fonts.ui(size: 10.5)
            button.target = self
            button.action = action
            // Must be able to shrink, or these two rows set a hard floor of ~285pt
            // on the whole sidebar and the divider cannot be dragged in.
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.cell?.lineBreakMode = .byTruncatingTail
            bottomBar.addArrangedSubview(button)
        }

        let commitBar = NSStackView.horizontal(spacing: 4)
        commitButton.title = "提交"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.font = Fonts.ui(size: 11, weight: .medium)
        commitButton.target = self
        commitButton.action = #selector(doCommit)
        commitButton.keyEquivalent = "\r"

        commitPushButton.title = "提交并推送"
        commitPushButton.bezelStyle = .rounded
        commitPushButton.controlSize = .small
        commitPushButton.font = Fonts.ui(size: 10.5)
        commitPushButton.target = self
        commitPushButton.action = #selector(doCommitAndPush)

        amendButton.title = "修正"
        amendButton.bezelStyle = .rounded
        amendButton.controlSize = .small
        amendButton.font = Fonts.ui(size: 10.5)
        amendButton.toolTip = "修正上一次提交（会改写历史，已推送时需强制推送）"
        amendButton.target = self
        amendButton.action = #selector(doAmend)

        aiButton.title = "AI 生成"
        aiButton.image = Icons.symbol("sparkles", size: 10)
        aiButton.imagePosition = .imageLeading
        aiButton.bezelStyle = .rounded
        aiButton.controlSize = .small
        aiButton.font = Fonts.ui(size: 10.5)
        aiButton.toolTip = "根据暂存的改动生成提交信息"
        aiButton.target = self
        aiButton.action = #selector(generateCommitMessage)

        for button in [commitButton, commitPushButton, amendButton, aiButton] {
            // Same reason as the staging row above.
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.cell?.lineBreakMode = .byTruncatingTail
            commitBar.addArrangedSubview(button)
        }

        for sub in [scrollView, messageScroll, statusLabel, bottomBar, commitBar] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bottomBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            bottomBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            bottomBar.heightAnchor.constraint(equalToConstant: 22),

            messageScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            messageScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            messageScroll.topAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: 6),
            messageScroll.heightAnchor.constraint(equalToConstant: 62),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 3),

            commitBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            commitBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            commitBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            commitBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { applyTheme(); outlineView.reloadData() }

    private func applyTheme() {
        let theme = ThemeManager.shared.current
        outlineView.backgroundColor = theme.panelBackground
        messageView.backgroundColor = theme.editorBackground
        messageView.textColor = theme.text
        messageView.insertionPointColor = theme.caretColor
        statusLabel.textColor = theme.tertiaryText
    }

    // MARK: Data

    func update(with state: GitRepoState?) {
        applyTheme()
        allChanges = state?.changes ?? []

        // Three groups, because "not yet added to Git" is a different thing from
        // "tracked but modified", and users look for them in different places.
        let (staged, modified, untracked) = Self.group(allChanges)

        var built: [Section] = []
        if !staged.isEmpty {
            built.append(Section(title: "已暂存 · 将随下次提交 (\(staged.count))",
                                 isStaged: true, items: staged))
        }
        if !modified.isEmpty {
            built.append(Section(title: "已修改 · 未暂存 (\(modified.count))",
                                 isStaged: false, items: modified))
        }
        if !untracked.isEmpty {
            built.append(Section(title: "未跟踪 · 尚未加入 Git (\(untracked.count))",
                                 isStaged: false, items: untracked))
        }
        sections = built
        outlineView.reloadData()
        for section in sections { outlineView.expandItem(section.title) }

        if let state {
            var parts: [String] = []
            if state.conflictedCount > 0 { parts.append("⚠️ \(state.conflictedCount) 个冲突待解决") }
            if state.isClean { parts.append("工作区干净") }
            if let op = state.operation { parts.append("进行中：\(op)") }
            if state.stashCount > 0 { parts.append("\(state.stashCount) 个贮藏") }
            statusLabel.stringValue = parts.joined(separator: "  ·  ")
        } else {
            statusLabel.stringValue = "未检测到 Git 仓库"
        }

        let hasStaged = !staged.isEmpty
        commitButton.isEnabled = hasStaged
        commitPushButton.isEnabled = hasStaged
        amendButton.isEnabled = true
        discardButton.isEnabled = !allChanges.isEmpty
        stageAllButton.isEnabled = !allChanges.isEmpty
        unstageAllButton.isEnabled = hasStaged
    }

    func clearMessage() { messageView.string = "" }

    // MARK: Actions

    private func selectedChanges() -> [GitFileChange] {
        var result: [GitFileChange] = []
        for row in outlineView.selectedRowIndexes {
            if let item = outlineView.item(atRow: row) as? GitFileChangeBox {
                result.append(item.change)
            }
        }
        return result
    }

    @objc private func itemClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let box = outlineView.item(atRow: row) as? GitFileChangeBox else { return }
        let staged = sections.first(where: { $0.isStaged })?.items.contains { $0.path == box.change.path } ?? false
        onShowDiff?(box.change, staged)
    }

    @objc private func toggleStage() {
        let changes = selectedChanges()
        guard !changes.isEmpty else { return }
        let toStage = changes.filter { $0.hasUnstaged }
        let toUnstage = changes.filter { $0.hasStaged && !$0.hasUnstaged }
        let group = DispatchGroup()
        if !toStage.isEmpty {
            group.enter()
            GitService.shared.stage(toStage.map { $0.path }) { _ in group.leave() }
        }
        if !toUnstage.isEmpty {
            group.enter()
            GitService.shared.unstage(toUnstage.map { $0.path }) { _ in group.leave() }
        }
        if toStage.isEmpty && toUnstage.isEmpty, let first = changes.first {
            if first.hasStaged {
                GitService.shared.unstage(changes.map { $0.path }) { _ in self.onNeedsRefresh?() }
            } else {
                GitService.shared.stage(changes.map { $0.path }) { _ in self.onNeedsRefresh?() }
            }
            return
        }
        group.notify(queue: .main) { [weak self] in self?.onNeedsRefresh?() }
    }

    @objc private func stageAll() {
        GitService.shared.stageAll { [weak self] _ in self?.onNeedsRefresh?() }
    }

    @objc private func unstageAll() {
        GitService.shared.unstageAll { [weak self] _ in self?.onNeedsRefresh?() }
    }

    @objc private func discardSelected() {
        let changes = selectedChanges()
        guard !changes.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "确定要丢弃这些改动吗？"
        alert.informativeText = changes.map { "• \($0.path)" }.joined(separator: "\n")
            + "\n\n⚠️ 此操作会覆盖工作区文件内容，未提交的修改将无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "丢弃改动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let group = DispatchGroup()
        for change in changes {
            group.enter()
            let untracked = !change.hasStaged && change.unstaged == .untracked
            GitService.shared.discard([change.path], untracked: untracked) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            self?.onInfo?("已丢弃 \(changes.count) 个文件的改动")
            self?.onNeedsRefresh?()
        }
    }

    private func performCommit(message: String, amend: Bool, push: Bool) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onError?("请先填写提交信息")
            return
        }
        GitService.shared.commit(message: trimmed, amend: amend) { [weak self] result in
            guard let self else { return }
            guard result.ok else {
                self.onError?(result.combined.trimmed)
                return
            }
            self.clearMessage()
            self.onInfo?(amend ? "已修正上一次提交" : "提交成功")
            self.onNeedsRefresh?()
            if push {
                NotificationCenter.default.post(name: .gitStatusDidChange, object: nil)
                GitService.shared.push { text in
                    self.onInfo?(text.trimmed)
                } onExit: { _ in
                    self.onNeedsRefresh?()
                }
            }
        }
    }

    @objc private func doCommit() {
        performCommit(message: messageView.string, amend: false, push: false)
    }

    @objc private func doCommitAndPush() {
        performCommit(message: messageView.string, amend: false, push: true)
    }

    @objc private func doAmend() {
        let alert = NSAlert()
        alert.messageText = "修正上一次提交？"
        alert.informativeText = "会用当前暂存区内容替换上一次提交，并更新提交信息。\n如果该提交已经推送，需要随后强制推送。"
        alert.addButton(withTitle: "修正")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performCommit(message: messageView.string, amend: true, push: false)
    }

    @objc func generateCommitMessage() {
        guard AIService.shared.isConfigured else {
            onError?("尚未配置 AI：请在「设置 → AI 助手」中填入接口地址与密钥")
            return
        }
        statusLabel.stringValue = "正在生成提交信息…"
        GitService.shared.stagedDiffForAI { [weak self] diff in
            guard let self else { return }
            let payload = diff.isEmpty ? "（暂存区为空）" : String(diff.prefix(12000))
            GitService.shared.run(["log", "-5", "--pretty=%s"]) { logResult in
                AIService.shared.generateCommitMessage(diff: payload,
                                                       recentStyle: logResult.stdout) { result in
                    switch result {
                    case .success(let message):
                        self.messageView.string = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.statusLabel.stringValue = "已生成提交信息"
                    case .failure(let error):
                        self.onError?("生成失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("暂存 / 取消暂存", #selector(toggleStage)),
            ("查看差异", #selector(viewDiff)),
            ("丢弃改动…", #selector(discardSelected)),
            ("在 Finder 中显示", #selector(revealInFinder)),
            ("复制路径", #selector(copyPath))
        ]
        for (title, sel) in items {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func viewDiff() {
        itemClicked()
    }

    @objc private func revealInFinder() {
        guard let change = selectedChanges().first, let root = GitService.shared.root else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let change = selectedChanges().first else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(change.path, forType: .string)
    }
}

/// NSOutlineView needs objects; this wraps a struct value.
final class GitFileChangeBox: NSObject {
    let change: GitFileChange
    init(_ change: GitFileChange) { self.change = change }
}

extension GitChangesView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let title = item as? String else { return sections.count }
        return sections.first { $0.title == title }?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let title = item as? String else { return sections[index].title }
        let section = sections.first { $0.title == title }
        return GitFileChangeBox(section!.items[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is String
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let theme = ThemeManager.shared.current
        if let title = item as? String {
            let cell = simpleCell(outlineView, id: "GitGroupCell", text: title,
                                  color: theme.secondaryText,
                                  font: Fonts.ui(size: 10.5, weight: .semibold))
            return cell
        }
        guard let box = item as? GitFileChangeBox else { return nil }
        let change = box.change

        let id = NSUserInterfaceItemIdentifier("GitChangeCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let status = NSTextField(labelWithString: "")
            status.translatesAutoresizingMaskIntoConstraints = false
            status.font = Fonts.code(size: 10, bold: true)
            status.alignment = .center
            // A tinted badge reads far faster than a bare coloured letter.
            status.isBezeled = false
            status.isEditable = false
            status.drawsBackground = true
            status.wantsLayer = true
            status.layer?.cornerRadius = 3
            status.layer?.borderWidth = 1
            status.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            label.font = Fonts.ui(size: 11.5)
            let dir = NSTextField(labelWithString: "")
            dir.translatesAutoresizingMaskIntoConstraints = false
            dir.font = Fonts.ui(size: 10)
            dir.lineBreakMode = .byTruncatingHead
            dir.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.addSubview(status); v.addSubview(label); v.addSubview(dir)
            v.textField = label
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                status.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                status.widthAnchor.constraint(equalToConstant: 16),
                status.heightAnchor.constraint(equalToConstant: 14),

                label.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 4),
                label.centerYAnchor.constraint(equalTo: v.centerYAnchor),

                dir.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
                dir.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4),
                dir.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }()

        let status = change.isConflicted ? GitFileStatus.conflicted
            : (change.hasStaged ? change.staged : change.unstaged)
        let statusColor = status.color(theme)

        if let badge = cell.subviews.first as? NSTextField {
            badge.stringValue = status.letter
            badge.textColor = statusColor
            badge.backgroundColor = statusColor.withAlphaComponent(0.16)
            badge.layer?.borderColor = statusColor.withAlphaComponent(0.45).cgColor
            badge.toolTip = status.badgeLabel
        }

        cell.textField?.stringValue = change.displayName
        // Colour the name too — added green, deleted red, untracked amber. That is
        // what makes the change kind readable without decoding the letter.
        switch status {
        case .added: cell.textField?.textColor = theme.gitAdded
        case .untracked: cell.textField?.textColor = theme.gitUntracked
        case .deleted: cell.textField?.textColor = theme.gitDeleted
        case .conflicted: cell.textField?.textColor = theme.gitConflicted
        default: cell.textField?.textColor = theme.text
        }
        if let dirField = cell.subviews.last as? NSTextField, dirField !== cell.textField {
            dirField.stringValue = change.directory.isEmpty ? "" : change.directory
            dirField.textColor = theme.tertiaryText
        }
        cell.toolTip = change.isConflicted
            ? "\(change.path)  ·  存在冲突，需要手动解决"
            : "\(change.path)  ·  \(status.badgeLabel)"
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is String
    }
}

extension GitChangesView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // ⌘↩ inside the message box commits.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) {
                doCommit()
                return true
            }
        }
        return false
    }
}

// MARK: - History

final class GitHistoryView: NSView, NSMenuItemValidation {

    var onNeedsRefresh: (() -> Void)?
    var onShowCommitDiff: ((GitCommit) -> Void)?
    var onShowRawDiff: (([FileDiff], String, String) -> Void)?
    var onInfo: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let graphColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("graph"))
    private let messageColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
    private let metaColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meta"))
    private var commits: [GitCommit] = []
    private var graphRows: [GraphRow] = []
    private var laneWidth: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        graphColumn.width = 90
        graphColumn.minWidth = 20
        messageColumn.width = 260
        messageColumn.minWidth = 120
        metaColumn.width = 170
        metaColumn.minWidth = 100
        tableView.addTableColumn(graphColumn)
        tableView.addTableColumn(messageColumn)
        tableView.addTableColumn(metaColumn)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = ThemeManager.shared.current.panelBackground
        tableView.style = .plain
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.menu = buildContextMenu()
        tableView.target = self
        tableView.doubleAction = #selector(showCommitDiff)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        tableView.backgroundColor = ThemeManager.shared.current.panelBackground
        tableView.reloadData()
    }

    func update(commits: [GitCommit], graphRows: [GraphRow]) {
        self.commits = commits
        self.graphRows = graphRows
        let maxLane = graphRows.map { $0.laneCount }.max() ?? 1
        graphColumn.width = min(220, CGFloat(max(2, maxLane)) * laneWidth + 12)
        tableView.reloadData()
    }

    private func selectedCommits() -> [GitCommit] {
        tableView.selectedRowIndexes.compactMap { $0 < commits.count ? commits[$0] : nil }
    }

    private func primaryCommit() -> GitCommit? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < commits.count else { return nil }
        return commits[row]
    }

    // MARK: Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("查看改动", #selector(showCommitDiff)),
            ("与工作区比较", #selector(diffAgainstWorkingTree)),
            ("从此处新建分支…", #selector(branchFromHere)),
            ("检出此提交", #selector(checkoutCommit)),
            ("挑拣到当前分支 (cherry-pick)", #selector(cherryPick)),
            ("还原此提交 (revert)", #selector(revertCommit)),
            ("标记标签…", #selector(createTagHere)),
            ("复制提交哈希", #selector(copyHash)),
            ("复制提交信息", #selector(copyMessage))
        ]
        for (title, sel) in items {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let resetMenu = NSMenu()
        for (title, mode) in [("软重置（保留改动在暂存区）", ResetMode.soft),
                              ("混合重置（保留改动在工作区）", ResetMode.mixed),
                              ("硬重置（丢弃所有改动）", ResetMode.hard)] {
            let item = NSMenuItem(title: title, action: #selector(resetToHere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            resetMenu.addItem(item)
        }
        let resetItem = NSMenuItem(title: "重置当前分支到此提交", action: nil, keyEquivalent: "")
        resetItem.submenu = resetMenu
        menu.addItem(resetItem)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cherryPick), #selector(revertCommit):
            return !selectedCommits().isEmpty
        case #selector(showCommitDiff), #selector(copyHash), #selector(copyMessage),
             #selector(checkoutCommit), #selector(branchFromHere), #selector(createTagHere),
             #selector(resetToHere(_:)), #selector(diffAgainstWorkingTree):
            return primaryCommit() != nil
        default:
            return true
        }
    }

    @objc private func showCommitDiff() {
        guard let commit = primaryCommit() else { return }
        onShowCommitDiff?(commit)
    }

    @objc private func diffAgainstWorkingTree() {
        guard let commit = primaryCommit() else { return }
        GitService.shared.diffAgainstWorkingTree(commit.hash) { [weak self] text in
            guard let self else { return }
            let diffs = DiffParser.parse(text)
            if diffs.isEmpty {
                self.onInfo?("与工作区没有差异")
                return
            }
            self.onShowRawDiff?(diffs, "与工作区比较 · \(commit.shortHash)", commit.subject)
        }
    }

    @objc private func checkoutCommit() {
        guard let commit = primaryCommit() else { return }
        let alert = NSAlert()
        alert.messageText = "检出提交 \(commit.shortHash)？"
        alert.informativeText = "会进入 detached HEAD 状态：\n\n\(commit.subject)\n\n建议改为「从此处新建分支」。"
        alert.addButton(withTitle: "检出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.checkout(commit.hash) { [weak self] result in
            if result.ok { self?.onInfo?("已检出 \(commit.shortHash)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func branchFromHere() {
        guard let commit = primaryCommit() else { return }
        guard let name = promptForText(title: "新建分支", placeholder: "分支名，例如 feature/login") else { return }
        GitService.shared.createBranch(name, at: commit.hash, checkout: true) { [weak self] result in
            if result.ok { self?.onInfo?("已从 \(commit.shortHash) 新建并切换到 \(name)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func cherryPick() {
        let selected = selectedCommits()
        guard !selected.isEmpty else { return }
        let ordered = selected.reversed().map { $0.hash }
        let alert = NSAlert()
        alert.messageText = "挑拣 \(ordered.count) 个提交到当前分支？"
        alert.informativeText = selected.reversed().map { "• \($0.shortHash)  \($0.subject)" }.joined(separator: "\n")
        alert.addButton(withTitle: "挑拣")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.cherryPick(ordered) { [weak self] result in
            if result.ok { self?.onInfo?("已挑拣 \(ordered.count) 个提交") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func revertCommit() {
        let selected = selectedCommits()
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "还原 \(selected.count) 个提交？"
        alert.informativeText = "会生成新的反向提交来抵消这些改动，不会改写历史。"
        alert.addButton(withTitle: "还原")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.revert(selected.map { $0.hash }) { [weak self] result in
            if result.ok { self?.onInfo?("已还原 \(selected.count) 个提交") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func resetToHere(_ sender: NSMenuItem) {
        guard let commit = primaryCommit(),
              let raw = sender.representedObject as? String,
              let mode = ResetMode(rawValue: raw) else { return }
        let alert = NSAlert()
        alert.messageText = "重置当前分支到 \(commit.shortHash)？"
        alert.informativeText = "\(commit.subject)\n\n模式：\(mode.displayName)"
        alert.alertStyle = mode == .hard ? .critical : .warning
        if mode == .hard {
            alert.informativeText += "\n\n⚠️ 硬重置会永久丢弃之后的提交与未提交改动。"
        }
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.reset(to: commit.hash, mode: mode) { [weak self] result in
            if result.ok { self?.onInfo?("已重置到 \(commit.shortHash)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func createTagHere() {
        guard let commit = primaryCommit() else { return }
        guard let name = promptForText(title: "新建标签", placeholder: "标签名，例如 v1.0.0") else { return }
        GitService.shared.createTag(name, at: commit.hash, message: name) { [weak self] result in
            if result.ok { self?.onInfo?("已创建标签 \(name)") }
            else { self?.onError?(result.combined.trimmed) }
        }
    }

    @objc private func copyHash() {
        guard let commit = primaryCommit() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commit.hash, forType: .string)
        onInfo?("已复制 \(commit.shortHash)")
    }

    @objc private func copyMessage() {
        guard let commit = primaryCommit() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commit.subject, forType: .string)
        onInfo?("已复制提交信息")
    }
}

extension GitHistoryView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < commits.count else { return nil }
        let commit = commits[row]
        let theme = ThemeManager.shared.current

        if tableColumn === graphColumn {
            let id = NSUserInterfaceItemIdentifier("GraphCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GraphCellView) ?? {
                let v = GraphCellView()
                v.identifier = id
                return v
            }()
            cell.row = row < graphRows.count ? graphRows[row] : nil
            cell.isSelected = tableView.selectedRowIndexes.contains(row)
            cell.laneWidth = laneWidth
            return cell
        }

        if tableColumn === messageColumn {
            let id = NSUserInterfaceItemIdentifier("MessageCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                v.identifier = id
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                v.addSubview(label)
                v.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
                ])
                return v
            }()

            let attributed = NSMutableAttributedString()
            for ref in commit.shortRefs {
                attributed.append(NSAttributedString(string: ref + " ", attributes: [
                    .font: Fonts.ui(size: 9.5, weight: .semibold),
                    .foregroundColor: theme.accent,
                    .backgroundColor: theme.accentSoft
                ]))
            }
            attributed.append(NSAttributedString(string: commit.subject, attributes: [
                .font: Fonts.ui(size: 11.5),
                .foregroundColor: theme.text
            ]))
            cell.textField?.attributedStringValue = attributed
            cell.toolTip = "\(commit.shortHash)\n\(commit.subject)\n\(commit.author) · \(commit.relativeDate)"
            return cell
        }

        let text = "\(commit.author)  ·  \(commit.relativeDate)"
        return simpleCell(tableView, id: "MetaCell", text: text,
                          color: theme.tertiaryText, font: Fonts.ui(size: 10),
                          tooltip: commit.email)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let rows = tableView.selectedRowIndexes
        for row in 0..<commits.count {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? GraphCellView {
                cell.isSelected = rows.contains(row)
            }
        }
    }
}

// MARK: - Branches

final class GitBranchesView: NSView, NSMenuItemValidation {

    var onNeedsRefresh: (() -> Void)?
    var onInfo: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var branches: [GitBranch] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branchName"))
        nameColumn.title = "分支"
        nameColumn.width = 220
        let upstreamColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branchUpstream"))
        upstreamColumn.title = "上游 / 说明"
        upstreamColumn.width = 240
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(upstreamColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = ThemeManager.shared.current.panelBackground
        tableView.style = .plain
        tableView.menu = buildContextMenu()
        tableView.target = self
        tableView.doubleAction = #selector(checkoutSelected)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        tableView.backgroundColor = ThemeManager.shared.current.panelBackground
        tableView.reloadData()
    }

    func update(_ branches: [GitBranch]) {
        self.branches = branches
        tableView.reloadData()
        if let idx = branches.firstIndex(where: { $0.isCurrent }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    private func selectedBranch() -> GitBranch? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < branches.count else { return nil }
        return branches[row]
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("检出", #selector(checkoutSelected)),
            ("合并到当前分支", #selector(mergeSelected)),
            ("变基到此处", #selector(rebaseOntoSelected)),
            ("推送此分支到 origin", #selector(pushSelected)),
            ("新建分支…", #selector(newBranch)),
            ("重命名…", #selector(renameSelected)),
            ("删除分支", #selector(deleteSelected)),
            ("复制分支名", #selector(copyBranchName))
        ]
        for (title, sel) in items {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkoutSelected), #selector(mergeSelected), #selector(rebaseOntoSelected),
             #selector(pushSelected), #selector(renameSelected), #selector(deleteSelected),
             #selector(copyBranchName):
            return selectedBranch() != nil
        default:
            return true
        }
    }

    @objc private func checkoutSelected() {
        guard let branch = selectedBranch(), !branch.isCurrent else { return }
        GitService.shared.checkout(branch.name) { [weak self] result in
            if result.ok { self?.onInfo?("已切换到 \(branch.name)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func mergeSelected() {
        guard let branch = selectedBranch() else { return }
        let alert = NSAlert()
        alert.messageText = "把 \(branch.name) 合并到当前分支？"
        alert.addButton(withTitle: "合并")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.merge(branch.name) { [weak self] result in
            if result.ok { self?.onInfo?("已合并 \(branch.name)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func rebaseOntoSelected() {
        guard let branch = selectedBranch() else { return }
        let alert = NSAlert()
        alert.messageText = "把当前分支变基到 \(branch.name)？"
        alert.informativeText = "会改写当前分支的提交历史。如果已经推送，需要强制推送。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "变基")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.rebase(onto: branch.name) { [weak self] result in
            if result.ok { self?.onInfo?("变基完成") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func pushSelected() {
        guard let branch = selectedBranch() else { return }
        let name = branch.isRemote ? branch.name.replacingOccurrences(of: "origin/", with: "", options: .anchored) : branch.name
        GitService.shared.push(forceWithLease: false, setUpstream: !branch.isRemote,
                               remote: "origin", branch: name,
                               onOutput: { [weak self] text in self?.onInfo?(text.trimmed) },
                               onExit: { [weak self] code in
            if code == 0 { self?.onInfo?("已推送 \(name)") }
            self?.onNeedsRefresh?()
        })
    }

    @objc private func newBranch() {
        guard let name = promptForText(title: "新建分支", placeholder: "分支名，例如 feature/login") else { return }
        let base = selectedBranch()?.name
        GitService.shared.createBranch(name, at: base, checkout: true) { [weak self] result in
            if result.ok { self?.onInfo?("已新建并切换到 \(name)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func renameSelected() {
        guard let branch = selectedBranch() else { return }
        guard let name = promptForText(title: "重命名分支", placeholder: "新名称", initial: branch.shortName) else { return }
        GitService.shared.renameBranch(branch.name, to: name) { [weak self] result in
            if result.ok { self?.onInfo?("已重命名为 \(name)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func deleteSelected() {
        guard let branch = selectedBranch() else { return }
        guard !branch.isCurrent else {
            onError?("不能删除当前所在的分支")
            return
        }
        let alert = NSAlert()
        alert.messageText = "删除分支 \(branch.name)？"
        alert.informativeText = "如果该分支还有未合并的提交，删除后会丢失这些提交。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.deleteBranch(branch.name, force: true) { [weak self] result in
            if result.ok { self?.onInfo?("已删除 \(branch.name)") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func copyBranchName() {
        guard let branch = selectedBranch() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(branch.name, forType: .string)
        onInfo?("已复制 \(branch.name)")
    }
}

extension GitBranchesView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { branches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < branches.count else { return nil }
        let branch = branches[row]
        let theme = ThemeManager.shared.current

        if tableColumn?.identifier.rawValue == "branchName" {
            let id = NSUserInterfaceItemIdentifier("BranchNameCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                v.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingMiddle
                v.addSubview(image); v.addSubview(label)
                v.textField = label
                v.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 13),
                    label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
                ])
                return v
            }()
            cell.imageView?.image = Icons.symbol(branch.isCurrent ? "arrow.right.circle.fill"
                                                                   : (branch.isRemote ? "cloud" : "arrow.triangle.branch"),
                                                 size: 11)
            cell.imageView?.contentTintColor = branch.isCurrent ? theme.accent : theme.secondaryText
            cell.textField?.stringValue = branch.shortName
            cell.textField?.font = Fonts.ui(size: 11.5, weight: branch.isCurrent ? .semibold : .regular)
            cell.textField?.textColor = theme.text
            cell.toolTip = branch.subject
            return cell
        }

        var detail = branch.upstream ?? ""
        if branch.isRemote { detail = "远程分支" + (detail.isEmpty ? "" : " · \(detail)") }
        else if detail.isEmpty { detail = "无上游" }
        let updated = relativeTime(branch.updated)
        if !updated.isEmpty { detail += "  ·  \(updated)" }
        return simpleCell(tableView, id: "BranchUpstreamCell", text: detail,
                          color: theme.tertiaryText, font: Fonts.ui(size: 10))
    }
}

// MARK: - Stash

final class GitStashView: NSView, NSMenuItemValidation {

    var onNeedsRefresh: (() -> Void)?
    var onInfo: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var entries: [GitStashEntry] = []
    private let saveButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stash"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = ThemeManager.shared.current.panelBackground
        tableView.style = .plain
        tableView.menu = buildContextMenu()
        tableView.target = self
        tableView.doubleAction = #selector(applySelected)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        saveButton.title = "贮藏当前改动"
        saveButton.image = Icons.symbol("tray.and.arrow.down", size: 11)
        saveButton.imagePosition = .imageLeading
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.font = Fonts.ui(size: 10.5)
        saveButton.target = self
        saveButton.action = #selector(saveStash)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(saveButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),

            saveButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            saveButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 5),
            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        tableView.backgroundColor = ThemeManager.shared.current.panelBackground
        tableView.reloadData()
    }

    func update(_ entries: [GitStashEntry]) {
        self.entries = entries
        tableView.reloadData()
    }

    private func selected() -> GitStashEntry? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("应用（保留贮藏）", #selector(applySelected)),
            ("弹出（应用后删除）", #selector(popSelected)),
            ("删除此贮藏", #selector(dropSelected))
        ]
        for (title, sel) in items {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        selected() != nil
    }

    @objc private func saveStash() {
        guard let message = promptForText(title: "贮藏改动", placeholder: "说明（可留空）", allowEmpty: true) else { return }
        GitService.shared.stashSave(message: message.isEmpty ? nil : message) { [weak self] result in
            if result.ok { self?.onInfo?("已贮藏改动") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func applySelected() {
        guard let entry = selected() else { return }
        GitService.shared.stashApply(index: entry.index, pop: false) { [weak self] result in
            if result.ok { self?.onInfo?("已应用贮藏") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func popSelected() {
        guard let entry = selected() else { return }
        GitService.shared.stashApply(index: entry.index, pop: true) { [weak self] result in
            if result.ok { self?.onInfo?("已弹出贮藏") }
            else { self?.onError?(result.combined.trimmed) }
            self?.onNeedsRefresh?()
        }
    }

    @objc private func dropSelected() {
        guard let entry = selected() else { return }
        let alert = NSAlert()
        alert.messageText = "删除这个贮藏？"
        alert.informativeText = entry.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GitService.shared.stashDrop(index: entry.index) { [weak self] _ in
            self?.onInfo?("已删除贮藏")
            self?.onNeedsRefresh?()
        }
    }
}

extension GitStashView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let theme = ThemeManager.shared.current
        let text = "stash@{\(entry.index)}  \(entry.branch)  ·  \(entry.date)"
        let cell = simpleCell(tableView, id: "StashCell", text: text,
                              color: theme.text, font: Fonts.ui(size: 11))
        cell.toolTip = entry.message
        return cell
    }
}

// MARK: - Shared prompt

func promptForText(title: String, placeholder: String, initial: String = "",
                   allowEmpty: Bool = false) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.placeholderString = placeholder
    field.stringValue = initial
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty && !allowEmpty { return nil }
    return value
}
