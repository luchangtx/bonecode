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
    /// The byte-order mark read from the file, written back verbatim on save.
    ///
    /// Kept as bytes rather than a flag because a UTF-16 file must get its own
    /// BOM back — writing the UTF-8 one would corrupt it.
    private var bom: Data?
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
        //
        // UTF-16 is only attempted when the file carries an explicit BOM.
        // `String(data:encoding:.utf16)` without one accepts almost any byte
        // sequence — a Mach-O header plus NUL padding decoded to 41 characters of
        // garbage, which then sailed past the binary check and reached the text
        // view. Requiring a BOM is both more correct and the reason the check
        // below can be trusted.
        var text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = Data([0xEF, 0xBB, 0xBF])
            text = String(data: data.dropFirst(3), encoding: .utf8)
            encoding = .utf8
        } else if data.starts(with: [0xFF, 0xFE]) {
            bom = Data([0xFF, 0xFE])
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            bom = Data([0xFE, 0xFF])
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
            encoding = .utf16BigEndian
        }
        if text == nil, let s = String(data: data, encoding: .utf8) {
            text = s
            encoding = .utf8
        }

        // Binary check **before** the Latin-1 fallback, which is the whole point:
        // `String(data:encoding:.isoLatin1)` maps every byte to a character and so
        // never fails. Falling through to it turned a JPEG into a screen of
        // mojibake instead of saying the file is not text.
        if text == nil,
           FileKind.classify(head: Data(data.prefix(512)), url: fileURL) == .binary {
            showPlaceholder(binaryMessage(data: data),
                            action: ("用系统默认应用打开", #selector(openWithDefaultApp(_:))))
            return
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
            showPlaceholder("无法识别文件编码。\n\n这个文件既不是有效的 UTF-8，也不是系统支持的其它文本编码。")
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

    /// Explains what a binary file actually is, so the user is not left staring
    /// at "not text" with no idea what to do next.
    private func binaryMessage(data: Data) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        var lines = ["这是二进制文件，不是文本，编辑器不打算把它显示成乱码。"]

        // Name the format when we recognise it, which is far more useful than
        // "binary". Files that reach this branch are ones the image preview did
        // not claim, so it is usually an archive, a compiled object, or media.
        let head = Array(data.prefix(8))
        let signature: String? = {
            if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "ZIP 压缩包（.zip/.jar/.docx/.xlsx 等）" }
            if head.starts(with: [0x1F, 0x8B]) { return "GZIP 压缩包" }
            if head.starts(with: [0x42, 0x5A, 0x68]) { return "BZIP2 压缩包" }
            if head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "XZ 压缩包" }
            if head.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { return "7-Zip 压缩包" }
            if head.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return "ELF 可执行文件" }
            if head.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || head.starts(with: [0xFE, 0xED, 0xFA, 0xCF])
                || head.starts(with: [0xCE, 0xFA, 0xED, 0xFE]) { return "Mach-O 可执行文件" }
            if head.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) { return "Java class 文件" }
            if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "PDF 文档" }
            if head.starts(with: [0x53, 0x51, 0x4C, 0x69]) { return "SQLite 数据库" }
            if head.starts(with: [0x00, 0x61, 0x73, 0x6D]) { return "WebAssembly 模块" }
            if head.starts(with: [0x49, 0x44, 0x33]) || head.starts(with: [0xFF, 0xFB]) { return "MP3 音频" }
            if head.count >= 12, head[4...7].elementsEqual(Array("ftyp".utf8)) { return "MP4 / 音视频容器" }
            if head.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return "Ogg 媒体文件" }
            if head.starts(with: [0x52, 0x49, 0x46, 0x46]), head.count >= 12,
               head[8...11].elementsEqual(Array("AVI ".utf8)) { return "AVI 视频" }
            return nil
        }()

        if let signature {
            lines.append("识别为：\(signature)　大小 \(size)")
        } else {
            lines.append("未能识别具体格式。大小 \(size)")
        }
        lines.append("")
        lines.append("想查看内容的话，可以用下方的按钮交给系统默认应用，"
                     + "或者在集成终端里用 xxd / file 等命令检查。")
        return lines.joined(separator: "\n")
    }

    /// Shows a centred message in place of the editor. `action` adds one button
    /// under it, for cases where there is an obvious next step.
    private func showPlaceholder(_ message: String,
                                 action: (title: String, selector: Selector)? = nil) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = Fonts.ui(size: 13)
        label.textColor = ThemeManager.shared.current.secondaryText
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])

        if let action {
            let button = HoverIconButton(frame: .zero)
            button.title = action.title
            button.font = Fonts.ui(size: 12)
            button.target = self
            button.action = action.selector
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
                button.heightAnchor.constraint(equalToConstant: 22)
            ])
        }
        loadError = message
    }

    /// Hand a file the editor cannot show over to the system.
    @objc func openWithDefaultApp(_ sender: Any?) {
        NSWorkspace.shared.open(fileURL)
    }

    @discardableResult
    func save() -> Bool {
        guard loadError == nil else { return true }
        var content = textView.string
        if lineEnding != "\n" {
            content = content.replacingOccurrences(of: "\n", with: lineEnding)
        }
        var data = Data()
        if let bom { data.append(bom) }
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
