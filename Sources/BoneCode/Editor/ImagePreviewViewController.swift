import AppKit

/// A read-only image tab.
///
/// Opening a `.jpg` used to dump its bytes into the text editor as mojibake,
/// because the loader's last-resort Latin-1 decode never fails. Images are now
/// routed here instead: the picture is shown scaled to fit, with the file's real
/// dimensions and size alongside it.
final class ImagePreviewViewController: NSViewController, EditorTabContent {

    let fileURL: URL
    private let image: NSImage?
    private let loadFailure: String?
    /// The real pixel dimensions. Exposed for assertions.
    let pixelSize: NSSize
    let byteSize: Int64

    /// True when the file decoded; false when the placeholder is showing.
    var hasImage: Bool { image != nil && loadFailure == nil }
    /// The failure text, when the file could not be decoded.
    var failureText: String? { loadFailure }
    /// What the header line reports, for assertions.
    var infoText: String { describe() }

    /// The view that actually paints the picture. Exposed so a test can render
    /// it in isolation: `NSView.draw(_:)` does not draw subviews, so rendering
    /// the whole hierarchy needs `cacheDisplay`, which is unreliable offscreen.
    var imageCanvas: NSView { canvas }

    private let scrollView = NSScrollView()
    private let canvas = ImageCanvasView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let bottomBar = NSView()

    private enum ZoomMode {
        case fit
        case actual
        case custom(CGFloat)
    }
    private var zoomMode: ZoomMode = .fit

    // MARK: - EditorTabContent

    var tabTitle: String { fileURL.lastPathComponent }
    var tabSubtitle: String? { "图片" }
    var tabURL: URL? { fileURL }
    var tabIsDirty: Bool { false }
    var tabIconName: String { FileIcons.symbolName(for: fileURL) }
    func saveIfNeeded() -> Bool { true }          // read-only, nothing to save
    func focusEditor() { view.window?.makeFirstResponder(canvas) }

    // MARK: - Init

    init(fileURL: URL) {
        self.fileURL = fileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        // `NSImage(contentsOf:)` is lazy; forcing a representation now tells us
        // straight away whether the file is really decodable.
        if let image = NSImage(contentsOf: fileURL), image.isValid,
           image.size.width > 0, image.size.height > 0 {
            self.image = image
            self.loadFailure = nil
            self.pixelSize = ImagePreviewViewController.pixelSize(of: image)
        } else {
            self.image = nil
            self.loadFailure = "无法解码这个图片文件。\n\n文件头看起来像图片，但内容已损坏，或者使用了系统不支持的编码（如某些 AVIF / HEIC 变体）。\n\n可用系统默认应用打开，或检查文件是否被 Git LFS 等工具替换成了指针文件。"
            self.pixelSize = .zero
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The real pixel dimensions, not the point size.
    ///
    /// `NSImage.size` is in points and respects the DPI recorded in the file, so
    /// a 3024×1964 screenshot reports 1512×982. Users compare against what Finder
    /// shows, which is pixels.
    private static func pixelSize(of image: NSImage) -> NSSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        canvas.image = image
        canvas.controller = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = canvas

        let bar = bottomBar
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.borderWidth = 1

        let buttons = NSStackView()
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 4

        for (title, selector, tip) in [
            ("−", #selector(zoomOut), "缩小"),
            ("＋", #selector(zoomIn), "放大"),
            ("适应窗口", #selector(zoomToFit), "缩放到刚好放得下"),
            ("实际大小", #selector(zoomToActual), "按 100% 显示")
        ] {
            let button = HoverIconButton(frame: .zero)
            button.title = title
            button.font = Fonts.ui(size: 11)
            button.target = self
            button.action = selector
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            // Wide enough for the two-word buttons, and every one the same so the
            // row does not jitter as the labels change.
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            buttons.addArrangedSubview(button)
        }

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = Fonts.ui(size: 11)
        zoomLabel.alignment = .right

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = Fonts.ui(size: 11)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bar.addSubview(buttons)
        bar.addSubview(infoLabel)
        bar.addSubview(zoomLabel)
        root.addSubview(scrollView)
        root.addSubview(bar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),

            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            zoomLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            zoomLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomLabel.leadingAnchor,
                                                constant: -12),
            infoLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        // Keep the picture centred when the panel is bigger than the image.
        canvas.onFitScaleChanged = { [weak self] in self?.refreshZoomLabel() }
        canvas.onScrollFrameChanged = { [weak self] in self?.recenterIfSmaller() }

        view = root
        canvas.controller = self
        infoLabel.stringValue = describe()
        canvas.setFailure(loadFailure)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayout() {
        super.viewDidLayout()
        recenterIfSmaller()
    }

    // MARK: - Zoom

    /// The scale that makes the whole image visible.
    var fitScale: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        let available = scrollView.contentSize
        guard available.width > 1, available.height > 1 else { return 1 }
        return min(available.width / pixelSize.width, available.height / pixelSize.height, 1)
    }

    var effectiveScale: CGFloat {
        switch zoomMode {
        case .fit: return fitScale
        case .actual: return 1
        case .custom(let value): return value
        }
    }

    private func setZoom(_ mode: ZoomMode) {
        zoomMode = mode
        canvas.scale = effectiveScale
        canvas.invalidateIntrinsicContentSize()
        canvas.needsLayout = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        recenterIfSmaller()
        refreshZoomLabel()
    }

    @objc func zoomIn() { setZoom(.custom(min(effectiveScale * 1.25, 16))) }
    @objc func zoomOut() { setZoom(.custom(max(effectiveScale / 1.25, 0.05))) }
    @objc func zoomToFit() { setZoom(.fit) }
    @objc func zoomToActual() { setZoom(.actual) }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        // A `where` clause on a multi-pattern case only binds to the last
        // pattern, so test the modifier once here instead of per case.
        if command {
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoomIn(); return
            case "-", "_": zoomOut(); return
            case "0": zoomToFit(); return
            case "1": zoomToActual(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// Centre the image when it is smaller than the viewport.
    private func recenterIfSmaller() {
        let viewport = scrollView.contentSize
        canvas.frame = NSRect(origin: .zero,
                              size: NSSize(width: max(canvas.contentSize.width, viewport.width),
                                           height: max(canvas.contentSize.height, viewport.height)))
        canvas.needsDisplay = true
    }

    // MARK: - Presentation

    private func describe() -> String {
        guard let image, loadFailure == nil else { return "无法预览" }
        let size = ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        let dimensions = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        let format = FileKind.describe(fileURL)
        let points = image.size
        // Mention the DPI-derived point size only when it differs, otherwise the
        // number looks like a contradiction next to the pixel dimensions.
        let suffix = abs(points.width - pixelSize.width) > 1
            ? String(format: "  ·  显示 %.0f × %.0f pt", points.width, points.height)
            : ""
        return "\(dimensions) px  ·  \(format)  ·  \(size)\(suffix)"
    }

    private func refreshZoomLabel() {
        guard loadFailure == nil else { zoomLabel.stringValue = ""; return }
        zoomLabel.stringValue = String(format: "%.0f%%", effectiveScale * 100)
        canvas.needsDisplay = true
    }

    @objc private func themeChanged() {
        applyTheme()
        canvas.needsDisplay = true
    }

    func applyTheme() {
        let theme = ThemeManager.shared.current
        view.setBackground(theme.editorBackground)
        scrollView.backgroundColor = theme.editorBackground
        infoLabel.textColor = theme.tertiaryText
        zoomLabel.textColor = theme.tertiaryText
        bottomBar.setBackground(theme.panelBackground)
        bottomBar.layer?.borderColor = theme.border.cgColor
        for case let button as HoverIconButton in bottomBar.subviews.flatMap({ $0.subviews }) {
            button.refreshAppearance()
        }
        canvas.needsDisplay = true
    }
}

/// Draws the image on a checkerboard so transparent PNGs are readable, and
/// centres it when there is room.
private final class ImageCanvasView: NSView {

    var image: NSImage?
    weak var controller: ImagePreviewViewController?
    var scale: CGFloat = 1
    var onFitScaleChanged: (() -> Void)?
    var onScrollFrameChanged: (() -> Void)?

    private var failureMessage: String?

    var contentSize: NSSize {
        guard let image else { return NSSize(width: 1, height: 1) }
        return NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setFailure(_ message: String?) { failureMessage = message }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.current
        theme.editorBackground.setFill()
        bounds.fill()

        guard let image else {
            drawFailure()
            return
        }

        let size = contentSize
        let origin = NSPoint(x: max(0, (bounds.width - size.width) / 2),
                             y: max(0, (bounds.height - size.height) / 2))
        let box = NSRect(origin: origin, size: size)

        drawCheckerboard(in: box)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        theme.border.setStroke()
        NSBezierPath(rect: box.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }

    private func drawFailure() {
        let theme = ThemeManager.shared.current
        let text = failureMessage ?? "无法预览这个文件。"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Fonts.ui(size: 12),
            .foregroundColor: theme.secondaryText
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.boundingRect(with: NSSize(width: min(420, bounds.width - 40),
                                                        height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin])
        attributed.draw(with: NSRect(x: max(20, (bounds.width - size.width) / 2),
                                     y: max(20, (bounds.height - size.height) / 2),
                                     width: size.width, height: size.height),
                        options: [.usesLineFragmentOrigin])
    }

    /// A fixed grey checkerboard: it is about "is this pixel transparent", not
    /// about the app theme, so it stays the same in light and dark mode.
    private func drawCheckerboard(in rect: NSRect) {
        let square: CGFloat = 8
        NSColor(white: 0.92, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var column = 0
            var x = rect.minX
            while x < rect.maxX {
                if (row + column) % 2 == 0 {
                    NSRect(x: x, y: y, width: min(square, rect.maxX - x),
                           height: min(square, rect.maxY - y)).fill()
                }
                x += square
                column += 1
            }
            y += square
            row += 1
        }
    }
}
