import AppKit

/// Renders a unified diff with line numbers and word-level intra-line highlights.
enum DiffRenderer {

    static func attributedString(for diff: FileDiff, theme: Theme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = Fonts.code(size: max(10, ThemeManager.shared.codeFontSize - 0.5))
        let boldFont = Fonts.code(size: max(10, ThemeManager.shared.codeFontSize - 0.5), bold: true)

        let gutterWidth = 13
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.headIndent = 0

        func gutter(_ old: Int?, _ new: Int?) -> String {
            let o = old.map { String($0) } ?? ""
            let n = new.map { String($0) } ?? ""
            let left = String(repeating: " ", count: max(0, 5 - o.count)) + o
            let right = String(repeating: " ", count: max(0, 5 - n.count)) + n
            return left + " " + right + " │ "
        }

        // ---- file header
        let headerText: String
        if diff.isBinary {
            headerText = "\(diff.path)  ·  二进制文件"
        } else if diff.isNew {
            headerText = "\(diff.path)  ·  新增文件  +\(diff.addedCount)"
        } else if diff.isDeleted {
            headerText = "\(diff.path)  ·  删除文件  −\(diff.removedCount)"
        } else {
            var name = diff.path
            if let old = diff.oldPath, old != diff.path { name = "\(old) → \(diff.path)" }
            headerText = "\(name)   +\(diff.addedCount)  −\(diff.removedCount)"
        }
        result.append(NSAttributedString(string: headerText + "\n", attributes: [
            .font: boldFont,
            .foregroundColor: theme.text,
            .backgroundColor: theme.diffHunkHeader,
            .paragraphStyle: paragraph
        ]))

        if diff.isBinary {
            result.append(NSAttributedString(string: "（二进制内容不显示差异）\n", attributes: [
                .font: font, .foregroundColor: theme.secondaryText, .paragraphStyle: paragraph
            ]))
            return result
        }

        for hunk in diff.hunks {
            result.append(NSAttributedString(string: hunk.header + "\n", attributes: [
                .font: font,
                .foregroundColor: theme.function,
                .backgroundColor: theme.diffHunkHeader,
                .paragraphStyle: paragraph
            ]))

            for line in hunk.lines {
                let lineText: String
                let attrs: [NSAttributedString.Key: Any]
                switch line.kind {
                case .added:
                    lineText = "+ " + line.text
                    attrs = [.font: font,
                             .foregroundColor: theme.diffAddedText,
                             .backgroundColor: theme.diffAddedBackground,
                             .paragraphStyle: paragraph]
                case .removed:
                    lineText = "- " + line.text
                    attrs = [.font: font,
                             .foregroundColor: theme.diffRemovedText,
                             .backgroundColor: theme.diffRemovedBackground,
                             .paragraphStyle: paragraph]
                case .meta:
                    lineText = line.text
                    attrs = [.font: font, .foregroundColor: theme.tertiaryText, .paragraphStyle: paragraph]
                default:
                    lineText = "  " + line.text
                    attrs = [.font: font, .foregroundColor: theme.text, .paragraphStyle: paragraph]
                }

                let gutterText = gutter(line.oldNumber, line.newNumber)
                let composed = NSMutableAttributedString(string: gutterText, attributes: [
                    .font: font,
                    .foregroundColor: theme.tertiaryText,
                    .paragraphStyle: paragraph
                ])
                let body = NSMutableAttributedString(string: lineText, attributes: attrs)

                // Intra-line highlights sit on top of the line background.
                if !line.highlight.isEmpty {
                    let offset = (gutterText as NSString).length + 2  // "+ " or "- " or "  "
                    let inlineColor = line.kind == .added ? theme.diffAddedInline : theme.diffRemovedInline
                    for range in line.highlight {
                        let adjusted = NSRange(location: offset + range.location, length: range.length)
                        guard adjusted.location >= 0,
                              adjusted.location + adjusted.length <= body.length else { continue }
                        body.addAttribute(.backgroundColor, value: inlineColor, range: adjusted)
                    }
                }
                composed.append(body)
                composed.append(NSAttributedString(string: "\n", attributes: attrs))
                result.append(composed)
            }
        }

        _ = gutterWidth
        return result
    }

    /// Build a compact summary line for a list of file diffs.
    static func summary(for diffs: [FileDiff]) -> String {
        let added = diffs.reduce(0) { $0 + $1.addedCount }
        let removed = diffs.reduce(0) { $0 + $1.removedCount }
        return "\(diffs.count) 个文件  +\(added)  −\(removed)"
    }
}

/// Read-only diff tab shown inside the editor area.
final class DiffViewController: NSViewController, EditorTabContent {

    private let diffs: [FileDiff]
    private let titleOverride: String
    private let subtitleText: String?
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var fileTable: NSTableView?
    private var selectedFileIndex = 0
    private var splitView: NSSplitView?

    init(diffs: [FileDiff], title: String, subtitle: String?) {
        self.diffs = diffs
        self.titleOverride = title
        self.subtitleText = subtitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var tabTitle: String { titleOverride }
    var tabSubtitle: String? { subtitleText }
    var tabURL: URL? { nil }
    var tabIsDirty: Bool { false }
    var tabIconName: String { "plusminus.circle" }
    func saveIfNeeded() -> Bool { true }
    func focusEditor() {}

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.editorBackground)

        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = ThemeManager.shared.current.editorBackground
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        textScroll.documentView = tv
        self.textView = tv
        self.scrollView = textScroll

        if diffs.count > 1 {
            let table = NSTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 24
            table.dataSource = self
            table.delegate = self
            table.backgroundColor = ThemeManager.shared.current.sidebarBackground
            table.style = .sourceList
            table.selectionHighlightStyle = .regular
            fileTable = table

            let listScroll = NSScrollView()
            listScroll.documentView = table
            listScroll.hasVerticalScroller = true
            listScroll.autohidesScrollers = true
            listScroll.drawsBackground = true
            listScroll.backgroundColor = ThemeManager.shared.current.sidebarBackground
            listScroll.borderType = .noBorder

            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            split.addArrangedSubview(listScroll)
            split.addArrangedSubview(textScroll)
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            split.translatesAutoresizingMaskIntoConstraints = false
            listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            listScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            splitView = split

            root.addSubview(split)
            NSLayoutConstraint.activate([
                split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                split.topAnchor.constraint(equalTo: root.topAnchor),
                split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            textScroll.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(textScroll)
            NSLayoutConstraint.activate([
                textScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                textScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                textScroll.topAnchor.constraint(equalTo: root.topAnchor),
                textScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }

        view = root
        render()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeChanged() {
        let theme = ThemeManager.shared.current
        view.setBackground(theme.editorBackground)
        textView.backgroundColor = theme.editorBackground
        fileTable?.backgroundColor = theme.sidebarBackground
        render()
    }

    private func render() {
        guard selectedFileIndex >= 0, selectedFileIndex < diffs.count else {
            textView.string = "没有可显示的差异。"
            return
        }
        let theme = ThemeManager.shared.current
        let attributed = DiffRenderer.attributedString(for: diffs[selectedFileIndex], theme: theme)
        textView.textStorage?.setAttributedString(attributed)
    }
}

extension DiffViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { diffs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("DiffFileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            label.font = Fonts.ui(size: 11.5)
            v.addSubview(label)
            v.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }()

        let diff = diffs[row]
        let theme = ThemeManager.shared.current
        cell.textField?.stringValue = (diff.path as NSString).lastPathComponent
        cell.textField?.textColor = diff.isDeleted ? theme.diffRemovedText : theme.text
        cell.toolTip = diff.path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = fileTable?.selectedRow ?? 0
        guard row >= 0 else { return }
        selectedFileIndex = row
        render()
    }
}
