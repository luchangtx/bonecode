import AppKit

/// One draw operation for a terminal row.
struct TerminalDrawOp {
    let x: CGFloat
    let text: String
    let font: NSFont
    let color: NSColor
    let flags: UInt16
    /// When non-nil, the glyph must be clipped to this width. Non-ASCII glyphs
    /// come from a fallback font and cannot be trusted to land on cell bounds.
    let clipWidth: CGFloat?
}

/// The one number the terminal grid and the drawn text must agree on.
///
/// Backgrounds, the selection and the cursor are placed at `col * cellWidth`.
/// Text is drawn as an attributed string, so its glyphs advance by whatever the
/// font says. If these two disagree, every character drifts relative to the grid
/// and the cursor — which lives on the grid — slides off the end of the line.
///
/// Measuring a *long* sample and dividing is deliberate: the width of a single
/// glyph carries sub-pixel rounding, and the original code rounded it **up**
/// (`ceil`), which overstates the cell and makes the drift grow with the line
/// length. Averaging a long run cancels that error out.
enum TerminalCellMetrics {

    static func cellWidth(for font: NSFont) -> CGFloat {
        let count = 64
        let sample = String(repeating: "M", count: count)
        let width = (sample as NSString).size(withAttributes: [.font: font]).width
        guard width > 0 else { return max(4, font.advancement(forGlyph:
            font.glyph(withName: "M")).width) }
        return max(4, width / CGFloat(count))
    }

    static func cellHeight(for font: NSFont) -> CGFloat {
        max(8, ceil(font.ascender - font.descender + font.leading))
    }
}

/// Splits a row of cells into draw operations.
///
/// ASCII runs are merged into a single string because a monospaced face advances
/// them uniformly. Anything non-ASCII is emitted as its own operation pinned to
/// its exact cell x: the fallback font a monospaced face uses for CJK or emoji
/// almost never advances by exactly one or two cells, which would shift every
/// character after it and make the text drift away from the cursor.
enum TerminalRowRenderer {

    static func operations(
        cells: ArraySlice<TermCell>,
        cellWidth: CGFloat,
        resolve: (TermCell) -> (font: NSFont, color: NSColor)
    ) -> [TerminalDrawOp] {
        var ops: [TerminalDrawOp] = []
        var col = 0
        var runStart = 0
        var runText = ""
        var runFont: NSFont?
        var runColor: NSColor?
        var runFlags: UInt16 = 0

        func flush() {
            defer { runText = ""; runFont = nil; runColor = nil }
            guard !runText.isEmpty, let font = runFont, let color = runColor else { return }
            ops.append(TerminalDrawOp(x: CGFloat(runStart) * cellWidth, text: runText,
                                      font: font, color: color, flags: runFlags, clipWidth: nil))
        }

        for cell in cells {
            if cell.isPad {
                // The second half of a wide glyph. The glyph's own `col += width`
                // already advanced past it, so this must not advance again.
                flush()
                continue
            }

            let scalarValue = cell.ch == 0 ? 32 : cell.ch
            let cellCount = max(1, Int(cell.width))
            let resolved = resolve(cell)

            if scalarValue >= 0x80 {
                flush()
                if let scalar = UnicodeScalar(scalarValue) {
                    ops.append(TerminalDrawOp(
                        x: CGFloat(col) * cellWidth,
                        text: String(Character(scalar)),
                        font: resolved.font,
                        color: resolved.color,
                        flags: cell.flags,
                        clipWidth: CGFloat(cellCount) * cellWidth
                    ))
                }
                col += cellCount
                continue
            }

            if runFont !== resolved.font || runColor != resolved.color || runFlags != cell.flags {
                flush()
            }
            if runText.isEmpty {
                runStart = col
                runFont = resolved.font
                runColor = resolved.color
                runFlags = cell.flags
            }
            if let scalar = UnicodeScalar(scalarValue) {
                runText.unicodeScalars.append(scalar)
            } else {
                runText.append(" ")
            }
            col += 1
        }
        flush()
        return ops
    }
}

/// Renders a `TerminalEmulator` grid and turns key events into byte sequences.
///
/// The view is the document view of a scroll view and is as tall as the whole
/// history, so scrollback comes for free. Only rows intersecting the dirty rect
/// are drawn.
final class TerminalView: NSView, NSTextInputClient {

    let emulator: TerminalEmulator

    var onInput: ((Data) -> Void)?
    /// Reports the new (cols, rows) after the visible size changed, so the
    /// process behind the pty can be told. Without this the shell keeps wrapping
    /// at its old width and the cursor drifts away from the text.
    var onResize: ((Int, Int) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onFontSizeChange: ((CGFloat) -> Void)?

    var fontSize: CGFloat = 12 {
        didSet {
            guard fontSize != oldValue else { return }
            rebuildFonts()
            updateSizeFromScrollView()      // cell size changed, so cols/rows did too
            needsDisplay = true
        }
    }

    private var regularFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var italicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldItalicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    private(set) var cellWidth: CGFloat = 8
    private(set) var cellHeight: CGFloat = 16

    // Cursor blink
    private var blinkTimer: Timer?
    private var blinkOn = true

    // Selection
    private var selStart: (row: Int, col: Int)?
    private var selEnd: (row: Int, col: Int)?
    private var isSelecting = false

    // IME
    private var markedText: String = ""
    private var markedRangeValue: NSRange = NSRange(location: NSNotFound, length: 0)

    // MARK: - Init

    init(emulator: TerminalEmulator) {
        self.emulator = emulator
        super.init(frame: .zero)
        wantsLayer = true
        rebuildFonts()
        emulator.onUpdate = { [weak self] in self?.emulatorDidUpdate() }
        emulator.onTitleChange = { [weak self] t in self?.onTitleChange?(t) }
        emulator.onBell = { [weak self] in self?.onBell?() }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        blinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rebuildFonts() {
        regularFont = Fonts.code(size: fontSize)
        boldFont = Fonts.code(size: fontSize, bold: true)
        let italicDesc = regularFont.fontDescriptor.withSymbolicTraits(.italic)
        italicFont = NSFont(descriptor: italicDesc, size: fontSize) ?? regularFont
        let biDesc = boldFont.fontDescriptor.withSymbolicTraits([.italic, .bold])
        boldItalicFont = NSFont(descriptor: biDesc, size: fontSize) ?? boldFont

        // Cell metrics come from one shared source, so the grid the cursor uses
        // and the advances the glyphs make can never disagree. Rounding the cell
        // up here (the original bug) made text drift out from under the cursor.
        cellWidth = TerminalCellMetrics.cellWidth(for: regularFont)
        cellHeight = TerminalCellMetrics.cellHeight(for: regularFont)
    }

    @objc private func themeChanged() { needsDisplay = true }

    // MARK: - Geometry

    /// Recompute cols/rows from the visible size and tell the emulator *and* the
    /// process behind the pty. Both must agree, or the shell's line wrapping and
    /// the grid diverge and the cursor ends up in the wrong column.
    func updateSizeFromScrollView() {
        guard let sv = enclosingScrollView else { return }
        let size = sv.contentSize
        let cols = max(20, Int(size.width / cellWidth))
        let rows = max(4, Int(size.height / cellHeight))
        let changed = cols != emulator.cols || rows != emulator.rows
        emulator.resize(cols: cols, rows: rows)
        syncFrame()
        if changed { onResize?(cols, rows) }
    }

    func syncFrame() {
        let width = enclosingScrollView?.contentSize.width ?? (CGFloat(emulator.cols) * cellWidth)
        let height = CGFloat(emulator.totalRows) * cellHeight
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    private func emulatorDidUpdate() {
        let wasPinned = isScrolledToBottom()
        syncFrame()
        needsDisplay = true
        if wasPinned { scrollToBottom() }
    }

    private func isScrolledToBottom() -> Bool {
        guard let sv = enclosingScrollView else { return true }
        let clip = sv.contentView
        let maxOffset = max(0, frame.height - clip.bounds.height)
        return clip.bounds.origin.y >= maxOffset - cellHeight * 2
    }

    func scrollToBottom() {
        guard let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        let target = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: target))
        sv.reflectScrolledClipView(clip)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.current
        theme.terminalBackground.setFill()
        dirtyRect.fill()

        guard cellHeight > 0 else { return }
        let firstRow = max(0, Int(floor(dirtyRect.minY / cellHeight)))
        let lastRow = min(emulator.totalRows - 1, Int(ceil(dirtyRect.maxY / cellHeight)))
        guard firstRow <= lastRow else { return }

        for v in firstRow...lastRow {
            drawRow(v, y: CGFloat(v) * cellHeight, theme: theme)
        }
        drawCursor(theme: theme)
    }

    private func drawRow(_ virtualRow: Int, y: CGFloat, theme: Theme) {
        let cells = emulator.row(virtualRow)
        guard !cells.isEmpty else { return }
        let count = cells.count
        let defaultBg = theme.terminalBackground

        // ---- backgrounds
        var c = 0
        while c < count {
            let cell = cells[cells.startIndex + c]
            let bg = resolvedBackground(cell, theme: theme, defaultBg: defaultBg)
            var end = c + 1
            while end < count {
                let nxt = cells[cells.startIndex + end]
                if resolvedBackground(nxt, theme: theme, defaultBg: defaultBg) != bg { break }
                end += 1
            }
            if bg != defaultBg {
                bg.setFill()
                NSRect(x: CGFloat(c) * cellWidth, y: y,
                       width: CGFloat(end - c) * cellWidth, height: cellHeight).fill()
            }
            c = end
        }

        // ---- selection
        if let sel = normalizedSelection(), virtualRow >= sel.startRow, virtualRow <= sel.endRow {
            let startCol = virtualRow == sel.startRow ? sel.startCol : 0
            let endCol = virtualRow == sel.endRow ? sel.endCol + 1 : count
            if endCol > startCol {
                theme.terminalSelection.setFill()
                NSRect(x: CGFloat(startCol) * cellWidth, y: y,
                       width: CGFloat(endCol - startCol) * cellWidth, height: cellHeight).fill()
            }
        }

        // ---- text
        let ops = TerminalRowRenderer.operations(cells: cells, cellWidth: cellWidth) { cell in
            (self.fontFor(cell), self.resolvedForeground(cell, theme: theme))
        }
        for op in ops {
            var attrs: [NSAttributedString.Key: Any] = [.font: op.font, .foregroundColor: op.color]
            if op.flags & TermCell.flagUnderline != 0 {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if op.flags & TermCell.flagStrike != 0 {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            let attributed = NSAttributedString(string: op.text, attributes: attrs)
            if let clipWidth = op.clipWidth {
                // 1pt of slack so a slightly wider glyph is not visibly cut.
                let box = NSRect(x: op.x, y: y, width: clipWidth + 1, height: cellHeight)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: box).addClip()
                attributed.draw(at: NSPoint(x: box.minX, y: box.minY))
                NSGraphicsContext.restoreGraphicsState()
            } else {
                attributed.draw(at: NSPoint(x: op.x, y: y))
            }
        }
    }

    fileprivate func fontFor(_ cell: TermCell) -> NSFont {
        let bold = cell.flags & TermCell.flagBold != 0
        let italic = cell.flags & TermCell.flagItalic != 0
        if bold && italic { return boldItalicFont }
        if bold { return boldFont }
        if italic { return italicFont }
        return regularFont
    }

    fileprivate func resolvedForeground(_ cell: TermCell, theme: Theme) -> NSColor {
        var fg = TerminalPalette.color(index: cell.fgIndex, rgb: cell.fgRGB, isForeground: true, theme: theme)
            ?? theme.terminalForeground
        var bg = resolvedBackground(cell, theme: theme, defaultBg: theme.terminalBackground)
        if cell.flags & TermCell.flagReverse != 0 {
            swap(&fg, &bg)
        }
        if cell.flags & TermCell.flagDim != 0 {
            fg = fg.withAlphaComponent(0.55)
        }
        return fg
    }

    private func resolvedBackground(_ cell: TermCell, theme: Theme, defaultBg: NSColor) -> NSColor {
        var bg = TerminalPalette.color(index: cell.bgIndex, rgb: cell.bgRGB, isForeground: false, theme: theme)
            ?? defaultBg
        if cell.flags & TermCell.flagReverse != 0 {
            bg = TerminalPalette.color(index: cell.fgIndex, rgb: cell.fgRGB, isForeground: true, theme: theme)
                ?? theme.terminalForeground
        }
        return bg
    }

    private func drawCursor(theme: Theme) {
        guard window?.firstResponder === self else { return }
        guard emulator.cursorVisible, blinkOn else { return }
        guard !emulator.altScreenActive || true else { return }

        let vRow = emulator.cursorVirtualRow
        let rowRect = NSRect(x: CGFloat(emulator.cursorCol) * cellWidth,
                             y: CGFloat(vRow) * cellHeight,
                             width: cellWidth, height: cellHeight)
        guard rowRect.intersects(visibleRect) else { return }

        let shape = emulator.cursorShape
        let isBar = shape == 4 || shape == 5
        let isUnderline = shape == 2 || shape == 3

        if isBar {
            theme.terminalCursor.setFill()
            NSRect(x: rowRect.minX, y: rowRect.minY, width: max(1.5, cellWidth * 0.15), height: cellHeight).fill()
        } else if isUnderline {
            theme.terminalCursor.setFill()
            NSRect(x: rowRect.minX, y: rowRect.maxY - max(1.5, cellHeight * 0.12),
                   width: cellWidth, height: max(1.5, cellHeight * 0.12)).fill()
        } else {
            theme.terminalCursor.setFill()
            rowRect.fill()
            // Redraw the character under the block cursor in the background colour.
            if vRow < emulator.totalRows {
                let cells = emulator.row(vRow)
                if emulator.cursorCol < cells.count {
                    let cell = cells[cells.startIndex + emulator.cursorCol]
                    if !cell.isPad, let scalar = UnicodeScalar(cell.ch == 0 ? 32 : cell.ch) {
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: fontFor(cell),
                            .foregroundColor: theme.terminalBackground
                        ]
                        NSAttributedString(string: String(Character(scalar)), attributes: attrs)
                            .draw(at: NSPoint(x: rowRect.minX, y: rowRect.minY))
                    }
                }
            }
        }

        // IME composition preview
        if !markedText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: theme.terminalForeground,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            NSAttributedString(string: markedText, attributes: attrs)
                .draw(at: NSPoint(x: rowRect.minX, y: rowRect.minY))
        }
    }

    // MARK: - Cursor blink

    override func becomeFirstResponder() -> Bool {
        startBlinking()
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopBlinking()
        needsDisplay = true
        return true
    }

    private func startBlinking() {
        stopBlinking()
        blinkOn = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.blinkOn.toggle()
            let vRow = self.emulator.cursorVirtualRow
            self.setNeedsDisplay(NSRect(x: 0, y: CGFloat(vRow) * self.cellHeight,
                                        width: self.bounds.width, height: self.cellHeight))
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let cell = cellAt(p)
        selStart = cell
        selEnd = cell
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let p = convert(event.locationInWindow, from: nil)
        selEnd = cellAt(p)
        needsDisplay = true
        autoScrollForDrag(p)
    }

    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        if selStart?.row == selEnd?.row, selStart?.col == selEnd?.col {
            selStart = nil
            selEnd = nil
            needsDisplay = true
        }
    }

    private func cellAt(_ point: NSPoint) -> (row: Int, col: Int) {
        let row = max(0, min(emulator.totalRows - 1, Int(point.y / cellHeight)))
        let col = max(0, min(emulator.cols - 1, Int(point.x / cellWidth)))
        return (row, col)
    }

    private func autoScrollForDrag(_ point: NSPoint) {
        guard let sv = enclosingScrollView else { return }
        let clip = sv.contentView
        var origin = clip.bounds.origin
        if point.y < clip.bounds.minY { origin.y = max(0, origin.y - cellHeight) }
        else if point.y > clip.bounds.maxY { origin.y = min(max(0, frame.height - clip.bounds.height), origin.y + cellHeight) }
        else { return }
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
    }

    private func normalizedSelection() -> (startRow: Int, startCol: Int, endRow: Int, endCol: Int)? {
        guard let s = selStart, let e = selEnd else { return nil }
        if s.row < e.row || (s.row == e.row && s.col <= e.col) {
            return (s.row, s.col, e.row, e.col)
        }
        return (e.row, e.col, s.row, s.col)
    }

    func selectedText() -> String {
        guard let sel = normalizedSelection() else { return "" }
        var lines: [String] = []
        for v in sel.startRow...sel.endRow {
            guard v >= 0, v < emulator.totalRows else { continue }
            let cells = emulator.row(v)
            var line = ""
            var col = 0
            for cell in cells {
                if cell.isPad { continue }
                let w = Int(max(1, cell.width))
                if v == sel.startRow && col + w <= sel.startCol { col += w; continue }
                if v == sel.endRow && col > sel.endCol { break }
                if let scalar = UnicodeScalar(cell.ch == 0 ? 32 : cell.ch) {
                    line.unicodeScalars.append(scalar)
                }
                col += w
            }
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        return lines.joined(separator: "\n")
    }

    func selectAll() {
        selStart = (0, 0)
        selEnd = (max(0, emulator.totalRows - 1), max(0, emulator.cols - 1))
        needsDisplay = true
    }

    // MARK: - Actions

    @objc func copy(_ sender: Any?) {
        let text = selectedText()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if emulator.bracketedPaste {
            send("\u{1B}[200~" + text + "\u{1B}[201~")
        } else {
            send(text)
        }
    }

    @objc func clearScreenAction(_ sender: Any?) {
        emulator.feed(Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8))
    }

    @objc func increaseFontSize(_ sender: Any?) {
        fontSize = min(28, fontSize + 1)
        onFontSizeChange?(fontSize)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        fontSize = max(8, fontSize - 1)
        onFontSizeChange?(fontSize)
    }

    @objc func resetFontSize(_ sender: Any?) {
        fontSize = 12
        onFontSizeChange?(fontSize)
    }

    // MARK: - Keyboard

    private func send(_ string: String) {
        onInput?(Data(string.utf8))
    }

    private func send(_ data: Data) {
        onInput?(data)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Command shortcuts belong to the menu / our action methods.
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if let seq = specialSequence(for: event) {
            send(seq)
            return
        }

        if flags.contains(.control), let b = controlByte(for: event) {
            send(Data([b]))
            return
        }

        if flags.contains(.option), let base = event.charactersIgnoringModifiers, !base.isEmpty {
            send("\u{1B}" + base)
            return
        }

        // Route through the input method so Chinese/Japanese IME works.
        interpretKeyEvents([event])
    }

    private func specialSequence(for event: NSEvent) -> String? {
        let app = emulator.applicationCursorKeys
        switch event.keyCode {
        case 126: return app ? "\u{1B}OA" : "\u{1B}[A"
        case 125: return app ? "\u{1B}OB" : "\u{1B}[B"
        case 124: return app ? "\u{1B}OC" : "\u{1B}[C"
        case 123: return app ? "\u{1B}OD" : "\u{1B}[D"
        case 115: return "\u{1B}[H"
        case 119: return "\u{1B}[F"
        case 116: return "\u{1B}[5~"
        case 121: return "\u{1B}[6~"
        case 117: return "\u{1B}[3~"
        case 51: return "\u{7F}"
        case 36, 76: return "\r"
        case 48: return "\t"
        case 53: return "\u{1B}"
        case 122: return "\u{1B}OP"
        case 120: return "\u{1B}OQ"
        case 99:  return "\u{1B}OR"
        case 118: return "\u{1B}OS"
        case 96:  return "\u{1B}[15~"
        case 97:  return "\u{1B}[17~"
        case 98:  return "\u{1B}[18~"
        case 100: return "\u{1B}[19~"
        case 101: return "\u{1B}[20~"
        case 109: return "\u{1B}[21~"
        case 103: return "\u{1B}[23~"
        case 111: return "\u{1B}[24~"
        default: return nil
        }
    }

    private func controlByte(for event: NSEvent) -> UInt8? {
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else { return nil }
        var v = scalar.value
        if v >= 0x61, v <= 0x7A { v -= 0x60 }
        else if v >= 0x41, v <= 0x5A { v -= 0x40 }
        else if v == 0x20 { v = 0 }
        else if v == 0x5B { v = 0x1B }
        else if v == 0x5C { v = 0x1C }
        else if v == 0x5D { v = 0x1D }
        else if v == 0x5E { v = 0x1E }
        else if v == 0x5F { v = 0x1F }
        else if v >= 0x40, v <= 0x5F { v -= 0x40 }
        else { return nil }
        return UInt8(v & 0xFF)
    }

    override func doCommand(by selector: Selector) {
        // Unhandled command selectors would beep; swallow them.
    }

    // MARK: - NSTextInputClient (IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let a = string as? NSAttributedString { text = a.string }
        else { return }
        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
        needsDisplay = true
        guard !text.isEmpty else { return }
        send(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let a = string as? NSAttributedString { text = a.string }
        else { return }
        markedText = text
        markedRangeValue = NSRange(location: 0, length: (text as NSString).length)
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        markedRangeValue = NSRange(location: NSNotFound, length: 0)
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange { markedRangeValue }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .foregroundColor, .font]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let vRow = emulator.cursorVirtualRow
        let local = NSRect(x: CGFloat(emulator.cursorCol) * cellWidth,
                           y: CGFloat(vRow) * cellHeight,
                           width: cellWidth, height: cellHeight)
        guard let window else { return .zero }
        let inWindow = convert(local, to: nil)
        return window.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}
