import AppKit

// MARK: - Editor tab commands

/// Commands offered by the editor tab context menu.
enum EditorTabAction {
    case close
    case closeOthers
    case closeToRight
    case closeAll
    case copyPath
    case revealInFinder
    case reloadFromDisk
    case openInTerminal
}

/// Hand-drawn tab strip lives in `TabStripView` (Util/TabStripView.swift), shared
/// with the terminal panel. Only the editor-specific menu commands stay here.

extension FileIcons {
    /// The tab bar stores a symbol name, but we want the colour of the file it
    /// represents; recover a reasonable colour from the symbol itself.
    static func color(forName symbol: String, theme: Theme) -> NSColor {
        switch symbol {
        case "swift": return theme.diffRemovedText
        case "globe": return theme.tag
        case "paintbrush": return theme.accent
        case "gearshape": return theme.tertiaryText
        case "doc.richtext", "doc.text": return theme.secondaryText
        case "terminal": return theme.diffAddedText
        case "shippingbox": return theme.annotation
        case "cylinder": return theme.type
        case "arrow.triangle.branch": return theme.accent
        case "plusminus.circle": return theme.constant
        case "hammer": return theme.diffAddedText
        case "photo": return theme.constant
        default: return theme.function
        }
    }
}

// MARK: - Editor area

final class EditorAreaController: NSViewController {

    private let tabBar = TabStripView()
    private let container = NSView()
    private var contents: [EditorTabContent] = []
    private var currentIndex: Int = -1
    private var welcomeView: WelcomeView?

    var onTabsChanged: (() -> Void)?

    var currentContent: EditorTabContent? {
        guard currentIndex >= 0, currentIndex < contents.count else { return nil }
        return contents[currentIndex]
    }

    var currentCodeEditor: CodeEditorViewController? {
        currentContent as? CodeEditorViewController
    }

    var openEditors: [CodeEditorViewController] {
        contents.compactMap { $0 as? CodeEditorViewController }
    }

    var openFileURLs: [URL] {
        contents.compactMap { $0.tabURL }
    }

    /// The shared tab strip. Exposed so tests can assert the editor and the
    /// terminal really do use the same component.
    var tabStripView: TabStripView { tabBar }

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.setBackground(ThemeManager.shared.current.editorBackground)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        container.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(tabBar)
        root.addSubview(container)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Metrics.tabHeight),

            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        showWelcome()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        view.setBackground(ThemeManager.shared.current.editorBackground)
        tabBar.needsDisplay = true
        welcomeView?.applyTheme()
    }

    // MARK: Tabs

    private func rebuildTabBar() {
        tabBar.items = contents.map {
            TabStripView.Item(title: $0.tabTitle,
                              iconName: $0.tabIconName,
                              showsDot: $0.tabIsDirty)
        }
        tabBar.selectedIndex = currentIndex
        tabBar.needsDisplay = true
        onTabsChanged?()
        NotificationCenter.default.post(name: .activeEditorDidChange, object: currentContent)
    }

    private func install(_ content: EditorTabContent, at index: Int) {
        guard let vc = content as? NSViewController else { return }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func select(_ index: Int) {
        guard index >= 0, index < contents.count else { return }
        hideWelcome()
        currentIndex = index
        for (i, content) in contents.enumerated() {
            guard let vc = content as? NSViewController else { continue }
            vc.view.isHidden = (i != index)
        }
        rebuildTabBar()
        tabBar.scrollToSelected()
        contents[index].focusEditor()
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < contents.count else { return }
        let content = contents[index]
        guard content.saveIfNeeded() else { return }

        if let vc = content as? NSViewController {
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }
        contents.remove(at: index)

        if contents.isEmpty {
            currentIndex = -1
            showWelcome()
            rebuildTabBar()
        } else if index <= currentIndex {
            currentIndex = min(currentIndex - 1, contents.count - 1)
            select(max(0, currentIndex))
        } else {
            rebuildTabBar()
        }
    }

    func closeCurrentTab() {
        guard currentIndex >= 0 else { return }
        closeTab(at: currentIndex)
    }

    func closeAllTabs() {
        for content in contents { _ = content.saveIfNeeded() }
        for content in contents {
            if let vc = content as? NSViewController {
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }
        contents.removeAll()
        currentIndex = -1
        showWelcome()
        rebuildTabBar()
    }

    func selectNextTab() {
        guard contents.count > 1 else { return }
        select((currentIndex + 1) % contents.count)
    }

    func selectPreviousTab() {
        guard contents.count > 1 else { return }
        select((currentIndex - 1 + contents.count) % contents.count)
    }

    func selectTab(at index: Int) {
        select(index)
    }

    func selectTab(for url: URL) {
        if let idx = contents.firstIndex(where: { $0.tabURL?.path == url.path }) {
            select(idx)
        }
    }

    // MARK: Opening

    @discardableResult
    func open(url: URL) -> CodeEditorViewController? {
        let normalized = url.standardizedFileURL

        if let idx = contents.firstIndex(where: { $0.tabURL?.path == normalized.path }) {
            select(idx)
            return contents[idx] as? CodeEditorViewController
        }

        // Images get a preview tab, not the text editor. Deciding by content
        // rather than extension means a PNG called `blob.dat` also previews, and
        // a Git LFS pointer called `photo.png` still opens as text.
        if FileKind.detect(url: normalized) == .image {
            openImageTab(normalized)
            return nil
        }

        let editor = CodeEditorViewController(fileURL: normalized)
        _ = editor.view  // force loadView so the text is read
        editor.onDirtyStateChange = { [weak self] _ in
            self?.rebuildTabBar()
        }
        editor.onSelectionChange = { [weak self] in
            NotificationCenter.default.post(name: .activeEditorDidChange, object: self?.currentContent)
        }

        contents.append(editor)
        install(editor, at: contents.count - 1)
        select(contents.count - 1)
        RecentProjects.shared.noteFile(normalized)
        return editor
    }

    /// Open an image as its own tab, reusing the existing one when possible.
    func openImageTab(_ url: URL) {
        if let idx = contents.firstIndex(where: { $0.tabURL?.path == url.path }) {
            select(idx)
            return
        }
        let preview = ImagePreviewViewController(fileURL: url)
        _ = preview.view
        contents.append(preview)
        install(preview, at: contents.count - 1)
        select(contents.count - 1)
        RecentProjects.shared.noteFile(url)
    }

    /// Open a parsed diff as its own tab, reusing an existing one when possible.
    func openDiffTab(_ request: DiffRequest) {
        if let idx = contents.firstIndex(where: {
            $0 is DiffViewController && $0.tabTitle == request.title && $0.tabSubtitle == request.subtitle
        }) {
            select(idx)
            return
        }
        let vc = DiffViewController(diffs: request.diffs, title: request.title, subtitle: request.subtitle)
        _ = vc.view
        contents.append(vc)
        install(vc, at: contents.count - 1)
        select(contents.count - 1)
    }

    /// Open an arbitrary read-only text tab (diffs, blame output, AI results).
    func openTextTab(title: String, subtitle: String?, text: String,
                     languageID: String?, iconName: String = "plusminus.circle") {
        let viewer = TextTabViewController(title: title, subtitle: subtitle,
                                           text: text, languageID: languageID,
                                           iconName: iconName)
        _ = viewer.view
        contents.append(viewer)
        install(viewer, at: contents.count - 1)
        select(contents.count - 1)
    }

    func reloadCurrentFromDisk() {
        currentCodeEditor?.reloadFromDisk()
    }

    func saveCurrent() {
        _ = currentContent?.saveIfNeeded()
        rebuildTabBar()
    }

    func saveAll() {
        for content in contents { _ = content.saveIfNeeded() }
        rebuildTabBar()
    }

    var hasDirtyTabs: Bool { contents.contains { $0.tabIsDirty } }

    func promptSaveAllIfNeeded() -> Bool {
        let dirty = contents.filter { $0.tabIsDirty }
        guard !dirty.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "有 \(dirty.count) 个文件尚未保存"
        alert.informativeText = dirty.map { "• \($0.tabTitle)" }.joined(separator: "\n")
        alert.addButton(withTitle: "全部保存")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for c in dirty where !c.saveIfNeeded() { return false }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Welcome

    private func showWelcome() {
        if welcomeView == nil {
            let w = WelcomeView()
            w.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(w)
            NSLayoutConstraint.activate([
                w.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                w.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                w.topAnchor.constraint(equalTo: container.topAnchor),
                w.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            welcomeView = w
        }
        welcomeView?.isHidden = false
        tabBar.isHidden = contents.isEmpty
    }

    private func hideWelcome() {
        welcomeView?.isHidden = true
        tabBar.isHidden = false
    }
}

extension EditorAreaController: TabStripViewDelegate {

    func tabStrip(_ strip: TabStripView, didSelect index: Int) { select(index) }

    func tabStrip(_ strip: TabStripView, didClose index: Int) { closeTab(at: index) }

    /// Build the context menu here rather than in the strip, so the shared view
    /// stays ignorant of what a tab means.
    func tabStrip(_ strip: TabStripView, menuFor index: Int) -> NSMenu? {
        guard index >= 0, index < contents.count else { return nil }
        let hasOthers = contents.count > 1
        let hasRight = index < contents.count - 1
        let entries: [(String, EditorTabAction, Bool)] = [
            ("关闭", .close, true),
            ("关闭其他标签页", .closeOthers, hasOthers),
            ("关闭右侧标签页", .closeToRight, hasRight),
            ("关闭所有标签页", .closeAll, hasOthers),
            ("", .close, false),
            ("复制完整路径", .copyPath, true),
            ("在 Finder 中显示", .revealInFinder, true),
            ("重新从磁盘加载", .reloadFromDisk, true),
            ("在终端中打开所在目录", .openInTerminal, true)
        ]
        let menu = NSMenu()
        for (title, action, enabled) in entries {
            if title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(editorTabMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = EditorTabMenuPayload(action: action, index: index)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    @objc private func editorTabMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? EditorTabMenuPayload else { return }
        performEditorTabAction(payload.action, on: payload.index)
    }

    /// `NSMenuItem.representedObject` has to be an object, so the enum plus the
    /// index travel together in this box.
    private final class EditorTabMenuPayload: NSObject {
        let action: EditorTabAction
        let index: Int
        init(action: EditorTabAction, index: Int) {
            self.action = action
            self.index = index
        }
    }

    func performEditorTabAction(_ action: EditorTabAction, on index: Int) {
        guard index >= 0, index < contents.count else { return }
        switch action {
        case .close:
            closeTab(at: index)
        case .closeOthers:
            closeTabs(keeping: index)
        case .closeToRight:
            closeTabs(after: index)
        case .closeAll:
            closeAllTabs()
        case .copyPath:
            guard let url = contents[index].tabURL else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
            AppState.shared.postStatus("已复制路径")
        case .revealInFinder:
            guard let url = contents[index].tabURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .reloadFromDisk:
            (contents[index] as? CodeEditorViewController)?.reloadFromDisk()
            AppState.shared.postStatus("已从磁盘重新加载")
        case .openInTerminal:
            guard let url = contents[index].tabURL else { return }
            NotificationCenter.default.post(name: .toggleTerminal, object: "show")
            NotificationCenter.default.post(name: .terminalSendText,
                                            object: "cd \"\(url.deletingLastPathComponent().path)\"\n")
        }
    }

    /// Close every tab except `index`.
    func closeTabs(keeping index: Int) {
        guard contents.count > 1, index >= 0, index < contents.count else { return }
        let doomed = contents.enumerated().filter { $0.offset != index }.map { $0.element }
        guard confirmClosing(doomed) else { return }
        let kept = contents[index]
        for content in doomed { detach(content) }
        contents = [kept]
        currentIndex = 0
        select(0)
    }

    /// Close every tab to the right of `index`.
    func closeTabs(after index: Int) {
        guard index >= 0, index < contents.count - 1 else { return }
        let doomed = Array(contents[(index + 1)...])
        guard confirmClosing(doomed) else { return }
        for content in doomed { detach(content) }
        contents.removeSubrange((index + 1)...)
        if currentIndex > index { currentIndex = index }
        select(min(currentIndex, contents.count - 1))
    }

    private func detach(_ content: EditorTabContent) {
        guard let vc = content as? NSViewController else { return }
        vc.view.removeFromSuperview()
        vc.removeFromParent()
    }

    /// One prompt for the whole batch, so a partial close cannot happen.
    private func confirmClosing(_ doomed: [EditorTabContent]) -> Bool {
        let dirty = doomed.filter { $0.tabIsDirty }
        guard !dirty.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "有 \(dirty.count) 个文件尚未保存"
        alert.informativeText = dirty.map { "• \($0.tabTitle)" }.joined(separator: "\n")
        alert.addButton(withTitle: "全部保存")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for content in dirty where !content.saveIfNeeded() { return false }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - Read-only text tab

final class TextTabViewController: NSViewController, EditorTabContent {

    private let text: String
    private let languageID: String?
    private let iconName: String
    private let subtitleText: String?

    init(title: String, subtitle: String?, text: String, languageID: String?, iconName: String) {
        self.text = text
        self.languageID = languageID
        self.iconName = iconName
        self.subtitleText = subtitle
        self.titleOverride = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private let titleOverride: String

    var tabTitle: String { titleOverride }
    var tabSubtitle: String? { subtitleText }
    var tabURL: URL? { nil }
    var tabIsDirty: Bool { false }
    var tabIconName: String { iconName }

    func saveIfNeeded() -> Bool { true }
    func focusEditor() {}

    override func loadView() {
        let container = NSView()
        container.setBackground(ThemeManager.shared.current.editorBackground)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tv = CodeTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        tv.isEditable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.language = LanguageRegistry.language(forID: languageID ?? "plain")
        tv.applyTheme()
        tv.rehighlight()
        scroll.documentView = tv

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }
}

// MARK: - Hoverable list row

/// A borderless button gives no affordance whatsoever — users cannot tell it is
/// interactive. This one highlights on hover and shows a pointing-hand cursor.
final class HoverRowButton: NSButton {

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            layer?.backgroundColor = isHovered
                ? ThemeManager.shared.current.hover.cgColor
                : NSColor.clear.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Welcome screen

final class WelcomeView: NSView {

    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var buttons: [NSButton] = []
    private var shortcutLabels: [NSTextField] = []
    private var recentTitle: NSTextField!
    private var recentStack: NSStackView!

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        titleLabel = NSTextField(labelWithString: "BoneCode")
        titleLabel.font = Fonts.ui(size: 34, weight: .bold)
        titleLabel.alignment = .center

        subtitleLabel = NSTextField(labelWithString: "原生 · 轻量 · 面向 AI 的代码编辑器")
        subtitleLabel.font = Fonts.ui(size: 13)
        subtitleLabel.alignment = .center

        let openButton = makeButton("打开文件夹…", symbol: "folder", action: #selector(openFolder))
        let newFileButton = makeButton("新建文件", symbol: "doc.badge.plus", action: #selector(newFile))
        buttons = [openButton, newFileButton]
        let buttonRow = NSStackView.horizontal(spacing: 12)
        buttonRow.addArrangedSubview(openButton)
        buttonRow.addArrangedSubview(newFileButton)
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillEqually

        let shortcuts: [(String, String)] = [
            ("⌘⇧O", "打开文件夹"),
            ("⌘O", "打开文件"),
            ("⌘S", "保存文件"),
            ("⌘⇧S", "全部保存"),
            ("⌘P", "快速打开文件"),
            ("⌃Space", "代码补全"),
            ("⌘/", "切换注释"),
            ("⌘F", "查找"),
            ("⌘⇧F", "全局搜索"),
            ("⌘`", "切换终端"),
            ("⌘⇧G", "Git 面板"),
            ("⌘⇧A", "AI 助手")
        ]
        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 14
        let keyFont = Fonts.code(size: 11)
        let descFont = Fonts.ui(size: 11.5)
        for (key, desc) in shortcuts {
            let k = NSTextField(labelWithString: key)
            k.font = keyFont
            k.alignment = .right
            let d = NSTextField(labelWithString: desc)
            d.font = descFont
            shortcutLabels.append(contentsOf: [k, d])
            grid.addRow(with: [k, d])
        }

        // Size both columns explicitly instead of trusting the grid's automatic
        // sizing. Left to itself the grid collapses to about 80 pt inside this
        // stack view — roughly two thirds of what it needs — which clipped the
        // key column mid-glyph: `⌃Space` rendered as `⌃Spa`, with no ellipsis,
        // while the description beside it looked fine. Fixed widths also stop a
        // narrow window from silently truncating the list.
        func widest(_ values: [String], _ font: NSFont) -> CGFloat {
            values.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
                .max() ?? 0
        }
        grid.column(at: 0).width = max(44, widest(shortcuts.map { $0.0 }, keyFont))
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = widest(shortcuts.map { $0.1 }, descFont)

        recentTitle = NSTextField(labelWithString: "最近打开")
        recentTitle.font = Fonts.ui(size: 12, weight: .semibold)

        recentStack = NSStackView.vertical(spacing: 4)
        recentStack.alignment = .leading

        let column = NSStackView.vertical(spacing: 18)
        column.alignment = .centerX
        column.addArrangedSubview(titleLabel)
        column.addArrangedSubview(subtitleLabel)
        column.addArrangedSubview(buttonRow)
        column.setCustomSpacing(26, after: buttonRow)
        column.addArrangedSubview(grid)
        column.setCustomSpacing(26, after: grid)
        column.addArrangedSubview(recentTitle)
        column.addArrangedSubview(recentStack)

        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])

        // Fixed widths, required. Combined with a low compression resistance on
        // the row titles below, a long file name truncates instead of stretching
        // the recent list — and with it the whole centre column, which used to
        // push the right-hand panel off the edge of the window.
        buttonRow.widthAnchor.constraint(equalToConstant: 300).isActive = true
        recentStack.widthAnchor.constraint(equalToConstant: 360).isActive = true

        applyTheme()
        reloadRecent()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        applyTheme()
        reloadRecent()      // rows are rebuilt with theme colours
    }

    func applyTheme() {
        let theme = ThemeManager.shared.current
        titleLabel.textColor = theme.text
        subtitleLabel.textColor = theme.secondaryText
        recentTitle.textColor = theme.secondaryText
        for label in shortcutLabels {
            label.textColor = theme.secondaryText
        }
        for button in buttons {
            button.contentTintColor = theme.accent
        }
    }

    private func reloadRecent() {
        for v in recentStack.arrangedSubviews { recentStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let recents = RecentProjects.shared.recentItems.prefix(6)
        if recents.isEmpty {
            let empty = NSTextField(labelWithString: "暂无记录")
            empty.font = Fonts.ui(size: 11)
            empty.textColor = ThemeManager.shared.current.tertiaryText
            recentStack.addArrangedSubview(empty)
            return
        }
        let theme = ThemeManager.shared.current
        for item in recents {
            let button = HoverRowButton(title: "", target: self, action: #selector(recentClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.path)
            button.toolTip = item.path + "\n点击打开"
            button.image = Icons.symbol(item.isDirectory ? "folder" : "doc.text", size: 11)
            button.imagePosition = .imageLeading
            button.contentTintColor = item.isDirectory ? theme.accent : theme.secondaryText

            let name = (item.path as NSString).lastPathComponent
            let parent = (item.path as NSString).deletingLastPathComponent
                .abbreviatedPath(maxComponents: 2)
            let title = NSMutableAttributedString(string: name + "   ", attributes: [
                .font: Fonts.ui(size: 11.5),
                .foregroundColor: theme.text
            ])
            title.append(NSAttributedString(string: parent, attributes: [
                .font: Fonts.ui(size: 10),
                .foregroundColor: theme.tertiaryText
            ]))
            button.attributedTitle = title
            // A long file name must truncate, not widen the list. Without this
            // the title's intrinsic width wins and the whole column grows.
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.cell?.lineBreakMode = .byTruncatingMiddle

            button.translatesAutoresizingMaskIntoConstraints = false
            recentStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalTo: recentStack.widthAnchor),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: " " + title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = Fonts.ui(size: 12, weight: .medium)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let image = Icons.symbol(symbol, size: 12) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        return button
    }

    @objc private func openFolder() {
        NotificationCenter.default.post(name: .welcomeOpenFolder, object: nil)
    }

    @objc private func newFile() {
        NotificationCenter.default.post(name: .welcomeNewFile, object: nil)
    }

    @objc private func recentClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NotificationCenter.default.post(name: .welcomeOpenPath, object: path)
    }
}

// MARK: - Recent items

struct RecentItem {
    let path: String
    let isDirectory: Bool
    var display: String {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return "\(name)   \(parent.abbreviatedPath(maxComponents: 2))"
    }
}

final class RecentProjects {
    static let shared = RecentProjects()
    private let key = "recentItems"

    private(set) var recentItems: [RecentItem] = []

    private init() {
        load()
    }

    private func load() {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        recentItems = raw.compactMap { dict in
            guard let path = dict["path"] as? String else { return nil }
            return RecentItem(path: path, isDirectory: (dict["dir"] as? Bool) ?? false)
        }
    }

    private func persist() {
        let raw: [[String: Any]] = recentItems.map { ["path": $0.path, "dir": $0.isDirectory] }
        UserDefaults.standard.set(raw, forKey: key)
    }

    private func push(_ item: RecentItem) {
        recentItems.removeAll { $0.path == item.path }
        recentItems.insert(item, at: 0)
        if recentItems.count > 12 { recentItems = Array(recentItems.prefix(12)) }
        persist()
    }

    func noteFolder(_ url: URL) { push(RecentItem(path: url.path, isDirectory: true)) }
    func noteFile(_ url: URL) { push(RecentItem(path: url.path, isDirectory: false)) }
    func clear() { recentItems.removeAll(); persist() }
}
