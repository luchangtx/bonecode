import AppKit

/// A borderless toolbar / header button that actually looks interactive.
///
/// `NSButton` with `isBordered = false` draws nothing on hover or press, so a row
/// of icon buttons reads as static decoration: the user clicks once, gets no
/// acknowledgement, and concludes the button is broken. This one paints a
/// rounded background for hover, press, and an optional persistent "active" state
/// (for panel toggles), and shows a pointing-hand cursor.
final class HoverIconButton: NSButton {

    /// Persistent highlight for toggles — "this panel is open".
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyBackground()
        }
    }

    /// The colour used when neither hovering nor pressed.
    var baseTint: NSColor? {
        didSet { applyBackground() }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyBackground() } }
    private var isPressed = false { didSet { applyBackground() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    convenience init(symbol: String,
                     tooltip: String,
                     target: AnyObject?,
                     action: Selector,
                     tint: NSColor? = nil,
                     width: CGFloat = 26,
                     height: CGFloat = 22,
                     symbolSize: CGFloat = 15) {
        self.init(frame: .zero)
        image = Icons.symbol(symbol, size: symbolSize)
        imageScaling = .scaleProportionallyDown
        baseTint = tint ?? ThemeManager.shared.current.secondaryText
        contentTintColor = baseTint
        toolTip = tooltip
        self.target = target
        self.action = action
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    private func configure() {
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
    }

    private func applyBackground() {
        let theme = ThemeManager.shared.current
        let background: NSColor
        if isPressed {
            background = theme.hover.pressed     // NSColor helper: darker than hover
        } else if isHovered {
            background = theme.hover
        } else if isActive {
            background = theme.accentSoft
        } else {
            background = .clear
        }
        layer?.backgroundColor = background.cgColor
        contentTintColor = (isActive && !isHovered && !isPressed) ? theme.accent : baseTint
    }

    /// Re-read theme colours after a theme switch.
    func refreshAppearance() {
        if baseTint == nil { baseTint = ThemeManager.shared.current.secondaryText }
        applyBackground()
    }

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

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)     // blocks until mouse up
        isPressed = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension NSView {
    /// Re-read theme colours for every hover button in the subtree. Their tint is
    /// captured at creation time, so without this they keep the old palette.
    func refreshHoverButtons() {
        (self as? HoverIconButton)?.refreshAppearance()
        for sub in subviews { sub.refreshHoverButtons() }
    }
}

extension NSView {
    /// Let a panel be resized freely by its split view.
    ///
    /// A split view item's usable width range is derived from its content's
    /// hugging and compression-resistance priorities. Left at the defaults a
    /// dense panel holds its fitting width, so the divider stops moving — which a
    /// user reports as "the divider will not drag". Panels are meant to clip or
    /// scroll their content, not to dictate the window layout.
    func relaxSizingForSplitView(depth: Int = 0) {
        guard depth < 40 else { return }
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        for sub in subviews { sub.relaxSizingForSplitView(depth: depth + 1) }
    }
}
