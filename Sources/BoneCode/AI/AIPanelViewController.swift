import AppKit

/// Right-hand AI panel: streaming chat, quick actions, and applying the
/// generated code back into the editor.
final class AIPanelViewController: NSViewController {

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "AI 助手")
    private let modelLabel = NSTextField(labelWithString: "")
    private let transcriptScroll = NSScrollView()
    private let transcriptView = NSTextView()
    private let inputScroll = NSScrollView()
    private let inputView = NSTextView()
    private let sendButton = NSButton()
    private let stopButton = NSButton()
    private let applyBar = NSView()
    private let applyLabel = NSTextField(labelWithString: "")
    private var applyButtons: [NSButton] = []
    private var applyBarHeight: NSLayoutConstraint!
    private let quickStack = NSStackView()
    private let inputHint = NSTextField(labelWithString: "回车发送 · Shift+回车换行")

    private var history: [AIService.Message] = []
    private var isStreaming = false
    private var assistantRangeStart = 0
    private var lastResponse = ""
    private var pendingCodeBlocks: [String] = []

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.panelBackground)

        // ---- header
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Fonts.ui(size: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.font = Fonts.ui(size: 10)
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = iconButton("gearshape", "AI 设置", #selector(openSettings))
        let clearButton = iconButton("trash", "清空对话", #selector(clearConversation))
        let buttonStack = NSStackView.horizontal(spacing: 2)
        buttonStack.addArrangedSubview(settingsButton)
        buttonStack.addArrangedSubview(clearButton)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(titleLabel)
        header.addSubview(modelLabel)
        header.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            modelLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            modelLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modelLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -6),

            buttonStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            buttonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        // ---- quick actions
        quickStack.orientation = .horizontal
        quickStack.spacing = 4
        quickStack.alignment = .centerY
        quickStack.translatesAutoresizingMaskIntoConstraints = false
        for (title, selector) in [
            ("解释代码", #selector(quickExplain)),
            ("找 Bug", #selector(quickBugs)),
            ("写测试", #selector(quickTests)),
            ("审查改动", #selector(quickReviewDiff))
        ] {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Fonts.ui(size: 10)
            quickStack.addArrangedSubview(button)
        }

        // ---- transcript
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = true
        transcriptScroll.autohidesScrollers = true
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = true
        transcriptView.textContainerInset = NSSize(width: 8, height: 8)
        transcriptScroll.documentView = transcriptView

        // ---- apply bar
        applyBar.translatesAutoresizingMaskIntoConstraints = false
        applyBar.wantsLayer = true
        applyLabel.font = Fonts.ui(size: 10.5)
        applyLabel.translatesAutoresizingMaskIntoConstraints = false
        applyBar.addSubview(applyLabel)
        let applyRow = NSStackView.horizontal(spacing: 4)
        applyRow.translatesAutoresizingMaskIntoConstraints = false
        for (title, selector) in [
            ("替换选中内容", #selector(applyReplaceSelection)),
            ("插入到光标处", #selector(applyInsertAtCursor)),
            ("复制代码", #selector(copyCode)),
            ("关闭", #selector(hideApplyBar))
        ] {
            let button = NSButton(title: title, target: self, action: selector)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Fonts.ui(size: 10)
            applyRow.addArrangedSubview(button)
            applyButtons.append(button)
        }
        applyBar.addSubview(applyRow)
        NSLayoutConstraint.activate([
            applyLabel.leadingAnchor.constraint(equalTo: applyBar.leadingAnchor, constant: 8),
            applyLabel.topAnchor.constraint(equalTo: applyBar.topAnchor, constant: 4),
            applyRow.leadingAnchor.constraint(equalTo: applyBar.leadingAnchor, constant: 8),
            applyRow.topAnchor.constraint(equalTo: applyLabel.bottomAnchor, constant: 3)
        ])

        // ---- input
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.drawsBackground = true
        inputView.isRichText = false
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.font = Fonts.ui(size: 12)
        inputView.textContainerInset = NSSize(width: 5, height: 5)
        inputView.delegate = self
        inputScroll.documentView = inputView

        sendButton.title = "发送"
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.font = Fonts.ui(size: 11, weight: .medium)
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        stopButton.title = "停止"
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = Fonts.ui(size: 11)
        stopButton.target = self
        stopButton.action = #selector(stopStreaming)
        stopButton.isHidden = true
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        inputHint.font = Fonts.ui(size: 10)
        inputHint.textColor = ThemeManager.shared.current.tertiaryText
        inputHint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(inputHint)

        root.addSubview(header)
        root.addSubview(quickStack)
        root.addSubview(transcriptScroll)
        root.addSubview(applyBar)
        root.addSubview(inputScroll)
        root.addSubview(sendButton)
        root.addSubview(stopButton)

        applyBarHeight = applyBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            quickStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            quickStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            quickStack.heightAnchor.constraint(equalToConstant: 22),

            transcriptScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: quickStack.bottomAnchor, constant: 4),
            transcriptScroll.bottomAnchor.constraint(equalTo: applyBar.topAnchor),

            applyBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            applyBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            applyBar.bottomAnchor.constraint(equalTo: inputScroll.topAnchor),
            applyBarHeight,

            inputScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            inputScroll.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -5),
            inputScroll.heightAnchor.constraint(equalToConstant: 74),

            sendButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 62),

            stopButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -5),
            stopButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 62),

            inputHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            inputHint.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            inputHint.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -6)
        ])

        view = root
        applyTheme()
        renderIntro()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { applyTheme(); rerenderTranscript() }

    private func applyTheme() {
        let theme = ThemeManager.shared.current
        view.setBackground(theme.panelBackground)
        header.setBackground(theme.tabBarBackground)
        applyBar.setBackground(theme.accentSoft)
        applyLabel.textColor = theme.accent
        inputHint.textColor = theme.tertiaryText
        titleLabel.textColor = theme.text
        modelLabel.textColor = theme.tertiaryText
        transcriptView.backgroundColor = theme.panelBackground
        transcriptView.textColor = theme.text
        inputView.backgroundColor = theme.editorBackground
        inputView.textColor = theme.text
        inputView.insertionPointColor = theme.caretColor
        refreshModelLabel()
    }

    private func iconButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = tooltip
        button.image = Icons.symbol(symbol, size: 12)
        button.contentTintColor = ThemeManager.shared.current.secondaryText
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20)
        ])
        return button
    }

    private func refreshModelLabel() {
        modelLabel.stringValue = AIService.shared.isConfigured
            ? AIService.shared.model
            : "未配置"
    }

    // MARK: - Transcript rendering

    private func baseAttributes(_ theme: Theme) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [.font: Fonts.ui(size: 12), .foregroundColor: theme.text, .paragraphStyle: paragraph]
    }

    private func renderIntro() {
        let theme = ThemeManager.shared.current
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "BoneCode AI 助手\n", attributes: [
            .font: Fonts.ui(size: 13, weight: .semibold),
            .foregroundColor: theme.text
        ]))
        let hint = AIService.shared.isConfigured
            ? "可以直接提问，也可以选中代码后用上面的快捷按钮。\n生成的代码可以一键替换选中内容或插入到光标处。"
            : "还没有配置模型接口。\n点击右上角 ⚙️ 填入接口地址、模型名与 API Key 即可启用。\n\n兼容任何 OpenAI 格式的服务：OpenAI、DeepSeek、Kimi、通义、Ollama 等。"
        text.append(NSAttributedString(string: hint + "\n", attributes: baseAttributes(theme)))
        transcriptView.textStorage?.setAttributedString(text)
    }

    private func rerenderTranscript() {
        guard !history.isEmpty else { renderIntro(); return }
        let theme = ThemeManager.shared.current
        let output = NSMutableAttributedString()
        for message in history {
            output.append(render(message, theme: theme))
        }
        transcriptView.textStorage?.setAttributedString(output)
        transcriptView.scrollToEndOfDocument(nil)
    }

    private func render(_ message: AIService.Message, theme: Theme) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let isUser = message.role == "user"
        output.append(NSAttributedString(string: isUser ? "\n你\n" : "\nAI\n", attributes: [
            .font: Fonts.ui(size: 10.5, weight: .semibold),
            .foregroundColor: isUser ? theme.secondaryText : theme.accent
        ]))
        output.append(StyledText.render(message.content, theme: theme,
                                        baseFont: Fonts.ui(size: 12),
                                        monoFont: Fonts.code(size: 11.5)))
        output.append(NSAttributedString(string: "\n", attributes: baseAttributes(theme)))
        return output
    }

    // MARK: - Sending

    @objc private func sendMessage() {
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard AIService.shared.isConfigured else {
            presentNotConfigured()
            return
        }
        inputView.string = ""
        hideApplyBar()
        send(text)
    }

    private func send(_ question: String) {
        let theme = ThemeManager.shared.current
        history.append(.user(question))

        let storage = transcriptView.textStorage!
        storage.append(render(history[history.count - 1], theme: theme))

        // Assistant header + streaming area
        storage.append(NSAttributedString(string: "\nAI\n", attributes: [
            .font: Fonts.ui(size: 10.5, weight: .semibold),
            .foregroundColor: theme.accent
        ]))
        assistantRangeStart = storage.length
        lastResponse = ""
        isStreaming = true
        sendButton.isHidden = true
        stopButton.isHidden = false
        transcriptView.scrollToEndOfDocument(nil)

        let context = AppState.shared.codeContext(maxChars: 6000)
        var prior: [AIService.Message] = []
        // Keep the last few turns so follow-ups have context.
        let historyWithoutLatest = history.dropLast()
        prior = Array(historyWithoutLatest.suffix(6))

        AIService.shared.ask(question: question, context: context, history: prior, onDelta: { [weak self] delta in
            guard let self else { return }
            self.lastResponse += delta
            let storage = self.transcriptView.textStorage!
            storage.append(NSAttributedString(string: delta, attributes: self.baseAttributes(ThemeManager.shared.current)))
            self.transcriptView.scrollToEndOfDocument(nil)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.isStreaming = false
            self.sendButton.isHidden = false
            self.stopButton.isHidden = true

            switch result {
            case .success(let full):
                self.lastResponse = full
                self.history.append(.assistant(full))
                self.replaceAssistantRange(with: full)
                self.extractCodeBlocks(from: full)
            case .failure(let error):
                self.history.append(.assistant(self.lastResponse))
                self.replaceAssistantRange(with: self.lastResponse)
                let storage = self.transcriptView.textStorage!
                storage.append(NSAttributedString(string: "\n⚠️ \(error.localizedDescription)\n", attributes: [
                    .font: Fonts.ui(size: 11),
                    .foregroundColor: ThemeManager.shared.current.diffRemovedText
                ]))
            }
            self.transcriptView.scrollToEndOfDocument(nil)
        })
    }

    /// Re-style the streamed plain text once the full message is known.
    private func replaceAssistantRange(with full: String) {
        let storage = transcriptView.textStorage!
        guard assistantRangeStart <= storage.length else { return }
        let range = NSRange(location: assistantRangeStart, length: storage.length - assistantRangeStart)
        let theme = ThemeManager.shared.current
        let styled = NSMutableAttributedString()
        styled.append(StyledText.render(full, theme: theme,
                                        baseFont: Fonts.ui(size: 12),
                                        monoFont: Fonts.code(size: 11.5)))
        styled.append(NSAttributedString(string: "\n", attributes: baseAttributes(theme)))
        storage.replaceCharacters(in: range, with: styled)
    }

    @objc private func stopStreaming() {
        // The stream finishes on its own; we simply stop appending.
        isStreaming = false
        stopButton.isHidden = true
        sendButton.isHidden = false
    }

    @objc private func clearConversation() {
        history.removeAll()
        lastResponse = ""
        hideApplyBar()
        renderIntro()
    }

    // MARK: - Code blocks

    private func extractCodeBlocks(from text: String) {
        var blocks: [String] = []
        var searchStart = text.startIndex
        while let fenceStart = text.range(of: "```", range: searchStart..<text.endIndex) {
            guard let newline = text.range(of: "\n", range: fenceStart.upperBound..<text.endIndex) else { break }
            guard let fenceEnd = text.range(of: "```", range: newline.upperBound..<text.endIndex) else { break }
            let code = String(text[newline.upperBound..<fenceEnd.lowerBound])
            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(code.trimmingCharacters(in: .newlines))
            }
            searchStart = fenceEnd.upperBound
        }
        pendingCodeBlocks = blocks
        guard !blocks.isEmpty else {
            hideApplyBar()
            return
        }
        applyLabel.stringValue = "AI 回复包含 \(blocks.count) 段代码"
        applyBarHeight.constant = 48
        applyBar.isHidden = false
    }

    @objc private func hideApplyBar() {
        applyBarHeight.constant = 0
        applyBar.isHidden = true
        pendingCodeBlocks = []
    }

    private func codeToApply() -> String? {
        guard !pendingCodeBlocks.isEmpty else { return nil }
        if pendingCodeBlocks.count == 1 { return pendingCodeBlocks[0] }
        // Multiple blocks: ask which one.
        let alert = NSAlert()
        alert.messageText = "选择要应用的代码段"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        for (index, block) in pendingCodeBlocks.enumerated() {
            let firstLine = block.components(separatedBy: "\n").first ?? ""
            popup.addItem(withTitle: "#\(index + 1)  \(firstLine.prefix(50))")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = max(0, min(popup.indexOfSelectedItem, pendingCodeBlocks.count - 1))
        return pendingCodeBlocks[index]
    }

    @objc private func applyReplaceSelection() {
        guard let code = codeToApply() else { return }
        guard let editor = AppState.shared.editorArea?.currentCodeEditor else {
            AppState.shared.postStatus("没有打开的文件可以应用")
            return
        }
        let textView = editor.textView!
        let range = textView.selectedRange()
        guard range.length > 0 else {
            AppState.shared.postStatus("请先在编辑器里选中要替换的内容")
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: code) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: code)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: (code as NSString).length))
        textView.rehighlight()
        AppState.shared.postStatus("已替换选中内容")
        hideApplyBar()
    }

    @objc private func applyInsertAtCursor() {
        guard let code = codeToApply() else { return }
        guard let editor = AppState.shared.editorArea?.currentCodeEditor else {
            AppState.shared.postStatus("没有打开的文件可以应用")
            return
        }
        let textView = editor.textView!
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: code) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: code)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + (code as NSString).length, length: 0))
        textView.rehighlight()
        AppState.shared.postStatus("已插入代码")
        hideApplyBar()
    }

    @objc private func copyCode() {
        guard !pendingCodeBlocks.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pendingCodeBlocks.joined(separator: "\n\n"), forType: .string)
        AppState.shared.postStatus("已复制代码")
    }

    // MARK: - Quick actions

    private func requireTarget() -> (text: String, languageID: String, path: String, isSelection: Bool)? {
        guard AIService.shared.isConfigured else {
            presentNotConfigured()
            return nil
        }
        guard let target = AppState.shared.editableTarget() else {
            AppState.shared.postStatus("请先打开一个文件")
            return nil
        }
        return target
    }

    private func run(promptTitle: String, start: @escaping (String, String) -> Void) {
        guard let target = requireTarget() else { return }
        hideApplyBar()
        let theme = ThemeManager.shared.current
        let storage = transcriptView.textStorage!
        storage.append(NSAttributedString(string: "\n你\n", attributes: [
            .font: Fonts.ui(size: 10.5, weight: .semibold),
            .foregroundColor: theme.secondaryText
        ]))
        let scope = target.isSelection ? "选中的代码" : "整个文件"
        storage.append(NSAttributedString(string: promptTitle + "（\(scope)）\n",
                                          attributes: baseAttributes(theme)))
        history.append(.user(promptTitle + "：\(target.path)"))

        storage.append(NSAttributedString(string: "\nAI\n", attributes: [
            .font: Fonts.ui(size: 10.5, weight: .semibold),
            .foregroundColor: theme.accent
        ]))
        assistantRangeStart = storage.length
        lastResponse = ""
        isStreaming = true
        sendButton.isHidden = true
        stopButton.isHidden = false

        let context = AppState.shared.codeContext(maxChars: 4000)
        let question = "文件：\(target.path)\n\n上下文：\n\(context)\n\n待处理代码：\n```\(target.languageID)\n\(target.text)\n```"
        _ = start

        AIService.shared.streamChat(messages: [
            .system("你是一位资深软件工程师，正在代码编辑器中协助用户。回答使用简体中文，代码保留英文。只输出结论与必要的代码。"),
            .user(promptTitle + "\n\n" + question)
        ], onDelta: { [weak self] delta in
            guard let self else { return }
            self.lastResponse += delta
            self.transcriptView.textStorage?.append(NSAttributedString(
                string: delta, attributes: self.baseAttributes(ThemeManager.shared.current)))
            self.transcriptView.scrollToEndOfDocument(nil)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.isStreaming = false
            self.sendButton.isHidden = false
            self.stopButton.isHidden = true
            switch result {
            case .success(let full):
                self.lastResponse = full
                self.history.append(.assistant(full))
                self.replaceAssistantRange(with: full)
                self.extractCodeBlocks(from: full)
            case .failure(let error):
                self.history.append(.assistant(self.lastResponse))
                self.replaceAssistantRange(with: self.lastResponse)
                self.transcriptView.textStorage?.append(NSAttributedString(
                    string: "\n⚠️ \(error.localizedDescription)\n",
                    attributes: [.font: Fonts.ui(size: 11),
                                 .foregroundColor: ThemeManager.shared.current.diffRemovedText]))
            }
            self.transcriptView.scrollToEndOfDocument(nil)
        })
    }

    @objc private func quickExplain() {
        run(promptTitle: "请解释这段代码的作用、关键流程和潜在问题") { _, _ in }
    }

    @objc private func quickBugs() {
        run(promptTitle: "请审查这段代码，找出 bug、边界问题与安全隐患，按严重程度排序") { _, _ in }
    }

    @objc private func quickTests() {
        run(promptTitle: "请为这段代码编写单元测试，只输出测试代码") { _, _ in }
    }

    @objc func quickReviewDiff() {
        guard AIService.shared.isConfigured else {
            presentNotConfigured()
            return
        }
        guard GitService.shared.isOpen else {
            AppState.shared.postStatus("当前不是 Git 仓库")
            return
        }
        hideApplyBar()
        let theme = ThemeManager.shared.current
        let storage = transcriptView.textStorage!
        storage.append(NSAttributedString(string: "\n你\n审查当前改动\n", attributes: [
            .font: Fonts.ui(size: 10.5, weight: .semibold),
            .foregroundColor: theme.secondaryText
        ]))
        storage.append(NSAttributedString(string: "\nAI\n", attributes: [
            .font: Fonts.ui(size: 10.5, weight: .semibold),
            .foregroundColor: theme.accent
        ]))
        assistantRangeStart = storage.length
        lastResponse = ""

        GitService.shared.diffAll(staged: false) { [weak self] workingDiff in
            GitService.shared.diffAll(staged: true) { [weak self] stagedDiff in
                guard let self else { return }
                let combined = String((stagedDiff + "\n" + workingDiff).prefix(16000))
                guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.transcriptView.textStorage?.append(NSAttributedString(
                        string: "当前没有未提交的改动。\n",
                        attributes: self.baseAttributes(ThemeManager.shared.current)))
                    return
                }
                self.isStreaming = true
                self.sendButton.isHidden = true
                self.stopButton.isHidden = false
                AIService.shared.reviewDiff(diff: combined) { [weak self] result in
                    guard let self else { return }
                    self.isStreaming = false
                    self.sendButton.isHidden = false
                    self.stopButton.isHidden = true
                    switch result {
                    case .success(let full):
                        self.lastResponse = full
                        self.history.append(.assistant(full))
                        self.replaceAssistantRange(with: full)
                        self.extractCodeBlocks(from: full)
                    case .failure(let error):
                        self.transcriptView.textStorage?.append(NSAttributedString(
                            string: "\n⚠️ \(error.localizedDescription)\n",
                            attributes: [.font: Fonts.ui(size: 11),
                                         .foregroundColor: ThemeManager.shared.current.diffRemovedText]))
                    }
                    self.transcriptView.scrollToEndOfDocument(nil)
                }
            }
        }
    }

    // MARK: - Settings

    @objc func openSettings() {
        let alert = NSAlert()
        alert.messageText = "AI 助手设置"
        alert.informativeText = "兼容任何 OpenAI 格式的接口。API Key 保存在 macOS 钥匙串中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 168))

        let baseLabel = NSTextField(labelWithString: "接口地址")
        let baseField = NSTextField(string: AIService.shared.baseURL)
        let modelLabel = NSTextField(labelWithString: "模型名称")
        let modelField = NSTextField(string: AIService.shared.model)
        let keyLabel = NSTextField(labelWithString: "API Key")
        let keyField = NSSecureTextField(string: AIService.shared.apiKey ?? "")
        let tempLabel = NSTextField(labelWithString: "温度")
        let tempField = NSTextField(string: String(format: "%.1f", AIService.shared.temperature))

        let rows: [(NSTextField, NSView)] = [
            (baseLabel, baseField), (modelLabel, modelField), (keyLabel, keyField), (tempLabel, tempField)
        ]
        var y: CGFloat = 138
        for (label, field) in rows {
            label.font = Fonts.ui(size: 11)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y, width: 74, height: 20)
            field.frame = NSRect(x: 80, y: y, width: 330, height: 22)
            container.addSubview(label)
            container.addSubview(field)
            y -= 30
        }

        let hint = NSTextField(labelWithString: "示例：https://api.deepseek.com/v1 · deepseek-chat")
        hint.font = Fonts.ui(size: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 80, y: 8, width: 330, height: 16)
        container.addSubview(hint)

        alert.accessoryView = container
        alert.window.initialFirstResponder = baseField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        AIService.shared.baseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AIService.shared.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AIService.shared.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = Double(tempField.stringValue) { AIService.shared.temperature = min(2, max(0, t)) }
        refreshModelLabel()
        AppState.shared.postStatus(AIService.shared.isConfigured ? "AI 设置已保存" : "AI 设置已保存（缺少 API Key）")
    }

    private func presentNotConfigured() {
        let alert = NSAlert()
        alert.messageText = "尚未配置 AI"
        alert.informativeText = "需要接口地址、模型名与 API Key。\n\n兼容 OpenAI、DeepSeek、Kimi、通义、Ollama 等任何 OpenAI 格式的服务。"
        alert.addButton(withTitle: "去设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    func focusInput() {
        view.window?.makeFirstResponder(inputView)
    }

    func quickReviewDiffAction() { quickReviewDiff() }
}

extension AIPanelViewController: NSTextViewDelegate {

    /// Enter sends, Shift+Enter inserts a newline so multi-line prompts are
    /// still possible. The send button deliberately has no key equivalent —
    /// otherwise the key-equivalent machinery swallows Return before the text
    /// view's delegate ever sees it.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView else { return false }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }

        let flags = (NSApp.currentEvent?.modifierFlags ?? [])
            .intersection(.deviceIndependentFlagsMask)
        guard shouldSend(forModifiers: flags) else {
            return false        // let AppKit insert a real newline
        }
        sendMessage()
        return true
    }

    /// Plain Return sends; Shift+Return inserts a newline so multi-line prompts
    /// remain possible.
    func shouldSend(forModifiers flags: NSEvent.ModifierFlags) -> Bool {
        !flags.contains(.shift)
    }
}

// MARK: - Lightweight markdown-ish styling

enum StyledText {

    /// Renders plain text, styling fenced code blocks and inline code.
    static func render(_ text: String, theme: Theme, baseFont: NSFont, monoFont: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2

        let base: [NSAttributedString.Key: Any] = [
            .font: baseFont, .foregroundColor: theme.text, .paragraphStyle: paragraph
        ]
        let codeParagraph = NSMutableParagraphStyle()
        codeParagraph.lineSpacing = 1
        codeParagraph.headIndent = 8
        codeParagraph.firstLineHeadIndent = 8
        let code: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: theme.text,
            .backgroundColor: theme.editorBackground,
            .paragraphStyle: codeParagraph
        ]

        var remainder = Substring(text)
        while let fenceStart = remainder.range(of: "```") {
            let before = remainder[remainder.startIndex..<fenceStart.lowerBound]
            output.append(NSAttributedString(string: String(before), attributes: base))

            let afterFence = remainder[fenceStart.upperBound...]
            guard let newline = afterFence.firstIndex(of: "\n") else {
                output.append(NSAttributedString(string: "```", attributes: base))
                return output
            }
            let body = afterFence[afterFence.index(after: newline)...]
            guard let fenceEnd = body.range(of: "```") else {
                output.append(NSAttributedString(string: String(body), attributes: code))
                return output
            }
            output.append(NSAttributedString(string: String(body[body.startIndex..<fenceEnd.lowerBound]),
                                             attributes: code))
            remainder = body[fenceEnd.upperBound...]
        }
        output.append(NSAttributedString(string: String(remainder), attributes: base))

        // Inline code: `like this`
        let full = output.string as NSString
        let regex = try? NSRegularExpression(pattern: "`([^`\n]+)`")
        if let regex {
            let matches = regex.matches(in: output.string, options: [], range: NSRange(location: 0, length: full.length))
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let inner = match.range(at: 1)
                let replacement = NSMutableAttributedString(string: full.substring(with: inner), attributes: [
                    .font: monoFont,
                    .foregroundColor: theme.constant,
                    .backgroundColor: theme.editorBackground
                ])
                output.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return output
    }
}
