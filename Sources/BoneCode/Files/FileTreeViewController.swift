import AppKit
import CoreServices

// MARK: - Node

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    private(set) var isLoaded = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    func loadChildren() -> [FileNode] {
        if isLoaded, let children { return children }
        guard isDirectory else { return [] }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
            isLoaded = true
            children = []
            return []
        }
        var nodes: [FileNode] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if FileManager.ignoredFileNames.contains(name) { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, FileManager.ignoredDirectoryNames.contains(name) { continue }
            if name.hasPrefix(".") { continue }
            nodes.append(FileNode(url: entry, isDirectory: isDir))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children = nodes
        isLoaded = true
        return nodes
    }

    func invalidate() {
        isLoaded = false
        children = nil
        for child in children ?? [] { child.invalidate() }
    }
}

// MARK: - File watching

/// FSEvents-backed recursive directory watcher.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    private let debouncer = Debouncer(delay: 0.45)
    private let queue = DispatchQueue(label: "bonecode.fswatch")
    private var isRunning = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.debouncer.schedule { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        isRunning = true
    }

    func stop() {
        guard let stream, isRunning else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        isRunning = false
    }
}

// MARK: - Cell

private final class FileCellView: NSTableCellView {
    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = Fonts.ui(size: 12)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = Fonts.code(size: 10, bold: true)
        badge.alignment = .center

        addSubview(iconView)
        addSubview(label)
        addSubview(badge)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - Controller

final class FileTreeViewController: NSViewController, NSMenuItemValidation {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "项目")
    private let filterField = NSSearchField()
    private var rootNode: FileNode?
    private var watcher: FileWatcher?
    private var filteredResults: [FileNode] = []
    private var isFiltering = false
    private var gitStatusMap: [String: GitFileStatus] = [:]
    private var gitRootPath: String?

    private let refreshDebouncer = Debouncer(delay: 0.2)

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView()
        root.setBackground(ThemeManager.shared.current.sidebarBackground)

        headerLabel.font = Fonts.ui(size: 11, weight: .semibold)
        headerLabel.textColor = ThemeManager.shared.current.secondaryText
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = "筛选文件"
        filterField.font = Fonts.ui(size: 11)
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.backgroundColor = ThemeManager.shared.current.sidebarBackground
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.target = self
        outlineView.action = #selector(itemClicked)
        outlineView.menu = buildContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerLabel)
        root.addSubview(filterField)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            headerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),

            filterField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            filterField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 5),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged(_:)),
                                               name: .gitStatusDidChange, object: nil)
    }

    deinit {
        watcher?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeChanged() {
        let theme = ThemeManager.shared.current
        view.setBackground(theme.sidebarBackground)
        outlineView.backgroundColor = theme.sidebarBackground
        headerLabel.textColor = theme.secondaryText
        outlineView.reloadData()
    }

    @objc private func gitStatusChanged(_ note: Notification) {
        guard let state = note.object as? GitRepoState else {
            gitStatusMap = [:]
            gitRootPath = nil
            outlineView.reloadData()
            return
        }
        // Keyed by path relative to the repository root so the badges still line
        // up when the opened folder is a subdirectory of the repository.
        gitRootPath = state.root
        var map: [String: GitFileStatus] = [:]
        for change in state.changes {
            map[change.path] = change.isConflicted
                ? .conflicted
                : (change.hasUnstaged ? change.unstaged : change.staged)
        }
        gitStatusMap = map
        outlineView.reloadData()
    }

    /// Resolve a tree node to its git status.
    ///
    /// The map is keyed by repository-relative paths, but the tree is rooted at
    /// the opened folder — which may be a subdirectory, or may differ from the
    /// repository root by a resolved symlink (`/var` vs `/private/var`). Try
    /// each candidate prefix before giving up.
    private func statusForNode(_ node: FileNode) -> GitFileStatus? {
        let nodePath = node.path
        var prefixes: [String] = []
        if let root = rootNode { prefixes.append(root.path) }
        if let gitRoot = gitRootPath { prefixes.append(gitRoot) }

        for prefix in prefixes where nodePath.hasPrefix(prefix + "/") {
            let relative = String(nodePath.dropFirst(prefix.count + 1))
            if let status = gitStatusMap[relative] { return status }
        }
        if let gitRoot = gitRootPath {
            let resolved = PathNormalizer.realPath(nodePath)
            if resolved.hasPrefix(gitRoot + "/") {
                return gitStatusMap[String(resolved.dropFirst(gitRoot.count + 1))]
            }
        }
        return nil
    }

    // MARK: Root

    func setRoot(_ url: URL?) {
        watcher?.stop()
        watcher = nil

        guard let url else {
            rootNode = nil
            headerLabel.stringValue = "项目"
            outlineView.reloadData()
            return
        }

        let node = FileNode(url: url, isDirectory: true)
        rootNode = node
        headerLabel.stringValue = url.lastPathComponent
        _ = node.loadChildren()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: false)
        for child in node.children ?? [] where child.isDirectory {
            outlineView.expandItem(child)
            break
        }

        let w = FileWatcher(path: url.path) { [weak self] in
            self?.refreshDebouncer.schedule { self?.refresh() }
        }
        w.start()
        watcher = w
    }

    func refresh() {
        guard let root = rootNode else { return }
        root.invalidate()
        _ = root.loadChildren()
        if isFiltering { applyFilter(filterField.stringValue) }
        outlineView.reloadData()
    }

    // MARK: Filtering

    @objc private func filterChanged() {
        applyFilter(filterField.stringValue)
    }

    private func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let root = rootNode else {
            isFiltering = false
            filteredResults = []
            outlineView.reloadData()
            return
        }
        isFiltering = true
        let needle = trimmed.lowercased()
        var results: [FileNode] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root.url,
                                          includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if results.count > 400 { break }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if FileManager.ignoredDirectoryNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if url.lastPathComponent.lowercased().contains(needle)
                    || url.path.lowercased().contains(needle) {
                    results.append(FileNode(url: url, isDirectory: false))
                }
            }
        }
        filteredResults = results
        outlineView.reloadData()
    }

    // MARK: Clicking

    @objc private func itemClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory, !isFiltering {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            NotificationCenter.default.post(name: .openFileRequested, object: node.url)
        }
    }

    func selectedNode() -> FileNode? {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return rootNode }
        return node
    }

    // MARK: Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let newFile = NSMenuItem(title: "新建文件…", action: #selector(newFileAction), keyEquivalent: "")
        newFile.target = self
        menu.addItem(newFile)

        let newFolder = NSMenuItem(title: "新建文件夹…", action: #selector(newFolderAction), keyEquivalent: "")
        newFolder.target = self
        menu.addItem(newFolder)

        menu.addItem(.separator())

        let rename = NSMenuItem(title: "重命名…", action: #selector(renameAction), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        let duplicate = NSMenuItem(title: "复制一份", action: #selector(duplicateAction), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)

        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealAction), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let copyPath = NSMenuItem(title: "复制完整路径", action: #selector(copyPathAction), keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)

        let terminal = NSMenuItem(title: "在此处打开终端", action: #selector(openTerminalAction), keyEquivalent: "")
        terminal.target = self
        menu.addItem(terminal)

        menu.addItem(.separator())

        let trash = NSMenuItem(title: "移到废纸篓", action: #selector(trashAction), keyEquivalent: "")
        trash.target = self
        menu.addItem(trash)

        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(renameAction), #selector(trashAction), #selector(duplicateAction),
             #selector(revealAction), #selector(copyPathAction), #selector(openTerminalAction):
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            return row >= 0
        case #selector(newFileAction), #selector(newFolderAction):
            return rootNode != nil
        default:
            return true
        }
    }

    private func targetDirectory() -> URL? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return rootNode?.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    @objc private func newFileAction() {
        guard let dir = targetDirectory() else { return }
        guard let name = promptForName(title: "新建文件", placeholder: "文件名，例如 App.java") else { return }
        let target = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            presentError("同名文件已存在")
            return
        }
        do {
            try Data().write(to: target)
            refresh()
            NotificationCenter.default.post(name: .openFileRequested, object: target)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func newFolderAction() {
        guard let dir = targetDirectory() else { return }
        guard let name = promptForName(title: "新建文件夹", placeholder: "文件夹名") else { return }
        let target = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            refresh()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func renameAction() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        guard let name = promptForName(title: "重命名", placeholder: node.name, initial: node.name) else { return }
        let target = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: target)
            refresh()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func duplicateAction() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        let base = node.url.deletingPathExtension().lastPathComponent
        let ext = node.url.pathExtension
        var candidate = node.url.deletingLastPathComponent().appendingPathComponent("\(base) 副本.\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = node.url.deletingLastPathComponent().appendingPathComponent("\(base) 副本 \(counter).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: node.url, to: candidate)
            refresh()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func revealAction() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPathAction() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(node.path, forType: .string)
        NotificationCenter.default.post(name: .statusMessage, object: "已复制路径")
    }

    @objc private func openTerminalAction() {
        guard let dir = targetDirectory() else { return }
        NotificationCenter.default.post(name: .terminalSendText, object: "cd \"\(dir.path)\"\n")
    }

    @objc private func trashAction() {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        let alert = NSAlert()
        alert.messageText = "确定要移到废纸篓吗？"
        alert.informativeText = "\(node.path)\n\n文件会先进入废纸篓，可以从废纸篓恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            refresh()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func promptForName(title: String, placeholder: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - Outline data source / delegate

extension FileTreeViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if isFiltering { return item == nil ? filteredResults.count : 0 }
        guard let node = item as? FileNode else {
            return rootNode?.children?.count ?? 0
        }
        return node.loadChildren().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if isFiltering { return filteredResults[index] }
        guard let node = item as? FileNode else {
            return rootNode?.children?[index] as Any
        }
        return node.loadChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if isFiltering { return false }
        return (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FileCellView) ?? {
            let v = FileCellView()
            v.identifier = id
            return v
        }()

        let theme = ThemeManager.shared.current
        let symbol = node.isDirectory ? "folder" : FileIcons.symbolName(for: node.url)
        let color = node.isDirectory ? theme.accent : FileIcons.color(for: node.url, theme: theme)
        if let image = Icons.symbol(symbol, size: 12.5) {
            cell.iconView.image = image
            cell.iconView.contentTintColor = color
        }
        cell.label.stringValue = node.name
        cell.label.textColor = theme.text
        cell.toolTip = node.path

        // Git status badge
        if let status = statusForNode(node), !node.isDirectory {
            cell.badge.stringValue = status.letter
            cell.badge.textColor = status.color(theme)
            cell.badge.isHidden = false
        } else {
            cell.badge.isHidden = true
        }

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !isFiltering
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Children are loaded lazily on demand.
    }
}
