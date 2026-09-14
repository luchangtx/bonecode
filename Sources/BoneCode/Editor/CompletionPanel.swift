import AppKit

/// Non-activating panel so the editor keeps keyboard focus while it is open.
final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CompletionRowView: NSView {
    var item: CompletionItem? { didSet { needsDisplay = true } }
    var rowIndex: Int = 0
    var isSelected: Bool = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let theme = ThemeManager.shared.current
        let h = bounds.height

        if isSelected {
            theme.accent.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
        }

        let fg = isSelected ? NSColor.white : theme.text
        let secondary = isSelected ? NSColor.white.withAlphaComponent(0.85) : theme.secondaryText

        // kind badge
        let badgeRect = NSRect(x: 9, y: (h - 14) / 2, width: 14, height: 14)
        let badgeColor = Self.color(for: item.kind, theme: theme)
        (isSelected ? NSColor.white.withAlphaComponent(0.25) : badgeColor.withAlphaComponent(0.18)).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3).fill()
        let badgeStr = NSAttributedString(string: item.kind.iconName, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: isSelected ? NSColor.white : badgeColor
        ])
        let bs = badgeStr.size()
        badgeStr.draw(at: NSPoint(x: badgeRect.midX - bs.width / 2, y: badgeRect.midY - bs.height / 2))

        // label
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: fg
        ]
        let label = NSAttributedString(string: item.label, attributes: labelAttrs)
        let labelSize = label.size()
        label.draw(at: NSPoint(x: 30, y: (h - labelSize.height) / 2))

        // detail, right aligned
        if let detail = item.detail, !detail.isEmpty {
            let detAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: secondary
            ]
            let det = NSAttributedString(string: detail, attributes: detAttrs)
            let ds = det.size()
            let x = bounds.width - ds.width - 10
            if x > 30 + labelSize.width + 8 {
                det.draw(at: NSPoint(x: x, y: (h - ds.height) / 2))
            }
        }
    }

    private static func color(for kind: CompletionKind, theme: Theme) -> NSColor {
        switch kind {
        case .keyword: return theme.keyword
        case .type: return theme.type
        case .function: return theme.function
        case .variable: return theme.text
        case .snippet: return theme.accent
        case .symbol: return theme.function
        case .constant: return theme.constant
        case .property: return theme.attribute
        case .module: return theme.tag
        }
    }
}

final class CompletionPanelController: NSWindowController {

    var onCommit: ((CompletionItem) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let container = NSView()
    private var items: [CompletionItem] = []
    private var selectedIndex = 0
    private(set) var isVisible = false

    var selectedItem: CompletionItem? {
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    init() {
        let panel = CompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        super.init(window: panel)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        guard let panel = window else { return }
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        panel.contentView = container

        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.allowsEmptySelection = false
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)

        applyTheme()
    }

    @objc private func themeChanged() { applyTheme(); tableView.reloadData() }

    private func applyTheme() {
        let t = ThemeManager.shared.current
        container.layer?.backgroundColor = t.panelBackground.cgColor
        container.layer?.borderColor = t.border.cgColor
        tableView.backgroundColor = t.panelBackground
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
    }

    // MARK: - Show / hide

    func show(items: [CompletionItem], at point: NSPoint, selectedIndex: Int) {
        guard let panel = window else { return }
        self.items = items
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)

        let rowH: CGFloat = 22
        let height = min(CGFloat(items.count) * rowH + 6, 300)
        let width: CGFloat = 400

        scrollView.frame = NSRect(x: 1, y: 1, width: width - 2, height: height - 2)

        var origin = NSPoint(x: point.x, y: point.y - height - 3)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.x + width > vf.maxX { origin.x = max(vf.minX + 4, vf.maxX - width - 4) }
            if origin.x < vf.minX { origin.x = vf.minX + 4 }
            if origin.y < vf.minY { origin.y = point.y + 4 }
            if origin.y + height > vf.maxY { origin.y = vf.maxY - height - 4 }
        }

        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        panel.orderFront(nil)
        isVisible = true
        tableView.scrollRowToVisible(self.selectedIndex)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        window?.orderOut(nil)
        items = []
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        selectedIndex = row
        onCommit?(items[row])
    }
}

extension CompletionPanelController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("CompletionRow")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? CompletionRowView) ?? {
            let v = CompletionRowView()
            v.identifier = id
            return v
        }()
        view.rowIndex = row
        view.isSelected = (row == selectedIndex)
        view.item = items[row]
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 { selectedIndex = row }
    }
}
