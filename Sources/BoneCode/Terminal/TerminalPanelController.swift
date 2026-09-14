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

    private let tabControl = NSSegmentedControl()
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

        tabControl.segmentStyle = .texturedRounded
        tabControl.trackingMode = .selectOne
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.controlSize = .small

        titleLabel.font = Fonts.ui(size: 10.5)
        titleLabel.textColor = ThemeManager.shared.current.tertiaryText
        titleLabel.lineBreakMode = .byTruncatingHead
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

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

        header.addSubview(tabControl)
        header.addSubview(titleLabel)
        header.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            tabControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            tabControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabControl.heightAnchor.constraint(equalToConstant: 20),
            tabControl.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            titleLabel.leadingAnchor.constraint(equalTo: tabControl.trailingAnchor, constant: 8),
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
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = tooltip
        button.image = Icons.symbol(symbol, size: 12)
        button.contentTintColor = ThemeManager.shared.current.secondaryText
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 20)
        ])
        return button
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
        tabControl.segmentCount = max(0, sessions.count)
        for (i, session) in sessions.enumerated() {
            let suffix = session.isRunning ? "" : " ⏹"
            tabControl.setLabel(session.title.truncatedMiddle(to: 18) + suffix, forSegment: i)
        }
        tabControl.selectedSegment = activeIndex
        tabControl.isHidden = sessions.isEmpty
        let active = activeSession
        titleLabel.stringValue = active.map { session -> String in
            let dir = session.workingDirectory ?? ""
            return dir.isEmpty ? "" : dir.abbreviatedPath(maxComponents: 3)
        } ?? ""
        onSessionsChanged?()
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        selectSession(tabControl.selectedSegment)
    }

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

    @objc func closeTerminal() {
        guard activeIndex >= 0, activeIndex < sessions.count else { return }
        let session = sessions[activeIndex]
        session.pty?.terminate()
        session.isRunning = false
        session.onProcessExit?()
        if let token = frameObservers[ObjectIdentifier(session)] {
            NotificationCenter.default.removeObserver(token)
            frameObservers.removeValue(forKey: ObjectIdentifier(session))
        }
        session.scrollView.removeFromSuperview()
        sessions.remove(at: activeIndex)
        if sessions.isEmpty {
            activeIndex = -1
        } else {
            selectSession(min(activeIndex, sessions.count - 1))
        }
        refreshTabs()
    }

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

    /// Run a command in a fresh terminal tab, creating the panel content if needed.
    @discardableResult
    func runCommand(_ command: String, cwd: String?, title: String,
                    workingDirectory: String? = nil) -> TerminalSession {
        let session = createSession(cwd: workingDirectory ?? cwd, command: command, title: title)
        session.workingDirectory = workingDirectory ?? cwd
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
