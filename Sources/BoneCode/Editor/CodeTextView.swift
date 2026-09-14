import AppKit

/// The code editing surface.
///
/// Highlighting is applied directly to the text storage over the *visible* range
/// only. That keeps the cost independent of file size and — because the range is
/// small — avoids the flicker and scroll jumps you get from restyling a whole
/// document on every keystroke.
final class CodeTextView: NSTextView {

    // MARK: - Public surface

    var language: Language = .plain {
        didSet {
            guard language.id != oldValue.id else { return }
            rehighlight()
        }
    }

    var fileURL: URL?

    var onTextChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    /// Extra names offered in completions (e.g. run configurations, git branches).
    var extraSymbols: [String] = []

    private(set) var tokens: [Token] = []
    private(set) var wordFrequency: [String: Int] = [:]
    private(set) var memberWords: Set<String> = []

    // MARK: - Private state

    private var didSetup = false
    private var isStyling = false
    private var tokenGeneration = 0
    private var styledRange = NSRange(location: 0, length: 0)
    private var bracketRanges: [NSRange] = []
    private var lineStarts: [Int] = [0]
    private var lineStartsDirty = true

    private let highlightDebouncer = Debouncer(delay: 0.06)
    private let completionDebouncer = Debouncer(delay: 0.10)

    private let completionPanel = CompletionPanelController()
    private var completionItems: [CompletionItem] = []
    private var completionReplaceRange = NSRange(location: 0, length: 0)

    private static let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setup()
    }

    private func setup() {
        guard !didSetup else { return }
        didSetup = true

        delegate = self
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        isEditable = true
        isSelectable = true
        drawsBackground = true
        textContainerInset = NSSize(width: 6, height: 6)

        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]

        applyTheme()
        completionPanel.onCommit = { [weak self] item in
            guard let self else { return }
            self.applyCompletion(item)
            self.window?.makeFirstResponder(self)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Theme

    @objc private func themeChanged() {
        applyTheme()
        rehighlight()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        needsDisplay = true
    }

    func applyTheme() {
        let t = ThemeManager.shared.current
        backgroundColor = t.editorBackground
        insertionPointColor = t.caretColor
        selectedTextAttributes = [.backgroundColor: t.selection]
        font = ThemeManager.shared.codeFont
        textColor = t.text
        updateParagraphStyle()
        applyWrapSetting()
    }

    func updateParagraphStyle() {
        let ps = NSMutableParagraphStyle()
        let tabW = max(4, EditorSettings.shared.useSpaces
                       ? CGFloat(EditorSettings.shared.tabWidth) * spaceWidth()
                       : spaceWidth() * 4)
        var stops: [NSTextTab] = []
        var x: CGFloat = tabW
        while x < 4000 {
            stops.append(NSTextTab(type: .leftTabStopType, location: x))
            x += tabW
        }
        ps.tabStops = stops
        ps.defaultTabInterval = tabW
        // Pin the line height. The italic comment font can have slightly
        // different metrics than the regular face, and a height that changes on
        // restyle makes the document view resize under the scroll view.
        let codeFont = ThemeManager.shared.codeFont
        let lineHeight = ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
        ps.minimumLineHeight = lineHeight
        ps.maximumLineHeight = lineHeight
        defaultParagraphStyle = ps
        typingAttributes = baseAttributes()
    }

    private func spaceWidth() -> CGFloat {
        let f = ThemeManager.shared.codeFont
        return ("MM" as NSString).size(withAttributes: [.font: f]).width / 2
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: ThemeManager.shared.codeFont,
            .foregroundColor: ThemeManager.shared.current.text
        ]
        if let ps = defaultParagraphStyle { a[.paragraphStyle] = ps }
        return a
    }

    func applyWrapSetting() {
        let wrap = EditorSettings.shared.wrapLines
        textContainer?.widthTracksTextView = wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: - Line index

    private func rebuildLineStartsIfNeeded() {
        guard lineStartsDirty else { return }
        lineStartsDirty = false
        var starts: [Int] = [0]
        starts.reserveCapacity(256)
        let ns = string as NSString
        var idx = 0
        let len = ns.length
        while idx < len {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: len - idx))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            idx = r.location + 1
        }
        lineStarts = starts
    }

    func lineNumber(at charIndex: Int) -> Int {
        rebuildLineStartsIfNeeded()
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    var totalLines: Int {
        rebuildLineStartsIfNeeded()
        return lineStarts.count
    }

    var currentLineNumber: Int {
        lineNumber(at: min(selectedRange().location, (string as NSString).length))
    }

    var currentColumn: Int {
        let loc = selectedRange().location
        rebuildLineStartsIfNeeded()
        let start = lineStarts[max(0, lineNumber(at: loc) - 1)]
        return loc - start + 1
    }

    func gotoLine(_ n: Int) {
        rebuildLineStartsIfNeeded()
        let idx = min(max(1, n), lineStarts.count) - 1
        let loc = lineStarts[idx]
        setSelectedRange(NSRange(location: loc, length: 0))
        scrollRangeToVisible(NSRange(location: loc, length: 0))
        window?.makeFirstResponder(self)
    }

    // MARK: - Highlighting

    func rehighlight() {
        tokenGeneration += 1
        let gen = tokenGeneration
        let text = string
        let lang = language
        highlightDebouncer.cancel()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let toks = SyntaxHighlighter.shared.cachedTokens(text, language: lang)
            let words = CompletionEngine.buildWordFrequency(text)
            let members = CompletionEngine.buildMemberWords(text)
            DispatchQueue.main.async {
                guard let self, gen == self.tokenGeneration else { return }
                self.tokens = toks
                self.wordFrequency = words
                self.memberWords = members
                self.applyStyling()
            }
        }
    }

    private func scheduleHighlight() {
        tokenGeneration += 1
        let gen = tokenGeneration
        let text = string
        let lang = language
        highlightDebouncer.schedule { [weak self] in
            guard let self, gen == self.tokenGeneration else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let toks = SyntaxHighlighter.shared.cachedTokens(text, language: lang)
                let words = CompletionEngine.buildWordFrequency(text)
                let members = CompletionEngine.buildMemberWords(text)
                DispatchQueue.main.async {
                    guard gen == self.tokenGeneration else { return }
                    self.tokens = toks
                    self.wordFrequency = words
                    self.memberWords = members
                    self.applyStyling()
                }
            }
        }
    }

    /// Style the visible range from the current token list.
    func applyStyling() {
        guard !isStyling else { return }        // never re-enter
        guard let ts = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        let theme = ThemeManager.shared.current
        let len = ts.length
        guard len > 0 else { return }

        let visible = visibleRect.insetBy(dx: 0, dy: -visibleRect.height)
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        var charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        charRange = NSIntersectionRange(charRange, NSRange(location: 0, length: len))
        guard charRange.length > 0 else { return }

        let base = baseAttributes()
        let italicFont: NSFont = {
            let f = ThemeManager.shared.codeFont
            let d = f.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: d, size: f.pointSize) ?? f
        }()

        isStyling = true
        let undoWasEnabled = undoManager?.isUndoRegistrationEnabled ?? false
        if undoWasEnabled { undoManager?.disableUndoRegistration() }

        ts.beginEditing()
        ts.setAttributes(base, range: charRange)

        let lo = charRange.location
        let hi = charRange.location + charRange.length
        var i = firstTokenIndex(atOrBefore: lo)
        while i < tokens.count {
            let t = tokens[i]
            if t.location >= hi { break }
            let tEnd = t.location + t.length
            if tEnd > lo {
                let s = max(t.location, lo)
                let e = min(tEnd, hi)
                let r = NSRange(location: s, length: e - s)
                if t.role == .comment {
                    ts.addAttribute(.foregroundColor, value: theme.color(for: .comment), range: r)
                    ts.addAttribute(.font, value: italicFont, range: r)
                } else if t.role != .plain {
                    ts.addAttribute(.foregroundColor, value: theme.color(for: t.role), range: r)
                }
            }
            i += 1
        }

        ts.endEditing()
        if undoWasEnabled { undoManager?.enableUndoRegistration() }
        styledRange = charRange
        isStyling = false
    }

    private func firstTokenIndex(atOrBefore location: Int) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var lo = 0, hi = tokens.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if tokens[mid].location <= location {
                best = mid; lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// True when the index sits inside a comment or string token.
    func isInCommentOrString(at index: Int) -> Bool {
        guard !tokens.isEmpty else { return false }
        var i = firstTokenIndex(atOrBefore: index)
        // tokens can be adjacent; walk back a little to be safe
        i = max(0, i - 1)
        while i < tokens.count {
            let t = tokens[i]
            if t.location > index { return false }
            if index >= t.location && index < t.location + t.length {
                return t.role == .comment || t.role == .string
            }
            i += 1
        }
        return false
    }

    // MARK: - Bracket matching

    private func updateBracketMatch() {
        bracketRanges = []
        guard EditorSettings.shared.highlightMatchingBracket else {
            refreshBracketVisual()
            return
        }
        let ns = string as NSString
        let sel = selectedRange()
        let len = ns.length
        guard len > 0 else { refreshBracketVisual(); return }

        // Look at the char before the caret first, then at the caret.
        for probe in [sel.location - 1, sel.location] {
            guard probe >= 0, probe < len else { continue }
            let ch = ns.character(at: probe)
            guard let scalar = UnicodeScalar(ch) else { continue }
            let c = Character(scalar)
            if let close = Self.openers[c] {
                if let match = findMatch(ns, from: probe, opener: c, closer: close, forward: true) {
                    bracketRanges = [NSRange(location: probe, length: 1), NSRange(location: match, length: 1)]
                    refreshBracketVisual()
                    return
                }
            } else if Self.closers.contains(c), c != "\"" && c != "'" && c != "`" {
                if let match = findMatch(ns, from: probe, opener: nil, closer: c, forward: false) {
                    bracketRanges = [NSRange(location: match, length: 1), NSRange(location: probe, length: 1)]
                    refreshBracketVisual()
                    return
                }
            }
        }
        refreshBracketVisual()
    }

    private var previousBracketRange = NSRange(location: 0, length: 0)

    /// Bracket highlighting uses *temporary* attributes: they affect drawing
    /// only, so moving the caret never touches the text storage and therefore
    /// never invalidates layout.
    private func refreshBracketVisual() {
        guard let lm = layoutManager else { return }
        if previousBracketRange.length > 0 {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previousBracketRange)
            previousBracketRange = NSRange(location: 0, length: 0)
        }
        guard !bracketRanges.isEmpty else { return }
        let theme = ThemeManager.shared.current
        let length = (string as NSString).length
        for range in bracketRanges where range.location + range.length <= length {
            lm.addTemporaryAttribute(.backgroundColor, value: theme.accentSoft, forCharacterRange: range)
        }
        let start = bracketRanges.map(\.location).min() ?? 0
        let end = bracketRanges.map { $0.location + $0.length }.max() ?? 0
        previousBracketRange = NSRange(location: start, length: max(0, end - start))
        needsDisplay = true
    }

    private func findMatch(_ ns: NSString, from index: Int, opener: Character?, closer: Character, forward: Bool) -> Int? {
        guard let scalarOpen = opener?.unicodeScalars.first.map({ Int($0.value) }),
              let scalarClose = closer.unicodeScalars.first.map({ Int($0.value) }) else { return nil }
        var depth = 0
        if forward {
            var i = index
            while i < ns.length {
                let v = Int(ns.character(at: i))
                if v == scalarOpen { depth += 1 }
                else if v == scalarClose {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += 1
            }
        } else {
            var i = index
            while i >= 0 {
                let v = Int(ns.character(at: i))
                if v == scalarClose { depth += 1 }
                else if v == scalarOpen {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i -= 1
            }
        }
        return nil
    }

    // MARK: - Editing operations

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let loc = min(sel.location, ns.length)
        var lineStart = 0, lineEnd = 0, contentEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentEnd, for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        var extra = ""
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[") {
            extra = EditorSettings.shared.indentUnit
        } else if trimmed.hasSuffix(":") {
            // Python / YAML style blocks
            if language.id == "python" || language.id == "yaml" || language.id == "toml" {
                extra = EditorSettings.shared.indentUnit
            }
        }

        // Smart close: caret right before a closing brace → expand into a block
        let charAfter: Character? = (loc < ns.length)
            ? UnicodeScalar(ns.character(at: loc)).map(Character.init)
            : nil
        if let after = charAfter, after == "}", extra.isEmpty, !indent.isEmpty {
            let insertion = "\n" + indent
            super.insertText(insertion, replacementRange: sel)
            let innerStart = selectedRange().location
            super.insertText("\n" + indent, replacementRange: selectedRange())
            setSelectedRange(NSRange(location: innerStart, length: 0))
            return
        }

        super.insertText("\n" + indent + extra, replacementRange: sel)
    }

    override func insertTab(_ sender: Any?) {
        indentSelection()
    }

    override func insertBacktab(_ sender: Any?) {
        outdentSelection()
    }

    func indentSelection() {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length == 0 || !selectionSpansMultipleLines() {
            // Move caret to the next tab stop
            if EditorSettings.shared.useSpaces {
                let loc = sel.location
                var lineStart = 0, lineEnd = 0, contentEnd = 0
                ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentEnd, for: NSRange(location: loc, length: 0))
                let column = loc - lineStart
                let tw = EditorSettings.shared.tabWidth
                let spaces = tw - (column % tw)
                super.insertText(String(repeating: " ", count: spaces), replacementRange: sel)
            } else {
                super.insertText("\t", replacementRange: sel)
            }
            return
        }
        transformSelectedLines { line in EditorSettings.shared.indentUnit + line }
    }

    func outdentSelection() {
        let sel = selectedRange()
        if sel.length == 0 { return }
        transformSelectedLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var drop = 0
            for ch in line where ch == " " && drop < EditorSettings.shared.tabWidth { drop += 1 }
            return String(line.dropFirst(drop))
        }
    }

    private func selectionSpansMultipleLines() -> Bool {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length > 0 else { return false }
        let range = ns.range(of: "\n", options: [], range: sel)
        return range.location != NSNotFound
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0 {
            sel = ns.lineRange(for: sel)
        }
        var lineRange = ns.lineRange(for: sel)
        if lineRange.length > 0, ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A,
           lineRange.length > 1 {
            lineRange.length -= 1
        }
        let block = ns.substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")
        let newBlock = lines.map(transform).joined(separator: "\n")
        guard newBlock != block else { return }
        guard shouldChangeText(in: lineRange, replacementString: newBlock) else { return }
        textStorage?.replaceCharacters(in: lineRange, with: newBlock)
        didChangeText()
        let delta = (newBlock as NSString).length - lineRange.length
        setSelectedRange(NSRange(location: lineRange.location, length: max(0, sel.length + delta)))
        rehighlight()
    }

    func toggleComment() {
        let lang = language
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = ns.lineRange(for: sel) }
        var lineRange = ns.lineRange(for: sel)
        if lineRange.length > 0, ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A,
           lineRange.length > 1 {
            lineRange.length -= 1
        }
        let block = ns.substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }

        let marker: String
        let usesBlock: Bool
        if let lc = lang.lineComments.first {
            marker = lc; usesBlock = false
        } else if let bc = lang.blockComments.first {
            marker = bc.0; usesBlock = true
        } else {
            marker = "//"; usesBlock = false
        }
        let closeMarker = usesBlock ? (lang.blockComments.first?.1 ?? "") : ""

        // Determine whether every non-empty line is already commented.
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        }

        let newBlock: String
        if allCommented {
            newBlock = lines.map { line -> String in
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                var rest = String(line.dropFirst(indent.count))
                if rest.hasPrefix(marker) {
                    rest = String(rest.dropFirst(marker.count))
                    if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
                }
                if usesBlock, !closeMarker.isEmpty, rest.hasSuffix(closeMarker) {
                    rest = String(rest.dropLast(closeMarker.count))
                }
                return indent + rest
            }.joined(separator: "\n")
        } else {
            newBlock = lines.map { line -> String in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let rest = String(line.dropFirst(indent.count))
                if usesBlock {
                    return indent + marker + " " + rest + " " + closeMarker
                }
                return indent + marker + " " + rest
            }.joined(separator: "\n")
        }

        guard shouldChangeText(in: lineRange, replacementString: newBlock) else { return }
        textStorage?.replaceCharacters(in: lineRange, with: newBlock)
        didChangeText()
        let delta = (newBlock as NSString).length - lineRange.length
        setSelectedRange(NSRange(location: lineRange.location, length: max(0, sel.length + delta)))
        rehighlight()
    }

    func duplicateSelection() {
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = ns.lineRange(for: sel) }
        var lineRange = ns.lineRange(for: sel)
        if lineRange.length > 0, ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A {
            lineRange.length -= 1
        }
        let block = ns.substring(with: lineRange)
        let insertion = "\n" + block
        guard shouldChangeText(in: NSRange(location: lineRange.location + lineRange.length, length: 0),
                               replacementString: insertion) else { return }
        textStorage?.replaceCharacters(in: NSRange(location: lineRange.location + lineRange.length, length: 0),
                                      with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location + lineRange.length + 1 + (sel.location - lineRange.location),
                                 length: sel.length))
        rehighlight()
    }

    func deleteLines() {
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = ns.lineRange(for: sel) }
        let lineRange = ns.lineRange(for: sel)
        guard shouldChangeText(in: lineRange, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: lineRange, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: min(lineRange.location, (string as NSString).length), length: 0))
        rehighlight()
    }

    func moveLines(up: Bool) {
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = ns.lineRange(for: sel) }
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)

        if up {
            guard lineRange.location > 0 else { return }
            let prevRange = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let prev = ns.substring(with: prevRange)
            let combined = prevRange.length + lineRange.length
            let replacement = block + prev
            guard shouldChangeText(in: NSRange(location: prevRange.location, length: combined), replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: NSRange(location: prevRange.location, length: combined), with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: prevRange.location + (sel.location - lineRange.location), length: sel.length))
        } else {
            let after = lineRange.location + lineRange.length
            guard after < ns.length else { return }
            let nextRange = ns.lineRange(for: NSRange(location: after, length: 0))
            let next = ns.substring(with: nextRange)
            let combined = lineRange.length + nextRange.length
            let replacement = next + block
            guard shouldChangeText(in: NSRange(location: lineRange.location, length: combined), replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: NSRange(location: lineRange.location, length: combined), with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: lineRange.location + nextRange.length + (sel.location - lineRange.location), length: sel.length))
        }
        rehighlight()
    }

    // MARK: - Auto close pairs

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let a = string as? NSAttributedString { text = a.string }
        else { super.insertText(string, replacementRange: replacementRange); return }

        guard EditorSettings.shared.autoCloseBrackets, text.count == 1,
              let ch = text.first else {
            super.insertText(text, replacementRange: replacementRange)
            return
        }

        let ns = self.string as NSString
        let sel = selectedRange()
        let inComment = isInCommentOrString(at: max(0, sel.location - 1))

        // Wrap a selection with the matching pair
        if sel.length > 0, let closer = Self.openers[ch] {
            let selected = ns.substring(with: sel)
            if ch == "\"" || ch == "'" || ch == "`" {
                if selected.contains("\n") { super.insertText(text, replacementRange: replacementRange); return }
            }
            let wrapped = "\(ch)\(selected)\(closer)"
            guard shouldChangeText(in: sel, replacementString: wrapped) else { return }
            textStorage?.replaceCharacters(in: sel, with: wrapped)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
            rehighlight()
            return
        }

        // Skip over an existing closing character
        if Self.closers.contains(ch), !inComment,
           sel.length == 0, sel.location < ns.length {
            let next = UnicodeScalar(ns.character(at: sel.location)).map(Character.init)
            if next == ch {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
        }

        // Auto-insert the pair
        if let closer = Self.openers[ch], !inComment, sel.length == 0 {
            let isQuote = (ch == "\"" || ch == "'" || ch == "`")
            if isQuote {
                // Don't auto-close a quote when the previous char is a quote (typing '' by hand)
                if sel.location > 0,
                   UnicodeScalar(ns.character(at: sel.location - 1)).map(Character.init) == ch {
                    super.insertText(text, replacementRange: replacementRange)
                    return
                }
                // Don't auto-close in the middle of a word
                if sel.location < ns.length,
                   let after = UnicodeScalar(ns.character(at: sel.location)).map(Character.init),
                   after.isLetter || after.isNumber {
                    super.insertText(text, replacementRange: replacementRange)
                    return
                }
            }
            let pair = "\(ch)\(closer)"
            guard shouldChangeText(in: sel, replacementString: pair) else { return }
            textStorage?.replaceCharacters(in: sel, with: pair)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            rehighlight()
            return
        }

        super.insertText(text, replacementRange: replacementRange)
    }

    /// Backspace should delete both halves of an empty pair.
    override func deleteBackward(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, sel.location < ns.length {
            let before = UnicodeScalar(ns.character(at: sel.location - 1)).map(Character.init)
            let after = UnicodeScalar(ns.character(at: sel.location)).map(Character.init)
            if let b = before, let a = after, let closer = Self.openers[b], closer == a {
                let r = NSRange(location: sel.location - 1, length: 2)
                if shouldChangeText(in: r, replacementString: "") {
                    textStorage?.replaceCharacters(in: r, with: "")
                    didChangeText()
                    setSelectedRange(NSRange(location: sel.location - 1, length: 0))
                    rehighlight()
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if completionPanel.isVisible {
            switch event.keyCode {
            case 53: // esc
                hideCompletions(); return
            case 125: // down
                completionPanel.moveSelection(1); return
            case 126: // up
                completionPanel.moveSelection(-1); return
            case 36, 48, 76: // return / tab / enter
                commitSelectedCompletion(); return
            default:
                break
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.control), event.keyCode == 49 { // ctrl+space
            showCompletions(explicit: true); return
        }
        if flags.contains(.command) {
            switch chars {
            case "/": toggleComment(); return
            case "d", "D": duplicateSelection(); return
            case "K": deleteLines(); return
            case "[": outdentSelection(); return
            case "]": indentSelection(); return
            default: break
            }
        }
        if flags.contains(.option), event.keyCode == 126 { moveLines(up: true); return }
        if flags.contains(.option), event.keyCode == 125 { moveLines(up: false); return }

        super.keyDown(with: event)
    }

    // MARK: - Completions

    func showCompletions(explicit: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length == 0 else { hideCompletions(); return }

        var start = sel.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x5F || c == 0x24 || c >= 0x80 || c == 0x2D
            if !ok { break }
            start -= 1
        }
        let prefixRange = NSRange(location: start, length: sel.location - start)
        let prefix = ns.substring(with: prefixRange)

        if !explicit && prefix.count < 1 { hideCompletions(); return }

        let isMemberAccess = prefixRange.location > 0
            && ns.character(at: prefixRange.location - 1) == 0x2E

        var items = CompletionEngine.shared.suggestions(
            prefix: prefix,
            language: language,
            documentWords: wordFrequency,
            memberWords: memberWords,
            isMemberAccess: isMemberAccess,
            fileURL: fileURL
        )

        if !extraSymbols.isEmpty {
            let lower = prefix.lowercased()
            let extra = extraSymbols
                .filter { prefix.isEmpty || $0.lowercased().hasPrefix(lower) }
                .map { CompletionItem(label: $0, insertText: $0, kind: .symbol, detail: "项目") }
            items = Array((extra + items).prefix(220))
        }

        guard !items.isEmpty else { hideCompletions(); return }

        completionItems = items
        completionReplaceRange = prefixRange
        let point = caretScreenPoint()
        completionPanel.show(items: items, at: point, selectedIndex: 0)
    }

    func hideCompletions() {
        completionItems = []
        completionPanel.hide()
    }

    private func commitSelectedCompletion() {
        guard let item = completionPanel.selectedItem else { hideCompletions(); return }
        applyCompletion(item)
    }

    func applyCompletion(_ item: CompletionItem) {
        let replaceRange = completionReplaceRange
        let ns = string as NSString
        guard replaceRange.location + replaceRange.length <= ns.length else { hideCompletions(); return }

        var insert = item.insertText
        var caretOffset = (insert as NSString).length
        if let marker = insert.range(of: "|") {
            let before = String(insert[insert.startIndex..<marker.lowerBound])
            caretOffset = (before as NSString).length
            insert = insert.replacingCharacters(in: marker, with: "")
        }

        guard shouldChangeText(in: replaceRange, replacementString: insert) else { hideCompletions(); return }
        textStorage?.replaceCharacters(in: replaceRange, with: insert)
        didChangeText()
        setSelectedRange(NSRange(location: replaceRange.location + caretOffset, length: 0))
        hideCompletions()
        rehighlight()
    }

    /// Screen-space caret position, used to anchor the completion popup.
    private func caretScreenPoint() -> NSPoint {
        guard let lm = layoutManager, let tc = textContainer, let window else {
            return NSEvent.mouseLocation
        }
        let sel = selectedRange()
        let loc = min(sel.location, max(0, (string as NSString).length))
        var rect: NSRect
        if loc == 0 {
            rect = NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 2, height: ThemeManager.shared.codeFont.pointSize + 4)
        } else {
            let glyphIndex = lm.glyphIndexForCharacter(at: loc - 1)
            let frag = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLoc = lm.location(forGlyphAt: glyphIndex)
            rect = NSRect(x: glyphLoc.x + textContainerOrigin.x,
                          y: frag.minY + textContainerOrigin.y,
                          width: 2,
                          height: frag.height)
            // If the previous char is a wide glyph the caret sits after it
            let adv = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: tc)
            rect.origin.x = adv.maxX + textContainerOrigin.x
        }
        let inWindow = convert(rect, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return NSPoint(x: onScreen.minX, y: onScreen.minY + rect.height)
    }

    // MARK: - Scrolling / layout hooks

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        rehighlight()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Never restyle from inside a layout pass. applyStyling() writes to the
        // text storage, which invalidates layout, which changes this view's
        // height, which calls setFrameSize again — an infinite loop that shows
        // up as a permanent spinning cursor. Defer to the next runloop turn.
        scheduleDeferredStyling()
    }

    private var deferredStylingScheduled = false

    private func scheduleDeferredStyling() {
        guard !deferredStylingScheduled else { return }
        deferredStylingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredStylingScheduled = false
            self.applyStyling()
        }
    }

    // MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard EditorSettings.shared.highlightCurrentLine,
              let lm = layoutManager else { return }
        guard lm.numberOfGlyphs > 0 else { return }
        let ns = string as NSString
        let sel = selectedRange()
        let loc = min(sel.location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let charIndex = min(lineRange.location, max(0, ns.length - 1))
        let glyphIndex = lm.glyphIndexForCharacter(at: charIndex)
        var r = lm.lineFragmentRect(forGlyphAt: min(glyphIndex, lm.numberOfGlyphs - 1), effectiveRange: nil)
        r.origin.x = 0
        r.size.width = bounds.width
        r.origin.y += textContainerOrigin.y
        ThemeManager.shared.current.currentLine.setFill()
        r.fill()
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let items: [(String, Selector)] = [
            ("切换注释", #selector(toggleCommentAction)),
            ("复制当前行", #selector(duplicateSelectionAction)),
            ("删除当前行", #selector(deleteLinesAction)),
            ("上移当前行", #selector(moveLineUpAction)),
            ("下移当前行", #selector(moveLineDownAction)),
            ("格式化缩进（选中）", #selector(formatSelectionAction))
        ]
        for (title, sel) in items {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        return menu
    }

    @objc private func toggleCommentAction() { toggleComment() }
    @objc private func duplicateSelectionAction() { duplicateSelection() }
    @objc private func deleteLinesAction() { deleteLines() }
    @objc private func moveLineUpAction() { moveLines(up: true) }
    @objc private func moveLineDownAction() { moveLines(up: false) }

    @objc func formatSelectionAction() {
        // Re-indent the selection based on brace depth — a cheap structural pass.
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0 { sel = ns.lineRange(for: sel) }
        var lineRange = ns.lineRange(for: sel)
        if lineRange.length > 0, ns.character(at: lineRange.location + lineRange.length - 1) == 0x0A,
           lineRange.length > 1 { lineRange.length -= 1 }
        let block = ns.substring(with: lineRange)
        var depth = 0
        // Account for nesting before the selection
        let prefix = ns.substring(to: lineRange.location)
        for ch in prefix {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth = max(0, depth - 1) }
        }
        let unit = EditorSettings.shared.indentUnit
        var out: [String] = []
        for raw in block.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(""); continue }
            if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") || trimmed.hasPrefix("]") {
                depth = max(0, depth - 1)
            }
            out.append(String(repeating: unit, count: depth) + trimmed)
            var open = 0, close = 0
            for ch in trimmed {
                if ch == "{" || ch == "(" || ch == "[" { open += 1 }
                if ch == "}" || ch == ")" || ch == "]" { close += 1 }
            }
            depth = max(0, depth + open - close)
        }
        let newBlock = out.joined(separator: "\n")
        guard newBlock != block, shouldChangeText(in: lineRange, replacementString: newBlock) else { return }
        textStorage?.replaceCharacters(in: lineRange, with: newBlock)
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: (newBlock as NSString).length))
        rehighlight()
    }
}

// MARK: - NSTextViewDelegate

extension CodeTextView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard !isStyling else { return }
        lineStartsDirty = true
        onTextChange?()
        scheduleHighlight()
        updateBracketMatch()
        if EditorSettings.shared.autoCompletionEnabled {
            completionDebouncer.schedule { [weak self] in
                guard let self else { return }
                guard self.window?.firstResponder === self else { return }
                self.showCompletions(explicit: false)
            }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
        updateBracketMatch()
        if completionPanel.isVisible { hideCompletions() }
        needsDisplay = true
    }
}

// MARK: - Line number gutter

final class LineNumberRulerView: NSRulerView {

    weak var textView: CodeTextView?

    init(textView: CodeTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Metrics.gutterWidth
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer,
              let sv = scrollView else { return }

        let theme = ThemeManager.shared.current
        theme.gutterBackground.setFill()
        NSBezierPath.fill(bounds)

        // separator
        theme.subtleBorder.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        sep.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        sep.lineWidth = 1
        sep.stroke()

        guard EditorSettings.shared.showLineNumbers, let ts = tv.textStorage, ts.length > 0 else { return }

        let visibleRect = sv.contentView.bounds
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, ThemeManager.shared.codeFont.pointSize - 2), weight: .regular)
        let activeLine = tv.currentLineNumber

        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let ns = tv.string as NSString
        let len = ns.length
        guard len > 0 else { return }

        var index = min(charRange.location, max(0, len - 1))
        let limit = min(NSMaxRange(charRange), len)

        while index <= limit {
            let lineRange = ns.lineRange(for: NSRange(location: min(index, max(0, len - 1)), length: 0))
            let number = tv.lineNumber(at: lineRange.location)
            let charIndex = min(lineRange.location, max(0, len - 1))
            let glyphIndex = lm.glyphIndexForCharacter(at: charIndex)
            if glyphIndex < lm.numberOfGlyphs {
                var frag = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                frag.origin.y += tv.textContainerOrigin.y - visibleRect.minY
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: number == activeLine ? theme.gutterTextActive : theme.gutterText
                ]
                let str = NSAttributedString(string: "\(number)", attributes: attrs)
                let size = str.size()
                let y = frag.minY + (frag.height - size.height) / 2
                let x = bounds.maxX - size.width - 10
                str.draw(at: NSPoint(x: x, y: y))
            }
            let next = lineRange.location + lineRange.length
            if next <= index { break }
            index = next
            if index > limit { break }
        }
    }
}

// MARK: - Menu / responder-chain entry points

extension CodeTextView {
    @objc func performToggleComment(_ sender: Any?) { toggleComment() }
    @objc func performDuplicateLine(_ sender: Any?) { duplicateSelection() }
    @objc func performDeleteLine(_ sender: Any?) { deleteLines() }
    @objc func performMoveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func performMoveLineDown(_ sender: Any?) { moveLines(up: false) }
    @objc func performIndent(_ sender: Any?) { indentSelection() }
    @objc func performOutdent(_ sender: Any?) { outdentSelection() }
    @objc func performFormat(_ sender: Any?) { formatSelectionAction() }
    @objc func performComplete(_ sender: Any?) { showCompletions(explicit: true) }
}
