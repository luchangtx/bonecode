import AppKit

/// Anything that can live in the editor area as a tab.
protocol EditorTabContent: AnyObject {
    var tabTitle: String { get }
    var tabSubtitle: String? { get }
    var tabURL: URL? { get }
    var tabIsDirty: Bool { get }
    var tabIconName: String { get }
    /// Returns false when the user cancels a save prompt.
    func saveIfNeeded() -> Bool
    func focusEditor()
}

/// One open file.
final class CodeEditorViewController: NSViewController, EditorTabContent {

    let fileURL: URL
    private(set) var isDirty = false

    private(set) var textView: CodeTextView!
    private var scrollView: NSScrollView!
    private var ruler: LineNumberRulerView!
    private var loadError: String?
    private var hasBOM = false
    private var lineEnding = "\n"
    private var encoding: String.Encoding = .utf8
    private let styleDebouncer = Debouncer(delay: 0.05)

    var onDirtyStateChange: ((Bool) -> Void)?
    var onSelectionChange: (() -> Void)?

    var tabTitle: String { fileURL.lastPathComponent }
    var tabSubtitle: String? { fileURL.deletingLastPathComponent().path.abbreviatedPath(maxComponents: 2) }
    var tabURL: URL? { fileURL }
    var tabIsDirty: Bool { isDirty }
    var tabIconName: String { FileIcons.symbolName(for: fileURL) }

    var language: Language { textView?.language ?? .plain }

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !EditorSettings.shared.wrapLines
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tv = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = EditorSettings.shared.wrapLines
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.fileURL = fileURL
        tv.language = LanguageRegistry.language(forPath: fileURL.path)
        scroll.documentView = tv

        let ruler = LineNumberRulerView(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = EditorSettings.shared.showLineNumbers
        scroll.rulersVisible = EditorSettings.shared.showLineNumbers

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.scrollView = scroll
        self.textView = tv
        self.ruler = ruler
        self.view = container

        tv.onTextChange = { [weak self] in
            guard let self else { return }
            if !self.isDirty {
                self.isDirty = true
                self.onDirtyStateChange?(true)
            }
        }
        tv.onSelectionChange = { [weak self] in
            self?.onSelectionChange?()
            self?.ruler.needsDisplay = true
        }

        loadContent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeChanged() {
        textView.applyTheme()
        textView.rehighlight()
        ruler.needsDisplay = true
        scrollView.backgroundColor = ThemeManager.shared.current.editorBackground
    }

    @objc private func scrollViewDidScroll() {
        styleDebouncer.schedule { [weak self] in
            self?.textView.applyStyling()
            self?.ruler.needsDisplay = true
        }
    }

    // MARK: - Load / save

    private func loadContent() {
        let path = fileURL.path
        let size = FileManager.default.fileSize(at: path)
        let limit = 12 * 1024 * 1024

        guard size <= limit else {
            showPlaceholder("文件过大（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))），已超出编辑器处理范围。\n\n可用集成终端打开：cat 查看，或使用系统默认应用。")
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            showPlaceholder("无法读取文件。")
            return
        }

        if data.isEmpty {
            applyLoadedText("")
            return
        }

        // Encoding detection, most specific first.
        var text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            text = String(data: data.dropFirst(3), encoding: .utf8)
            encoding = .utf8
        }
        if text == nil, let s = String(data: data, encoding: .utf8) {
            text = s
            encoding = .utf8
        }
        if text == nil, let s = String(data: data, encoding: .utf16) {
            text = s
            encoding = .utf16
        }
        if text == nil, let s = String(data: data, encoding: .isoLatin1) {
            text = s
            encoding = .isoLatin1
        }
        if text == nil, let s = String(data: data, encoding: .shiftJIS) {
            text = s
            encoding = .shiftJIS
        }

        guard var content = text else {
            showPlaceholder("无法识别文件编码，可能是二进制文件。")
            return
        }

        if content.contains("\r\n") { lineEnding = "\r\n"; content = content.replacingOccurrences(of: "\r\n", with: "\n") }
        else if content.contains("\r") { lineEnding = "\r"; content = content.replacingOccurrences(of: "\r", with: "\n") }

        applyLoadedText(content)
    }

    private func applyLoadedText(_ text: String) {
        textView.string = text
        textView.applyTheme()
        textView.updateParagraphStyle()
        textView.rehighlight()
        isDirty = false
        scrollView.backgroundColor = ThemeManager.shared.current.editorBackground
        ruler.needsDisplay = true
    }

    private func showPlaceholder(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = Fonts.ui(size: 13)
        label.textColor = ThemeManager.shared.current.secondaryText
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        loadError = message
    }

    @discardableResult
    func save() -> Bool {
        guard loadError == nil else { return true }
        var content = textView.string
        if lineEnding != "\n" {
            content = content.replacingOccurrences(of: "\n", with: lineEnding)
        }
        var data = Data()
        if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        guard let encoded = content.data(using: encoding) ?? content.data(using: .utf8) else { return false }
        data.append(encoded)

        do {
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
            onDirtyStateChange?(false)
            NotificationCenter.default.post(name: .editorDidSave, object: fileURL)
            return true
        } catch {
            presentSaveError(error)
            return false
        }
    }

    private func presentSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "保存失败"
        alert.informativeText = "\(fileURL.path)\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func saveIfNeeded() -> Bool {
        guard isDirty else { return true }
        return save()
    }

    func focusEditor() {
        view.window?.makeFirstResponder(textView)
    }

    func reloadFromDisk() {
        guard !isDirty else { return }
        loadContent()
    }

    // MARK: - Editing helpers used by menus

    func toggleComment() { textView.toggleComment() }
    func duplicateLine() { textView.duplicateSelection() }
    func deleteLine() { textView.deleteLines() }
    func moveLine(up: Bool) { textView.moveLines(up: up) }
    func indent() { textView.indentSelection() }
    func outdent() { textView.outdentSelection() }
    func formatSelection() { textView.formatSelectionAction() }
    func gotoLine(_ n: Int) { textView.gotoLine(n) }
    func requestCompletions() { textView.showCompletions(explicit: true) }
    func findInFile() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
}
