import AppKit

// MARK: - Status bar

final class StatusBarView: NSView {

    private let messageLabel = NSTextField(labelWithString: "就绪")
    private let projectLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for label in [messageLabel, projectLabel, branchLabel, positionLabel, languageLabel] {
            label.font = Fonts.ui(size: 10.5)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: projectLabel.leadingAnchor, constant: -10),

            languageLabel.trailingAnchor.constraint(equalTo: positionLabel.leadingAnchor, constant: -14),
            languageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            positionLabel.trailingAnchor.constraint(equalTo: branchLabel.leadingAnchor, constant: -14),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            branchLabel.trailingAnchor.constraint(equalTo: projectLabel.leadingAnchor, constant: -14),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            projectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            projectLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func applyTheme() {
        let theme = ThemeManager.shared.current
        setBackground(theme.tabBarBackground)
        messageLabel.textColor = theme.secondaryText
        projectLabel.textColor = theme.tertiaryText
        branchLabel.textColor = theme.accent
        positionLabel.textColor = theme.tertiaryText
        languageLabel.textColor = theme.tertiaryText
    }

    func setMessage(_ text: String) { messageLabel.stringValue = text }
    func setProject(_ text: String) { projectLabel.stringValue = text }
    func setBranch(_ text: String) { branchLabel.stringValue = text }
    func setPosition(_ text: String) { positionLabel.stringValue = text }
    func setLanguage(_ text: String) { languageLabel.stringValue = text }
}

// MARK: - Split view that stays inside the window

/// `NSSplitViewController` sizes its items by each item's preferred width and
/// will happily let the total exceed the window, which clips the rightmost panel
/// at the window edge — it reads as "the content is being covered up".
///
/// This clamps the divider positions on every layout pass: only when the items
/// would overflow, so normal dragging is untouched.
final class ConstrainedSplitViewController: NSSplitViewController {

    private var isClamping = false

    override func viewDidLayout() {
        super.viewDidLayout()
        clampDividers()
    }

    private func clampDividers() {
        guard !isClamping else { return }
        let split = splitView
        let items = splitViewItems
        guard items.count >= 2 else { return }

        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        guard extent > 1 else { return }

        let minimums = items.map { max($0.minimumThickness, 60) }
        guard minimums.reduce(0, +) <= extent else { return }   // impossible; let AppKit squeeze

        // Measure the current sizes from the laid-out subviews.
        var widths = split.arrangedSubviews.map {
            split.isVertical ? $0.frame.width : $0.frame.height
        }
        guard widths.count == items.count else { return }

        var overflow = widths.reduce(0, +) - extent
        guard overflow > 0.5 else { return }        // already fits

        // Shrink the widest panel that still has slack, repeatedly.
        while overflow > 0.5 {
            let candidates = widths.indices.filter { widths[$0] - minimums[$0] > 0.5 }
            guard let widest = candidates.max(by: { widths[$0] < widths[$1] }) else { break }
            let slack = widths[widest] - minimums[widest]
            let take = min(slack, overflow)
            widths[widest] -= take
            overflow -= take
        }

        isClamping = true
        var position: CGFloat = 0
        for index in 0..<(widths.count - 1) {
            position += widths[index]
            split.setPosition(position, ofDividerAt: index)
        }
        isClamping = false
    }
}

// MARK: - Main view controller

final class MainViewController: NSViewController {

    let outerSplit = ConstrainedSplitViewController()
    let centerSplit = ConstrainedSplitViewController()

    let sidebar = SidebarViewController()
    let editorArea = EditorAreaController()
    let terminalPanel = TerminalPanelController()
    let aiPanel = AIPanelViewController()
    let statusBar = StatusBarView()

    private var sidebarItem: NSSplitViewItem!
    private var aiItem: NSSplitViewItem!
    private var terminalItem: NSSplitViewItem!

    let runner = ProjectRunner()
    private let quickOpen = QuickOpenController()

    /// Retained so the run controls can be updated as the state changes.
    weak var toolbarRunButton: NSButton?
    weak var toolbarStopButton: NSButton?
    weak var toolbarRunStatusLabel: NSTextField?
    weak var toolbarTerminalButton: HoverIconButton?
    weak var toolbarAIButton: HoverIconButton?

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.windowBackground)

        // ---- center: editor above, terminal below
        centerSplit.splitView.isVertical = false
        centerSplit.splitView.dividerStyle = .thin
        let editorItem = NSSplitViewItem(viewController: editorArea)
        editorItem.minimumThickness = 120
        editorItem.canCollapse = false
        terminalItem = NSSplitViewItem(viewController: terminalPanel)
        terminalItem.minimumThickness = 90
        terminalItem.canCollapse = true
        terminalItem.isCollapsed = true
        centerSplit.addSplitViewItem(editorItem)
        centerSplit.addSplitViewItem(terminalItem)

        // ---- outer: sidebar | center | ai
        outerSplit.splitView.isVertical = true
        outerSplit.splitView.dividerStyle = .thin
        // Deliberately NOT sidebarWithViewController: — that wraps the view in a
        // vibrant NSVisualEffectView whose material follows the system appearance
        // rather than our theme, which leaves the panel looking unthemed. A plain
        // item lets us paint an opaque background we control.
        // Deliberately NOT sidebarWithViewController: — that wraps the view in a
        // vibrant NSVisualEffectView whose material follows the *system*
        // appearance rather than our theme, leaving the panel looking unthemed.
        // A plain item lets us paint an opaque background we control.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = Metrics.sidebarMinWidth
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow

        let centerItem = NSSplitViewItem(viewController: centerSplit)
        centerItem.minimumThickness = 280

        aiItem = NSSplitViewItem(viewController: aiPanel)
        aiItem.minimumThickness = Metrics.aiPanelMinWidth
        aiItem.maximumThickness = 520
        aiItem.canCollapse = true
        aiItem.holdingPriority = .defaultHigh

        outerSplit.addSplitViewItem(sidebarItem)
        outerSplit.addSplitViewItem(centerItem)
        outerSplit.addSplitViewItem(aiItem)

        let splitView = outerSplit.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Metrics.statusBarHeight)
        ])

        view = root
        wire()
        hardenPanelBackgrounds()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Give the sidebar and editor sensible initial widths.
        outerSplit.splitView.setPosition(250, ofDividerAt: 0)
        if outerSplit.splitView.arrangedSubviews.count > 2 {
            let total = view.bounds.width
            outerSplit.splitView.setPosition(max(320, total - 348), ofDividerAt: 1)
        }
        editorArea.view.window?.makeFirstResponder(nil)
    }

    // MARK: Wiring

    private func wire() {
        let state = AppState.shared
        state.editorArea = editorArea
        state.fileTree = sidebar.fileTree
        state.gitPanel = sidebar.gitPanel
        state.terminalPanel = terminalPanel
        state.aiPanel = aiPanel
        state.sidebar = sidebar
        state.runController = runner

        runner.onConfigsChanged = { [weak self] in
            self?.sidebar.runPanel.reload()
            self?.refreshToolbarRunMenu()
        }
        runner.onRunningStateChanged = { [weak self] _ in
            self?.updateRunControls()
        }
        updateRunControls()

        sidebar.gitPanel.onShowDiff = { [weak self] request in
            self?.editorArea.openDiffTab(request)
        }

        let center: NotificationCenter = .default
        center.addObserver(self, selector: #selector(handleOpenFile(_:)), name: .openFileRequested, object: nil)
        center.addObserver(self, selector: #selector(handleOpenFolder), name: .welcomeOpenFolder, object: nil)
        center.addObserver(self, selector: #selector(handleNewFile), name: .welcomeNewFile, object: nil)
        center.addObserver(self, selector: #selector(handleOpenPath(_:)), name: .welcomeOpenPath, object: nil)
        center.addObserver(self, selector: #selector(handleToggleTerminal(_:)), name: .toggleTerminal, object: nil)
        center.addObserver(self, selector: #selector(handleRevealTerminal), name: .revealTerminal, object: nil)
        center.addObserver(self, selector: #selector(handleToggleAI), name: .toggleAIPanel, object: nil)
        center.addObserver(self, selector: #selector(handleToggleSidebar), name: .toggleSidebar, object: nil)
        center.addObserver(self, selector: #selector(handleStatus(_:)), name: .statusMessage, object: nil)
        center.addObserver(self, selector: #selector(handleTheme), name: .themeDidChange, object: nil)
        center.addObserver(self, selector: #selector(handleActiveEditor), name: .activeEditorDidChange, object: nil)
        center.addObserver(self, selector: #selector(handleWorkspace), name: .workspaceDidChange, object: nil)
        center.addObserver(self, selector: #selector(handleGitStatus(_:)), name: .gitStatusDidChange, object: nil)
        center.addObserver(self, selector: #selector(handleQuickOpen), name: .quickOpenRequested, object: nil)
        center.addObserver(self, selector: #selector(handleRun), name: .runProject, object: nil)
        center.addObserver(self, selector: #selector(handleStop), name: .stopProject, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Notification handlers

    @objc private func handleOpenFile(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        editorArea.open(url: url)
        NotificationCenter.default.post(name: .workspaceDidChange, object: AppState.shared.workspaceRoot)
    }

    @objc private func handleOpenPath(_ note: Notification) {
        guard let path = note.object as? String else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.isDirectory(path) {
            openWorkspace(url)
        } else {
            editorArea.open(url: url)
        }
    }

    @objc func handleOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开项目"
        panel.message = "选择要用 BoneCode 打开的项目文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(url)
    }

    func openWorkspace(_ url: URL) {
        AppState.shared.openWorkspace(url, window: view.window)
        runner.refreshConfigs()
        sidebar.runPanel.reload()
        refreshToolbarRunMenu()
    }

    @objc private func handleNewFile() {
        guard let root = AppState.shared.workspaceRoot else {
            handleOpenFolder()
            return
        }
        guard let name = promptForText(title: "新建文件", placeholder: "文件名，例如 Hello.java") else { return }
        let target = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            AppState.shared.postStatus("同名文件已存在")
            return
        }
        do {
            try Data().write(to: target)
            sidebar.fileTree.refresh()
            editorArea.open(url: target)
        } catch {
            AppState.shared.postStatus("新建失败：\(error.localizedDescription)")
        }
    }

    @objc private func handleToggleTerminal(_ note: Notification) {
        let wantsShow = (note.object as? String) != "hide"
        if terminalItem.isCollapsed && wantsShow {
            terminalItem.animator().isCollapsed = false
            if !terminalPanel.hasSessions { terminalPanel.newTerminal() }
            terminalPanel.focusActiveTerminal()
        } else if !terminalItem.isCollapsed && (note.object as? String) != "show" {
            terminalItem.animator().isCollapsed = true
        }
        updatePanelToggleStates()
    }

    /// Expand the terminal without animation and lay it out immediately, so the
    /// session created right afterwards measures the real panel size.
    @objc private func handleRevealTerminal() {
        if terminalItem.isCollapsed {
            terminalItem.isCollapsed = false
        }
        view.layoutSubtreeIfNeeded()
        updatePanelToggleStates()
    }

    @objc private func handleToggleAI() {
        aiItem.animator().isCollapsed.toggle()
        if !aiItem.isCollapsed { aiPanel.focusInput() }
        updatePanelToggleStates()
    }

    @objc private func handleToggleSidebar() {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc private func handleStatus(_ note: Notification) {
        guard let message = note.object as? String else { return }
        statusBar.setMessage(message)
    }

    @objc private func handleTheme() {
        statusBar.applyTheme()
        refreshStatusBar()
        updateRunControls()
        hardenPanelBackgrounds()
        // Toolbar buttons live outside the controller's view hierarchy.
        for item in view.window?.toolbar?.items ?? [] {
            (item.view as? HoverIconButton)?.refreshAppearance()
        }
        view.refreshHoverButtons()
    }

    /// Re-assert an opaque background on every panel root. Belt and braces: the
    /// controllers each react to the theme too, but a single missed surface shows
    /// up as an unthemed stripe.
    private func hardenPanelBackgrounds() {
        let theme = ThemeManager.shared.current
        var surfaces: [(NSView, NSColor)] = [
            (sidebar.view, theme.sidebarBackground),
            (editorArea.view, theme.editorBackground),
            (aiPanel.view, theme.panelBackground)
        ]
        // Only touch the terminal panel when its view already exists. The panel
        // starts collapsed, and forcing a collapsed item's view to load from
        // inside another controller's loadView deadlocks.
        if terminalPanel.isViewLoaded {
            surfaces.append((terminalPanel.view, theme.terminalBackground))
        }
        for (view, color) in surfaces {
            view.wantsLayer = true
            view.layer?.backgroundColor = color.cgColor
            // Strip AppKit's wallpaper-sampling sidebar material, or the panel
            // ignores the theme no matter what colour we set.
            Vibrancy.neutralize(in: view, background: color)
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.windowBackground.cgColor
        view.needsDisplay = true
    }

    @objc private func handleActiveEditor() {
        refreshStatusBar()
    }

    @objc private func handleWorkspace() {
        refreshStatusBar()
    }

    @objc private func handleGitStatus(_ note: Notification) {
        guard let state = note.object as? GitRepoState else {
            statusBar.setBranch("")
            return
        }
        var text = state.branch
        if state.ahead > 0 { text += " ↑\(state.ahead)" }
        if state.behind > 0 { text += " ↓\(state.behind)" }
        statusBar.setBranch(text)
    }

    @objc private func handleQuickOpen() {
        quickOpen.show(relativeTo: view.window)
    }

    @objc private func handleRun() {
        runner.runDefault()
    }

    @objc private func handleStop() {
        runner.stop()
    }

    func refreshStatusBar() {
        statusBar.setProject(AppState.shared.workspaceRoot?.lastPathComponent ?? "未打开项目")
        if let editor = editorArea.currentCodeEditor {
            statusBar.setLanguage(editor.language.displayName)
            statusBar.setPosition("第 \(editor.textView.currentLineNumber) 行，第 \(editor.textView.currentColumn) 列")
        } else {
            statusBar.setLanguage("")
            statusBar.setPosition("")
        }
    }

    /// Reflect the running state on the run controls. Without this the Run
    /// button looks identical whether or not something is running.
    func updateRunControls() {
        let theme = ThemeManager.shared.current
        let running = runner.isRunning

        if let run = toolbarRunButton {
            run.isEnabled = !running
            run.contentTintColor = running ? theme.tertiaryText : theme.diffAddedText
            run.toolTip = running ? "正在运行中" : "运行 (⌘R)"
        }
        if let stop = toolbarStopButton {
            stop.isEnabled = running
            stop.contentTintColor = running ? theme.diffRemovedText : theme.tertiaryText
        }
        toolbarRunStatusLabel?.stringValue = running ? "● 运行中" : ""
        toolbarRunStatusLabel?.textColor = theme.diffAddedText
        updatePanelToggleStates()
    }

    /// Show which side panels are currently open, so the toolbar toggles read as
    /// state rather than as plain buttons.
    func updatePanelToggleStates() {
        toolbarTerminalButton?.isActive = isTerminalVisible
        toolbarAIButton?.isActive = !aiItem.isCollapsed
    }

    func refreshToolbarRunMenu() {
        guard let toolbar = view.window?.toolbar else { return }
        for item in toolbar.items where item.itemIdentifier.rawValue == "runConfig" {
            if let popup = item.view as? NSPopUpButton {
                popup.removeAllItems()
                let configs = runner.configs
                if configs.isEmpty {
                    popup.addItem(withTitle: "无可运行配置")
                } else {
                    for config in configs { popup.addItem(withTitle: config.name) }
                }
                popup.isEnabled = !configs.isEmpty
            }
        }
    }

    func saveAll() { editorArea.saveAll() }

    /// Whether the terminal panel is currently expanded.
    var isTerminalVisible: Bool { !terminalItem.isCollapsed }

    /// Minimum widths the split view items enforce. Exposed so the self-test can
    /// assert the dividers remain draggable.
    var panelMinimumWidths: (sidebar: CGFloat, center: CGFloat, ai: CGFloat) {
        (sidebarItem.minimumThickness, 280, aiItem.minimumThickness)
    }

    func handleNewFileAction() { handleNewFile() }
}

// MARK: - Window controller

final class MainWindowController: NSWindowController, NSToolbarDelegate {

    let mainViewController = MainViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 880),
            // No .fullSizeContentView: the content view would extend under the
            // title bar and the toolbar's leading items would end up beneath the
            // close/minimise/zoom buttons.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BoneCode"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        // Must not exceed the sum of the split view item minimums, or the split
        // view is forced to violate them and the dividers stop responding.
        window.minSize = NSSize(width: 820, height: 520)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("BoneCodeMainWindow")
        window.center()

        self.init(window: window)
        window.contentViewController = mainViewController
        window.delegate = self

        let toolbar = NSToolbar(identifier: "BoneCodeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        AppState.shared.mainWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
        applyTheme()
        mainViewController.updateRunControls()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { applyTheme() }

    private func applyTheme() {
        let theme = ThemeManager.shared.current
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.windowBackground
        window?.invalidateShadow()
    }

    // MARK: Toolbar

    private enum ItemID {
        static let openFolder = NSToolbarItem.Identifier("openFolder")
        static let save = NSToolbarItem.Identifier("save")
        static let runConfig = NSToolbarItem.Identifier("runConfig")
        static let run = NSToolbarItem.Identifier("run")
        static let stop = NSToolbarItem.Identifier("stop")
        static let runStatus = NSToolbarItem.Identifier("runStatus")
        static let gitPull = NSToolbarItem.Identifier("gitPull")
        static let gitPush = NSToolbarItem.Identifier("gitPush")
        static let terminal = NSToolbarItem.Identifier("terminal")
        static let ai = NSToolbarItem.Identifier("ai")
        static let quickOpen = NSToolbarItem.Identifier("quickOpen")
        static let search = NSToolbarItem.Identifier("search")
        static let theme = NSToolbarItem.Identifier("theme")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.openFolder, ItemID.save, .flexibleSpace,
         ItemID.runConfig, ItemID.run, ItemID.stop, ItemID.runStatus, .flexibleSpace,
         ItemID.gitPull, ItemID.gitPush, .flexibleSpace,
         ItemID.quickOpen, ItemID.search, .flexibleSpace,
         ItemID.terminal, ItemID.ai, ItemID.theme]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let vc = mainViewController

        func button(_ symbol: String, _ tooltip: String, _ action: Selector,
                    tint: NSColor? = nil, capture: ((HoverIconButton) -> Void)? = nil) {
            let b = HoverIconButton(symbol: symbol, tooltip: tooltip,
                                    target: vc, action: action, tint: tint)
            item.view = b
            capture?(b)
        }

        switch itemIdentifier {
        case ItemID.openFolder:
            item.label = "打开项目"
            button("folder", "打开项目文件夹 (⌘⇧O)", #selector(MainViewController.handleOpenFolder))
        case ItemID.save:
            item.label = "保存"
            button("square.and.arrow.down", "保存当前文件 (⌘S)", #selector(MainViewController.saveCurrentFile))
        case ItemID.runConfig:
            item.label = "运行配置"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 22), pullsDown: false)
            popup.bezelStyle = .rounded
            popup.controlSize = .small
            popup.font = Fonts.ui(size: 11)
            popup.target = vc
            popup.action = #selector(MainViewController.runSelectedConfig(_:))
            for config in vc.runner.configs { popup.addItem(withTitle: config.name) }
            if vc.runner.configs.isEmpty { popup.addItem(withTitle: "无可运行配置") }
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
            item.view = popup
        case ItemID.run:
            item.label = "运行"
            button("play.fill", "运行 (⌘R)", #selector(MainViewController.runDefaultConfig),
                   tint: ThemeManager.shared.current.diffAddedText) { [weak vc] b in
                vc?.toolbarRunButton = b
            }
        case ItemID.stop:
            item.label = "停止"
            button("stop.fill", "停止 (⌘.)", #selector(MainViewController.stopRunning),
                   tint: ThemeManager.shared.current.diffRemovedText) { [weak vc] b in
                vc?.toolbarStopButton = b
            }
        case ItemID.runStatus:
            item.label = "运行状态"
            let label = NSTextField(labelWithString: "")
            label.font = Fonts.ui(size: 11, weight: .medium)
            label.textColor = ThemeManager.shared.current.diffAddedText
            label.translatesAutoresizingMaskIntoConstraints = false
            item.view = label
            vc.toolbarRunStatusLabel = label
        case ItemID.gitPull:
            item.label = "拉取"
            button("arrow.down.to.line", "拉取 (git pull)", #selector(MainViewController.gitPull))
        case ItemID.gitPush:
            item.label = "推送"
            button("arrow.up.to.line", "推送 (git push)", #selector(MainViewController.gitPush))
        case ItemID.quickOpen:
            item.label = "快速打开"
            button("doc.text.magnifyingglass", "快速打开文件 (⌘P)", #selector(MainViewController.showQuickOpen))
        case ItemID.search:
            item.label = "全局搜索"
            button("magnifyingglass", "在项目中搜索 (⌘⇧F)", #selector(MainViewController.showProjectSearch))
        case ItemID.terminal:
            item.label = "终端"
            button("terminal", "切换终端 (⌘`)", #selector(MainViewController.toggleTerminalAction)) { [weak vc] b in
                vc?.toolbarTerminalButton = b
            }
        case ItemID.ai:
            item.label = "AI 助手"
            button("sparkles", "AI 助手 (⌘⇧A)", #selector(MainViewController.toggleAIAction),
                   tint: ThemeManager.shared.current.accent) { [weak vc] b in
                vc?.toolbarAIButton = b
            }
        case ItemID.theme:
            item.label = "主题"
            button("circle.lefthalf.filled", "切换浅色/深色主题", #selector(MainViewController.toggleTheme))
        default:
            return nil
        }
        return item
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mainViewController.editorArea.promptSaveAllIfNeeded() else { return false }
        mainViewController.terminalPanel.terminateAll()
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Actions reachable from the toolbar and menus

extension MainViewController {

    @objc func saveCurrentFile() {
        editorArea.saveCurrent()
        AppState.shared.postStatus("已保存")
    }

    @objc func runDefaultConfig() {
        runner.runDefault()
    }

    @objc func stopRunning() {
        runner.stop()
    }

    @objc func runSelectedConfig(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < runner.configs.count else { return }
        runner.run(runner.configs[index])
    }

    @objc func gitPull() {
        sidebar.select(1)
        sidebar.gitPanel.doPull()
    }

    @objc func gitPush() {
        sidebar.select(1)
        sidebar.gitPanel.doPush()
    }

    @objc func showQuickOpen() {
        quickOpen.show(relativeTo: view.window)
    }

    @objc func showProjectSearch() {
        quickOpen.showSearch(relativeTo: view.window)
    }

    @objc func toggleTerminalAction() {
        NotificationCenter.default.post(name: .toggleTerminal, object: nil)
    }

    @objc func toggleAIAction() {
        NotificationCenter.default.post(name: .toggleAIPanel, object: nil)
    }

    @objc func toggleTheme() {
        ThemeManager.shared.toggle()
    }

    @objc func openFolderAction() {
        handleOpenFolder()
    }
}
