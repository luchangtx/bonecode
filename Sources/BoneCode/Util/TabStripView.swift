import AppKit

/// Events a tab strip reports. The owner builds its own context menu, so the
/// strip does not need to know what a tab *means*.
protocol TabStripViewDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelect index: Int)
    func tabStrip(_ strip: TabStripView, didClose index: Int)
    /// Return the right-click menu for a tab, or nil for no menu.
    func tabStrip(_ strip: TabStripView, menuFor index: Int) -> NSMenu?
}

/// A hand-drawn, scrollable tab strip with a close button on every tab.
///
/// Shared by the editor area and the terminal panel. A stack of `NSButton`s would
/// need a lot of layout code and still would not match the IDEA-like look, and
/// `NSSegmentedControl` — which the terminal panel used originally — cannot draw
/// a close affordance per segment at all, which is why terminal tabs could not be
/// closed.
final class TabStripView: NSView {

    struct Item {
        let title: String
        let iconName: String
        /// Status dot drawn **before the title**: unsaved changes, or a live
        /// process. Deliberately not drawn in the close-button slot — that hid
        /// the × exactly when the tab most needed one.
        let showsDot: Bool
        /// Colour for the dot. Defaults to the secondary text colour.
        let dotColor: NSColor?

        init(title: String, iconName: String, showsDot: Bool = false,
             dotColor: NSColor? = nil) {
            self.title = title
            self.iconName = iconName
            self.showsDot = showsDot
            self.dotColor = dotColor
        }
    }

    var items: [Item] = [] {
        didSet {
            if selectedIndex >= items.count { selectedIndex = items.count - 1 }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var selectedIndex: Int = -1 {
        didSet { needsDisplay = true }
    }

    weak var delegate: TabStripViewDelegate?

    /// Terminal tabs are label-only: an identical icon on every tab is noise, and
    /// the width is better spent on the title.
    var showsIcon: Bool = true
    /// Show the close button on every tab rather than only on hover/selection.
    /// Used where tabs are transient and the user needs to see how to get rid of
    /// one without hunting for it.
    var alwaysShowsCloseButton: Bool = false
    /// Slightly tighter metrics, for a strip that shares a row with other controls.
    var isCompact: Bool = false
    var onDoubleClick: ((Int) -> Void)?

    private var scrollOffset: CGFloat = 0
    private var tabRects: [NSRect] = []
    private var closeRects: [NSRect] = []
    private var hoverIndex: Int = -1
    private var trackingArea: NSTrackingArea?

    private var minTabWidth: CGFloat { isCompact ? 84 : 110 }
    private var maxTabWidth: CGFloat { isCompact ? 190 : 230 }
    private var iconWidth: CGFloat { showsIcon ? 18 : 0 }
    private var dotWidth: CGFloat { 11 }
    private var closeWidth: CGFloat { 22 }
    private var horizontalPadding: CGFloat { isCompact ? 8 : 9 }
    private var titleFontSize: CGFloat { isCompact ? 11.5 : 12 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Layout

    private func widthFor(_ item: Item) -> CGFloat {
        let font = Fonts.ui(size: titleFontSize)
        let textWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        let total = horizontalPadding * 2 + iconWidth + (item.showsDot ? dotWidth : 0)
            + textWidth + closeWidth
        return min(maxTabWidth, max(minTabWidth, total))
    }

    private func layoutTabs() {
        tabRects.removeAll()
        closeRects.removeAll()
        var x: CGFloat = 0
        let h = bounds.height
        for item in items {
            let w = widthFor(item)
            let rect = NSRect(x: x - scrollOffset, y: 0, width: w, height: h)
            tabRects.append(rect)
            closeRects.append(NSRect(x: rect.maxX - closeWidth - 2, y: (h - 16) / 2,
                                     width: 16, height: 16))
            x += w
        }
        contentWidth = x
    }

    private var contentWidth: CGFloat = 0

    /// A custom `NSView` has no intrinsic size, so a strip constrained only by a
    /// leading edge and a maximum width is under-determined — Auto Layout happily
    /// collapses it to **zero** width, leaving a tab bar that exists in the
    /// hierarchy but is invisible on screen. Reporting the content width fixes
    /// that; callers decide whether it may be squeezed by adjusting the
    /// compression-resistance priority.
    override var intrinsicContentSize: NSSize {
        let content = items.reduce(CGFloat(0)) { $0 + widthFor($1) }
        return NSSize(width: max(60, content), height: NSView.noIntrinsicMetric)
    }

    private func clampScroll() {
        let maxOffset = max(0, contentWidth - bounds.width)
        scrollOffset = min(max(0, scrollOffset), maxOffset)
    }

    func scrollToSelected() {
        guard selectedIndex >= 0, selectedIndex < tabRects.count else { return }
        let rect = tabRects[selectedIndex]
        if rect.minX < 0 { scrollOffset += rect.minX - 8 }
        else if rect.maxX > bounds.width { scrollOffset += rect.maxX - bounds.width + 8 }
        clampScroll()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.current
        theme.tabBarBackground.setFill()
        dirtyRect.fill()

        layoutTabs()
        clampScroll()

        let titleFont = Fonts.ui(size: titleFontSize)
        let activeFont = Fonts.ui(size: titleFontSize, weight: .medium)

        for (index, item) in items.enumerated() {
            let rect = tabRects[index]
            guard rect.intersects(dirtyRect) else { continue }
            let isSelected = index == selectedIndex

            if isSelected {
                theme.tabActiveBackground.setFill()
                rect.fill()
                theme.accent.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2).fill()
            } else if index == hoverIndex {
                theme.hover.setFill()
                rect.fill()
            } else {
                theme.tabInactiveBackground.setFill()
                rect.fill()
            }

            theme.subtleBorder.setStroke()
            let sep = NSBezierPath()
            sep.move(to: NSPoint(x: rect.maxX - 0.5, y: 5))
            sep.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.maxY - 5))
            sep.lineWidth = 1
            sep.stroke()

            var textX = rect.minX + horizontalPadding
            if showsIcon {
                let iconColor = isSelected ? theme.accent
                    : FileIcons.color(forName: item.iconName, theme: theme)
                if let img = Icons.symbol(item.iconName, size: 11.5) {
                    let tinted = TabStripView.tintedImage(img, color: iconColor)
                    tinted?.draw(in: NSRect(x: textX, y: rect.midY - 7, width: 14, height: 14),
                                 from: .zero, operation: .sourceOver, fraction: 1)
                }
                textX += iconWidth
            }

            // Status dot, before the title. The close slot stays free for the ×.
            if item.showsDot {
                let dotSize: CGFloat = 6
                (item.dotColor ?? theme.secondaryText).setFill()
                NSBezierPath(ovalIn: NSRect(x: textX + (dotWidth - dotSize) / 2,
                                            y: rect.midY - dotSize / 2,
                                            width: dotSize, height: dotSize)).fill()
                textX += dotWidth
            }

            let titleColor = isSelected ? theme.text : theme.secondaryText
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isSelected ? activeFont : titleFont,
                .foregroundColor: titleColor
            ]
            let available = rect.width - horizontalPadding * 2 - iconWidth
                - (item.showsDot ? dotWidth : 0) - closeWidth
            let attributed = NSAttributedString(string: item.title, attributes: attrs)
            let textSize = attributed.size()
            let textRect = NSRect(x: textX,
                                  y: rect.midY - textSize.height / 2,
                                  width: min(available, textSize.width),
                                  height: textSize.height)
            attributed.draw(with: textRect,
                            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

            // Close button. Always drawn when the tab is hovered or selected, so
            // there is no state in which a tab looks unclosable.
            let closeRect = closeRects[index]
            if alwaysShowsCloseButton || index == hoverIndex || isSelected {
                if let img = Icons.symbol("xmark", size: 9, weight: .semibold) {
                    let tinted = TabStripView.tintedImage(img, color: theme.secondaryText)
                    tinted?.draw(in: closeRect.insetBy(dx: 3.5, dy: 3.5),
                                 from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
        }

        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    static func tintedImage(_ image: NSImage, color: NSColor) -> NSImage? {
        let img = image.copy() as? NSImage
        img?.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        img?.unlockFocus()
        img?.isTemplate = false
        return img
    }

    // MARK: - Interaction

    func index(at point: NSPoint) -> Int? {
        for (i, rect) in tabRects.enumerated() where rect.contains(point) { return i }
        return nil
    }

    /// The close-button hit box for a tab, in this view's coordinates. Exposed so
    /// a test can click exactly where the × is drawn.
    func closeRect(at index: Int) -> NSRect? {
        layoutTabs()
        return closeRects.indices.contains(index) ? closeRects[index] : nil
    }

    /// The tab's hit box, in this view's coordinates.
    func tabRect(at index: Int) -> NSRect? {
        layoutTabs()
        return tabRects.indices.contains(index) ? tabRects[index] : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = index(at: p) else { return }
        if event.clickCount == 2 {
            onDoubleClick?(index)
            return
        }
        click(at: p)
    }

    /// Applies a click at a point in this view's coordinates.
    ///
    /// Split out of `mouseDown` so tests can exercise the hit-testing — in
    /// particular that the close button wins over the tab body — without
    /// synthesising mouse events.
    func click(at point: NSPoint) {
        layoutTabs()
        guard let index = index(at: point) else { return }
        if closeRects.indices.contains(index), closeRects[index].contains(point) {
            delegate?.tabStrip(self, didClose: index)
            return
        }
        delegate?.tabStrip(self, didSelect: index)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p) ?? -1
        if idx != hoverIndex {
            hoverIndex = idx
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != -1 {
            hoverIndex = -1
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollOffset -= event.scrollingDeltaX + event.scrollingDeltaY
        clampScroll()
        needsDisplay = true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return nil }
        // Right-clicking a tab should also select it: every menu item acts on the
        // tab the user pointed at, so leaving the selection elsewhere is confusing.
        if index != selectedIndex {
            delegate?.tabStrip(self, didSelect: index)
        }
        return delegate?.tabStrip(self, menuFor: index)
    }
}
