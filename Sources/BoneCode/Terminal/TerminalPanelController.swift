import AppKit

/// One terminal tab: emulator + view + PTY.
final class TerminalSession {
    let id = UUID()
    let emulator: TerminalEmulator
    let terminalView: TerminalView
    let scrollView: NSScrollView
    var pty: PTY?
    var title: String
    var isRunning = false
    var pendingCommand: String?
    var lastExitCode: Int32?
    var workingDirectory: String?
    /// Called when the process in this session ends, however it ends.
    var onProcessExit: (() -> Void)?

    init(cols: Int, rows: Int, title: String) {
        self.emulator = TerminalEmulator(cols: cols, rows: rows)
        self.terminalView = TerminalView(emulator: emulator)
        self.scrollView = NSScrollView()
        self.title = title

        scrollView.documentView = terminalView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
    }
}

final class TerminalPanelController: NSViewController {

    private let tabStrip = TabStripView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private let header = NSView()
    private let aiBar = NSView()
    private let aiField = NSTextField()
    private let aiStatus = NSTextField(labelWithString: "")
    private var aiBarHeight: NSLayoutConstraint!

    private var sessions: [TerminalSession] = []
    private var activeIndex: Int = -1
    private var frameObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    var onSessionsChanged: (() -> Void)?

    var activeSession: TerminalSession? {
        guard activeIndex >= 0, activeIndex < sessions.count else { return nil }
        return sessions[activeIndex]
    }

    var hasSessions: Bool { !sessions.isEmpty }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.terminalBackground)

        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        // Terminal tabs are label-only and always show their close button: an
        // `NSSegmentedControl` cannot draw a per-segment close affordance, which
        // is why tabs used to be impossible to get rid of.
        tabStrip.delegate = self
        tabStrip.showsIcon = false
        tabStrip.isCompact = true
        tabStrip.alwaysShowsCloseButton = true
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        // The strip sizes itself to its tabs, but must give way when the panel is
        // narrow, otherwise the header buttons get squeezed off the right edge.
        tabStrip.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tabStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = Fonts.ui(size: 10.5)
        titleLabel.textColor = ThemeManager.shared.current.tertiaryText
        titleLabel.lineBreakMode = .byTruncatingHead
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Lowest priority in the row: the path is the first thing to give way.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let newButton = iconButton("plus", tooltip: "新建终端", action: #selector(newTerminal))
        let clearButton = iconButton("eraser", tooltip: "清空", action: #selector(clearTerminal))
        let restartButton = iconButton("arrow.clockwise", tooltip: "重启终端", action: #selector(restartTerminal))
        let stopButton = iconButton("stop.fill", tooltip: "中断当前命令 (Ctrl-C)", action: #selector(interruptTerminal))
        let aiButton = iconButton("sparkles", tooltip: "AI 命令（自然语言转命令）", action: #selector(toggleAIBar))
        let closeButton = iconButton("xmark", tooltip: "关闭当前终端", action: #selector(closeTerminal))

        let buttonStack = NSStackView.horizontal(spacing: 2)
        for b in [aiButton, stopButton, restartButton, clearButton, newButton, closeButton] {
            buttonStack.addArrangedSubview(b)
        }

        header.addSubview(tabStrip)
        header.addSubview(titleLabel)
        header.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            tabStrip.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 22),
            tabStrip.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            titleLabel.leadingAnchor.constraint(equalTo: tabStrip.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            buttonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        // ---- AI command bar
        aiBar.translatesAutoresizingMaskIntoConstraints = false
        aiBar.wantsLayer = true

        let aiIcon = NSImageView()
        aiIcon.image = Icons.symbol("sparkles", size: 12)
        aiIcon.contentTintColor = ThemeManager.shared.current.accent
        aiIcon.translatesAutoresizingMaskIntoConstraints = false

        aiField.placeholderString = "用自然语言描述你要执行的命令，回车生成（例如：查看最近三次提交的改动）"
        aiField.font = Fonts.ui(size: 11.5)
        aiField.translatesAutoresizingMaskIntoConstraints = false
        aiField.target = self
        aiField.action = #selector(aiCommandSubmitted)
        aiField.bezelStyle = .roundedBezel

        aiStatus.font = Fonts.ui(size: 10.5)
        aiStatus.textColor = ThemeManager.shared.current.tertiaryText
        aiStatus.lineBreakMode = .byTruncatingTail
        aiStatus.translatesAutoresizingMaskIntoConstraints = false

        aiBar.addSubview(aiIcon)
        aiBar.addSubview(aiField)
        aiBar.addSubview(aiStatus)
        NSLayoutConstraint.activate([
            aiIcon.leadingAnchor.constraint(equalTo: aiBar.leadingAnchor, constant: 8),
            aiIcon.centerYAnchor.constraint(equalTo: aiField.centerYAnchor),
            aiIcon.widthAnchor.constraint(equalToConstant: 14),

            aiField.leadingAnchor.constraint(equalTo: aiIcon.trailingAnchor, constant: 6),
            aiField.trailingAnchor.constraint(equalTo: aiBar.trailingAnchor, constant: -8),
            aiField.topAnchor.constraint(equalTo: aiBar.topAnchor, constant: 5),
            aiField.heightAnchor.constraint(equalToConstant: 22),

            aiStatus.leadingAnchor.constraint(equalTo: aiField.leadingAnchor),
            aiStatus.trailingAnchor.constraint(equalTo: aiField.trailingAnchor),
            aiStatus.topAnchor.constraint(equalTo: aiField.bottomAnchor, constant: 3)
        ])

        root.addSubview(header)
        root.addSubview(container)
        root.addSubview(aiBar)

        aiBarHeight = aiBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: header.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: aiBar.topAnchor),

            aiBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            aiBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            aiBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            aiBarHeight
        ])

        view = root
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSendText(_:)),
                                               name: .terminalSendText, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(aiResultReceived(_:)),
                                               name: .aiInsertCommandRequested, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for session in sessions { session.pty?.terminate() }
    }

    @objc private func themeChanged() {
        ensureViewLoaded()
        applyTheme()
        refreshTabs()
    }

    private func applyTheme() {
        ensureViewLoaded()
        let theme = ThemeManager.shared.current
        view.setBackground(theme.terminalBackground)
        header.setBackground(theme.tabBarBackground)
        aiBar.setBackground(theme.panelBackground)
        aiStatus.textColor = theme.tertiaryText
        titleLabel.textColor = theme.tertiaryText
        for session in sessions {
            session.scrollView.backgroundColor = theme.terminalBackground
            session.terminalView.needsDisplay = true
        }
        view.refreshHoverButtons()
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        HoverIconButton(symbol: symbol, tooltip: tooltip, target: self, action: action,
                        width: 24, height: 20, symbolSize: 12)
    }

    /// The terminal panel starts collapsed, and NSSplitViewController does not
    /// load a collapsed item's view. Any entry point that touches the view
    /// hierarchy must therefore force it first, otherwise subviews would be
    /// added to a detached container.
    private func ensureViewLoaded() {
        _ = view
    }

    // MARK: - Sessions

    @discardableResult
    func createSession(cwd: String?, command: String? = nil, title: String? = nil) -> TerminalSession {
        ensureViewLoaded()
        let session = TerminalSession(cols: 100, rows: 30, title: title ?? "终端 \(sessions.count + 1)")
        session.workingDirectory = cwd
        session.pendingCommand = command

        session.terminalView.onInput = { [weak session] data in
            session?.pty?.write(data)
        }
        session.terminalView.onResize = { [weak session] cols, rows in
            session?.pty?.resize(cols: cols, rows: rows)
        }
        session.terminalView.onTitleChange = { [weak self, weak session] newTitle in
            guard let session else { return }
            session.title = newTitle
            self?.refreshTabs()
        }
        session.emulator.onResponse = { [weak session] text in
            session?.pty?.write(text)
        }

        sessions.append(session)
        container.addSubview(session.scrollView)
        session.scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            session.scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            session.scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            session.scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        observeFrame(of: session)
        view.layoutSubtreeIfNeeded()
        session.terminalView.updateSizeFromScrollView()

        startShell(for: session)
        selectSession(sessions.count - 1)
        return session
    }

    private func observeFrame(of session: TerminalSession) {
        session.scrollView.contentView.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: session.scrollView.contentView,
            queue: .main
        ) { [weak session] _ in
            guard let session else { return }
            session.terminalView.updateSizeFromScrollView()
        }
        frameObservers[ObjectIdentifier(session)] = token
    }

    private func startShell(for session: TerminalSession) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let pty = PTY(shell: shell,
                            cwd: session.workingDirectory,
                            cols: session.emulator.cols,
                            rows: session.emulator.rows) else {
            session.emulator.feed(Data("\n[无法启动终端：PTY 分配失败]\n".utf8))
            return
        }

        session.pty = pty
        session.isRunning = true
        session.lastExitCode = nil

        var hasSeenFirstOutput = false
        pty.onOutput = { [weak session] data in
            session?.emulator.feed(data)
            if !hasSeenFirstOutput {
                hasSeenFirstOutput = true
                if let command = session?.pendingCommand, !command.isEmpty {
                    session?.pendingCommand = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        session?.pty?.write(command + "\n")
                    }
                }
            }
        }
        pty.onExit = { [weak self, weak session] code in
            guard let session else { return }
            session.isRunning = false
            session.lastExitCode = code
            let message = code == 0
                ? "\n\u{1B}[90m[进程已结束]\u{1B}[0m\n"
                : "\n\u{1B}[31m[进程已结束，退出码 \(code)]\u{1B}[0m\n"
            session.emulator.feed(Data(message.utf8))
            session.onProcessExit?()
            self?.refreshTabs()
        }

        // The command is sent once the shell prompt arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak session] in
            guard let session, session.pendingCommand != nil else { return }
            if let command = session.pendingCommand {
                session.pendingCommand = nil
                session.pty?.write(command + "\n")
            }
        }

        refreshTabs()
    }

    private func selectSession(_ index: Int) {
        guard index >= 0, index < sessions.count else { return }
        activeIndex = index
        for (i, session) in sessions.enumerated() {
            session.scrollView.isHidden = (i != index)
        }
        sessions[index].terminalView.updateSizeFromScrollView()
        sessions[index].scrollView.documentView?.window?.makeFirstResponder(sessions[index].terminalView)
        refreshTabs()
    }

    private func refreshTabs() {
        ensureViewLoaded()
        let theme = ThemeManager.shared.current
        tabStrip.items = sessions.map { session in
            // A dot marks a live process; an exited one keeps a marker in the
            // title so the two states stay distinguishable at a glance.
            TabStripView.Item(title: session.title.truncatedMiddle(to: 18)
                                + (session.isRunning ? "" : " ⏹"),
                              iconName: "terminal",
                              showsDot: session.isRunning,
                              dotColor: theme.diffAddedText)
        }
        tabStrip.selectedIndex = activeIndex
        tabStrip.isHidden = sessions.isEmpty
        let active = activeSession
        titleLabel.stringValue = active.map { session -> String in
            let dir = session.workingDirectory ?? ""
            return dir.isEmpty ? "" : dir.abbreviatedPath(maxComponents: 3)
        } ?? ""
        onSessionsChanged?()
    }

    // MARK: - Actions

    @objc func newTerminal() {
        let cwd = AppState.shared.workspaceRoot?.path ?? NSHomeDirectory()
        createSession(cwd: cwd)
    }

    @objc func clearTerminal() {
        activeSession?.terminalView.clearScreenAction(nil)
    }

    @objc func restartTerminal() {
        guard let session = activeSession else { return }
        session.pty?.terminate()
        session.emulator.reset()
        startShell(for: session)
    }

    private var interruptRequestedAt: Date?

    /// First press sends Ctrl-C; a second press within five seconds escalates to
    /// SIGKILL, since plenty of processes ignore the interrupt.
    @objc func interruptTerminal() {
        guard let session = activeSession else { return }

        if let requested = interruptRequestedAt, Date().timeIntervalSince(requested) < 5 {
            interruptRequestedAt = nil
            session.pty?.forceKill()
            AppState.shared.postStatus("已强制结束进程 (SIGKILL)")
            return
        }

        interruptRequestedAt = Date()
        session.pty?.sendInterrupt()
        AppState.shared.postStatus("已发送 Ctrl-C；若仍在运行，请再点一次强制结束")
    }

    /// Closes the active tab. Kept for the toolbar button and the ⌘W path.
    @objc func closeTerminal() {
        closeSession(at: activeIndex)
    }

    /// Tear down one session and its tab.
    func closeSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        let session = sessions[index]
        session.pty?.terminate()
        session.isRunning = false
        session.onProcessExit?()
        if let token = frameObservers[ObjectIdentifier(session)] {
            NotificationCenter.default.removeObserver(token)
            frameObservers.removeValue(forKey: ObjectIdentifier(session))
        }
        session.scrollView.removeFromSuperview()
        sessions.remove(at: index)

        if sessions.isEmpty {
            activeIndex = -1
        } else if index <= activeIndex {
            // Keep the same tab selected where possible, otherwise step left.
            selectSession(min(max(0, activeIndex - 1), sessions.count - 1))
            return
        } else {
            selectSession(min(activeIndex, sessions.count - 1))
            return
        }
        refreshTabs()
    }

    /// Close every tab except `index`.
    func closeOtherSessions(keeping index: Int) {
        guard sessions.count > 1, index >= 0, index < sessions.count else { return }
        let keep = sessions[index]
        for (i, session) in sessions.enumerated() where i != index {
            session.pty?.terminate()
            session.isRunning = false
            session.onProcessExit?()
            if let token = frameObservers[ObjectIdentifier(session)] {
                NotificationCenter.default.removeObserver(token)
                frameObservers.removeValue(forKey: ObjectIdentifier(session))
            }
            session.scrollView.removeFromSuperview()
        }
        sessions = [keep]
        activeIndex = 0
        selectSession(0)
    }

    /// Close every tab. The panel stays open with no sessions, which is the state
    /// a freshly opened terminal panel starts in.
    func closeAllSessions() {
        guard !sessions.isEmpty else { return }
        for session in sessions {
            session.pty?.terminate()
            session.isRunning = false
            session.onProcessExit?()
            if let token = frameObservers[ObjectIdentifier(session)] {
                NotificationCenter.default.removeObserver(token)
                frameObservers.removeValue(forKey: ObjectIdentifier(session))
            }
            session.scrollView.removeFromSuperview()
        }
        sessions.removeAll()
        activeIndex = -1
        refreshTabs()
    }

    /// Restart the shell in one tab, in place.
    func restartSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        let session = sessions[index]
        session.pty?.terminate()
        session.isRunning = false
        session.emulator.reset()
        session.pendingCommand = nil
        startShell(for: session)
    }

    func selectSession(at index: Int) {
        selectSession(index)
    }

    func sessionCount() -> Int { sessions.count }

    func sessionTitle(at index: Int) -> String? {
        sessions.indices.contains(index) ? sessions[index].title : nil
    }

    func isSessionRunning(at index: Int) -> Bool {
        sessions.indices.contains(index) ? sessions[index].isRunning : false
    }

    /// Exposed so the tab strip's hit boxes can be asserted in tests.
    var tabStripView: TabStripView { ensureViewLoaded(); return tabStrip }

    func terminateAll() {
        for session in sessions {
            session.pty?.terminate()
            session.isRunning = false
            session.onProcessExit?()
        }
    }

    /// Send Ctrl-C to the foreground job.
    func stopActiveProcess() {
        activeSession?.pty?.sendInterrupt()
    }

    /// Escalate when the job ignores SIGINT.
    func forceKillActiveProcess() {
        activeSession?.pty?.forceKill()
    }

    /// Run a command in a terminal tab, creating the panel content if needed.
    ///
    /// Reuses an existing tab for the same configuration. Pressing Run twice used
    /// to stack two identically-titled tabs, which then had to be closed by hand
    /// and made it unclear which one was live.
    @discardableResult
    func runCommand(_ command: String, cwd: String?, title: String,
                    workingDirectory: String? = nil,
                    reuseExisting: Bool = true) -> TerminalSession {
        let dir = workingDirectory ?? cwd

        if reuseExisting, let index = sessions.firstIndex(where: {
            $0.title == title && ($0.workingDirectory ?? "") == (dir ?? "")
        }) {
            let session = sessions[index]
            if session.isRunning {
                selectSession(index)
                AppState.shared.postStatus("「\(title)」已经在运行，已切到那个终端")
            } else {
                // The process ended; re-run it in the same tab rather than
                // leaving a dead tab and opening a new one beside it.
                session.emulator.reset()
                session.lastExitCode = nil
                session.pendingCommand = command
                startShell(for: session)
                selectSession(index)
                AppState.shared.postStatus("已重新运行「\(title)」")
            }
            refreshTabs()
            return session
        }

        let session = createSession(cwd: dir, command: command, title: title)
        session.workingDirectory = dir
        refreshTabs()
        return session
    }

    @objc private func handleSendText(_ note: Notification) {
        guard let text = note.object as? String else { return }
        if let session = activeSession {
            session.pty?.write(text)
            session.scrollView.documentView?.window?.makeFirstResponder(session.terminalView)
        }
    }

    func sendToActive(_ text: String) {
        activeSession?.pty?.write(text)
    }

    func focusActiveTerminal() {
        ensureViewLoaded()
        guard let session = activeSession else { return }
        session.terminalView.window?.makeFirstResponder(session.terminalView)
    }

    // MARK: - AI command bar

    @objc private func toggleAIBar() {
        ensureViewLoaded()
        let showing = aiBarHeight.constant > 0
        aiBarHeight.constant = showing ? 0 : 46
        aiBar.isHidden = showing
        if !showing {
            aiField.window?.makeFirstResponder(aiField)
        }
    }

    @objc private func aiCommandSubmitted() {
        let query = aiField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard AIService.shared.isConfigured else {
            aiStatus.stringValue = "尚未配置 AI：请在「设置 → AI 助手」中填入接口地址与密钥"
            return
        }
        aiStatus.stringValue = "正在生成命令…"
        let context = AppState.shared.shellContext()
        AIService.shared.generateShellCommand(request: query, context: context) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let command):
                let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "```bash", with: "")
                    .replacingOccurrences(of: "```sh", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.aiStatus.stringValue = "已生成：\(cleaned.firstLine)  —  回车再次执行，或按 ⌘↩ 插入不执行"
                self.pendingAICommand = cleaned
            case .failure(let error):
                self.aiStatus.stringValue = "生成失败：\(error.localizedDescription)"
            }
        }
    }

    private var pendingAICommand: String?

    @objc private func aiResultReceived(_ note: Notification) {
        guard let command = note.object as? String else { return }
        aiBarHeight.constant = 46
        aiBar.isHidden = false
        pendingAICommand = command
        aiField.stringValue = ""
        aiStatus.stringValue = "已生成：\(command.firstLine)"
    }

    /// Enter in the AI field: first press generates, second press runs.
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }

    func executePendingAICommand() {
        guard let command = pendingAICommand else { return }
        pendingAICommand = nil
        aiStatus.stringValue = ""
        aiField.stringValue = ""
        let session = activeSession ?? createSession(cwd: AppState.shared.workspaceRoot?.path)
        session.pty?.write(command + "\n")
        focusActiveTerminal()
    }
}

// MARK: - Tab strip

extension TerminalPanelController: TabStripViewDelegate {

    func tabStrip(_ strip: TabStripView, didSelect index: Int) {
        selectSession(index)
    }

    func tabStrip(_ strip: TabStripView, didClose index: Int) {
        closeSession(at: index)
    }

    func tabStrip(_ strip: TabStripView, menuFor index: Int) -> NSMenu? {
        guard sessions.indices.contains(index) else { return nil }
        let hasOthers = sessions.count > 1
        let isRunning = sessions[index].isRunning

        let menu = NSMenu()
        let entries: [(String, TerminalTabAction, Bool)] = [
            ("关闭", .close, true),
            ("关闭其他终端", .closeOthers, hasOthers),
            ("关闭全部终端", .closeAll, hasOthers),
            ("", .close, false),
            ("重启这个终端", .restart, true),
            (isRunning ? "中断当前命令 (Ctrl-C)" : "复制工作目录", isRunning ? .interrupt : .copyPath, true)
        ]
        for (title, action, enabled) in entries {
            if title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(terminalTabMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = TerminalTabMenuPayload(action: action, index: index)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    private final class TerminalTabMenuPayload: NSObject {
        let action: TerminalTabAction
        let index: Int
        init(action: TerminalTabAction, index: Int) {
            self.action = action
            self.index = index
        }
    }

    @objc fileprivate func terminalTabMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? TerminalTabMenuPayload else { return }
        performTerminalTabAction(payload.action, on: payload.index)
    }

    func performTerminalTabAction(_ action: TerminalTabAction, on index: Int) {
        guard sessions.indices.contains(index) else { return }
        switch action {
        case .close:
            closeSession(at: index)
        case .closeOthers:
            closeOtherSessions(keeping: index)
        case .closeAll:
            closeAllSessions()
        case .restart:
            restartSession(at: index)
        case .interrupt:
            sessions[index].pty?.sendInterrupt()
        case .copyPath:
            guard let dir = sessions[index].workingDirectory, !dir.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(dir, forType: .string)
            AppState.shared.postStatus("已复制工作目录")
        }
    }
}

/// Commands offered by the terminal tab context menu.
enum TerminalTabAction {
    case close
    case closeOthers
    case closeAll
    case restart
    case interrupt
    case copyPath
}
