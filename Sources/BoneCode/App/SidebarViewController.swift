import AppKit

/// Left sidebar hosting the file tree, Git tool window and run configurations.
final class SidebarViewController: NSViewController {

    private let segmented = NSSegmentedControl()
    private let container = NSView()

    let fileTree = FileTreeViewController()
    let gitPanel = GitPanelViewController()
    let runPanel = RunPanelViewController()

    private var current = 0

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.sidebarBackground)

        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.segmentCount = 3
        segmented.setLabel("项目", forSegment: 0)
        segmented.setLabel("Git", forSegment: 1)
        segmented.setLabel("运行", forSegment: 2)
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.selectedSegment = 0
        segmented.controlSize = .small
        segmented.target = self
        segmented.action = #selector(sectionChanged)

        container.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(segmented)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            segmented.heightAnchor.constraint(equalToConstant: 22),

            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let children: [NSViewController] = [fileTree, gitPanel, runPanel]
        for (index, child) in children.enumerated() {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: container.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            child.view.isHidden = index != 0
        }

        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleGitPanel),
                                               name: .toggleGitPanel, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        view.setBackground(ThemeManager.shared.current.sidebarBackground)
    }

    @objc private func sectionChanged() {
        select(segmented.selectedSegment)
    }

    func select(_ index: Int) {
        current = max(0, min(2, index))
        segmented.selectedSegment = current
        let views = [fileTree.view, gitPanel.view, runPanel.view]
        for (i, sub) in views.enumerated() { sub.isHidden = i != current }
        if current == 1 { gitPanel.refreshNow() }
        if current == 2 { runPanel.reload() }
    }

    @objc private func toggleGitPanel() {
        select(current == 1 ? 0 : 1)
    }
}

// MARK: - Run panel

final class RunPanelViewController: NSViewController {

    private let summaryLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "打开一个项目后会自动识别可运行的配置")

    private var configs: [RunConfig] = []

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.sidebarBackground)

        summaryLabel.font = Fonts.ui(size: 10.5)
        summaryLabel.textColor = ThemeManager.shared.current.tertiaryText
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 3
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Fonts.ui(size: 11)
        emptyLabel.textColor = ThemeManager.shared.current.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView.horizontal(spacing: 5)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        let customButton = NSButton(title: "自定义命令…", target: self, action: #selector(addCustom))
        customButton.bezelStyle = .rounded
        customButton.controlSize = .small
        customButton.font = Fonts.ui(size: 10.5)
        let terminalButton = NSButton(title: "打开终端", target: self, action: #selector(openTerminal))
        terminalButton.bezelStyle = .rounded
        terminalButton.controlSize = .small
        terminalButton.font = Fonts.ui(size: 10.5)
        footerStack.addArrangedSubview(customButton)
        footerStack.addArrangedSubview(terminalButton)

        root.addSubview(summaryLabel)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footerStack)

        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            summaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            summaryLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -5),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 6),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -6),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -2),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])

        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(configsChanged),
                                               name: .runConfigsChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        let theme = ThemeManager.shared.current
        view.setBackground(theme.sidebarBackground)
        summaryLabel.textColor = theme.tertiaryText
        emptyLabel.textColor = theme.tertiaryText
        reload()
    }

    @objc private func configsChanged() { reload() }

    func reload() {
        configs = AppState.shared.runController?.configs ?? []
        summaryLabel.stringValue = AppState.shared.runController?.projectSummary ?? ""

        for sub in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        emptyLabel.isHidden = !configs.isEmpty
        guard !configs.isEmpty else { return }

        for config in configs {
            let row = RunConfigRowView(config: config)
            row.onRun = { [weak self] cfg in
                self?.runConfig(cfg)
            }
            row.onDelete = { [weak self] cfg in
                guard cfg.isCustom else { return }
                AppState.shared.runController?.removeCustomConfig(id: cfg.id)
                self?.reload()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func runConfig(_ config: RunConfig) {
        AppState.shared.runController?.run(config)
    }

    @objc private func openTerminal() {
        AppState.shared.terminalPanel?.newTerminal()
        NotificationCenter.default.post(name: .toggleTerminal, object: "show")
    }

    @objc private func addCustom() {
        let alert = NSAlert()
        alert.messageText = "新建运行配置"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 92))
        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(string: "")
        let commandLabel = NSTextField(labelWithString: "命令")
        let commandField = NSTextField(string: "")
        let dirLabel = NSTextField(labelWithString: "目录")
        let dirField = NSTextField(string: AppState.shared.workspaceRoot?.path ?? NSHomeDirectory())

        let rows: [(NSTextField, NSTextField, String)] = [
            (nameLabel, nameField, "例如 启动前端"),
            (commandLabel, commandField, "例如 npm run dev"),
            (dirLabel, dirField, "执行命令的工作目录")
        ]
        var y: CGFloat = 62
        for (label, field, placeholder) in rows {
            label.font = Fonts.ui(size: 11)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y, width: 56, height: 20)
            field.placeholderString = placeholder
            field.frame = NSRect(x: 62, y: y, width: 330, height: 22)
            container.addSubview(label)
            container.addSubview(field)
            y -= 30
        }

        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return }
        let config = RunConfig.make(
            id: "custom-\(UUID().uuidString.prefix(8))",
            name: name,
            command: command,
            directory: dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: "自定义",
            symbol: "wrench.and.screwdriver",
            custom: true
        )
        AppState.shared.runController?.addCustomConfig(config)
        reload()
    }
}

// MARK: - Run config row

private final class RunConfigRowView: NSView {

    let config: RunConfig
    var onRun: ((RunConfig) -> Void)?
    var onDelete: ((RunConfig) -> Void)?

    private let hoverLayer = CALayer()

    init(config: RunConfig) {
        self.config = config
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 5

        let icon = NSImageView()
        icon.image = Icons.symbol(config.symbolName, size: 12)
        icon.contentTintColor = ThemeManager.shared.current.accent
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: config.name)
        name.font = Fonts.ui(size: 11.5, weight: .medium)
        name.textColor = ThemeManager.shared.current.text
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let kind = NSTextField(labelWithString: config.kind + (config.detectedPort.map { " · 端口 \($0)" } ?? ""))
        kind.font = Fonts.ui(size: 9.5)
        kind.textColor = ThemeManager.shared.current.tertiaryText
        kind.translatesAutoresizingMaskIntoConstraints = false

        let runButton = NSButton(title: "", target: self, action: #selector(runTapped))
        runButton.isBordered = false
        runButton.bezelStyle = .inline
        runButton.image = Icons.symbol("play.fill", size: 10)
        runButton.contentTintColor = ThemeManager.shared.current.diffAddedText
        runButton.toolTip = "运行"
        runButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(name)
        addSubview(kind)
        addSubview(runButton)

        if config.isCustom {
            let deleteButton = NSButton(title: "", target: self, action: #selector(deleteTapped))
            deleteButton.isBordered = false
            deleteButton.bezelStyle = .inline
            deleteButton.image = Icons.symbol("trash", size: 10)
            deleteButton.contentTintColor = ThemeManager.shared.current.tertiaryText
            deleteButton.toolTip = "删除此配置"
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(deleteButton)
            NSLayoutConstraint.activate([
                deleteButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -2),
                deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                deleteButton.widthAnchor.constraint(equalToConstant: 18)
            ])
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -4),

            kind.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            kind.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            kind.trailingAnchor.constraint(lessThanOrEqualTo: runButton.leadingAnchor, constant: -4),

            runButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            runButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            runButton.widthAnchor.constraint(equalToConstant: 20)
        ])
    }

    @objc private func runTapped() { onRun?(config) }
    @objc private func deleteTapped() { onDelete?(config) }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = ThemeManager.shared.current.hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
