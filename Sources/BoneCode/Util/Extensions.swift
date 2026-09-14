import AppKit
import Foundation

// MARK: - NSColor helpers

extension NSColor {
    /// Build a color from a 0xRRGGBB literal.
    static func hex(_ value: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    /// Blend two colors; `t` = 0 returns self, `t` = 1 returns other.
    func blended(with other: NSColor, fraction t: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
        )
    }

    /// A slightly stronger version of the color, for hover states.
    var hovered: NSColor { blended(with: .black, fraction: 0.06) }
    var pressed: NSColor { blended(with: .black, fraction: 0.12) }
}

// MARK: - Fonts

enum Fonts {
    /// Preferred monospaced coding fonts, in order of preference.
    private static let codeCandidates = [
        "JetBrains Mono", "Fira Code", "Cascadia Code", "SF Mono",
        "Menlo", "Monaco", "Hack", "Source Code Pro"
    ]

    static func code(size: CGFloat, bold: Bool = false) -> NSFont {
        for name in codeCandidates {
            if let f = NSFont(name: name, size: size) {
                if bold {
                    let d = f.fontDescriptor.withSymbolicTraits(.bold)
                    return NSFont(descriptor: d, size: size) ?? f
                }
                return f
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func ui(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func icon(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - NSView helpers

extension NSView {
    /// Pin a subview to the receiver's edges.
    func pin(_ child: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }

    func setBackground(_ color: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSStackView {
    static func horizontal(spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView()
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func vertical(spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = spacing
        s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
}

// MARK: - String helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var firstLine: String {
        if let r = range(of: "\n") { return String(self[..<r.lowerBound]) }
        return self
    }

    func truncatedMiddle(to limit: Int) -> String {
        guard count > limit, limit > 8 else { return self }
        let keep = (limit - 1) / 2
        return "\(prefix(keep))…\(suffix(keep))"
    }

    /// Shorten a path for display: /a/b/c/d/File.swift -> …/c/d/File.swift
    func abbreviatedPath(maxComponents: Int = 3) -> String {
        let comps = split(separator: "/").map(String.init)
        guard comps.count > maxComponents else { return self }
        return "…/" + comps.suffix(maxComponents).joined(separator: "/")
    }
}

// MARK: - NSImage helpers

enum Icons {
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }
}

// MARK: - Paths

enum PathNormalizer {
    /// `realpath(3)`-style resolution.
    ///
    /// `NSString.resolvingSymlinksInPath` intentionally normalises
    /// `/private/var/...` back to `/var/...`, so it disagrees with what `git`
    /// prints. We need git's answer to line up file-tree rows with statuses.
    static func realPath(_ path: String) -> String {
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            return (path as NSString).resolvingSymlinksInPath
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when two paths point at the same filesystem object.
    static func isSameLocation(_ a: String, _ b: String) -> Bool {
        var statA = stat()
        var statB = stat()
        guard stat(a, &statA) == 0, stat(b, &statB) == 0 else { return a == b }
        return statA.st_dev == statB.st_dev && statA.st_ino == statB.st_ino
    }
}

// MARK: - FileManager helpers

extension FileManager {
    /// Directories that should never show up in the project tree.
    static let ignoredDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "target", "build", "dist",
        ".idea", ".vscode", "__pycache__", ".gradle", ".mvn", "out", "bin",
        ".next", ".nuxt", "coverage", ".venv", "venv", "Pods", "DerivedData",
        ".DS_Store", ".cache", "vendor"
    ]

    static let ignoredFileNames: Set<String> = [".DS_Store", ".gitkeep"]

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    func fileSize(at path: String) -> Int64 {
        (try? attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }
}

// MARK: - Misc

/// A closure-based target/action helper so we don't need @objc selectors everywhere.
final class ActionProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Simple debouncer used for syntax highlighting / file watching.
final class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func schedule(_ block: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: block)
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let themeDidChange = Notification.Name("BoneCode.themeDidChange")
    static let gitStatusDidChange = Notification.Name("BoneCode.gitStatusDidChange")
    static let openFileRequested = Notification.Name("BoneCode.openFileRequested")
    static let showDiffRequested = Notification.Name("BoneCode.showDiffRequested")
    static let runConfigRequested = Notification.Name("BoneCode.runConfigRequested")
    static let aiPanelToggle = Notification.Name("BoneCode.aiPanelToggle")
    static let editorDidSave = Notification.Name("BoneCode.editorDidSave")
    static let activeEditorDidChange = Notification.Name("BoneCode.activeEditorDidChange")

    // Welcome screen actions
    static let welcomeOpenFolder = Notification.Name("BoneCode.welcomeOpenFolder")
    static let welcomeNewFile = Notification.Name("BoneCode.welcomeNewFile")
    static let welcomeOpenPath = Notification.Name("BoneCode.welcomeOpenPath")

    // Workspace
    static let workspaceDidChange = Notification.Name("BoneCode.workspaceDidChange")
    static let fileTreeDidChange = Notification.Name("BoneCode.fileTreeDidChange")
    static let quickOpenRequested = Notification.Name("BoneCode.quickOpenRequested")

    // Panels
    static let toggleTerminal = Notification.Name("BoneCode.toggleTerminal")
    /// Expand the terminal panel without creating a session. Used before a run
    /// so the new session is sized against the real panel.
    static let revealTerminal = Notification.Name("BoneCode.revealTerminal")
    static let toggleGitPanel = Notification.Name("BoneCode.toggleGitPanel")
    static let toggleAIPanel = Notification.Name("BoneCode.toggleAIPanel")
    static let toggleSidebar = Notification.Name("BoneCode.toggleSidebar")

    // Runner
    static let runProject = Notification.Name("BoneCode.runProject")
    static let stopProject = Notification.Name("BoneCode.stopProject")
    static let runConfigsChanged = Notification.Name("BoneCode.runConfigsChanged")

    // AI
    static let aiApplyEditRequested = Notification.Name("BoneCode.aiApplyEditRequested")
    static let aiInsertCommandRequested = Notification.Name("BoneCode.aiInsertCommandRequested")
    static let terminalSendText = Notification.Name("BoneCode.terminalSendText")

    // Status
    static let statusMessage = Notification.Name("BoneCode.statusMessage")
}

// MARK: - Layout constants

enum Metrics {
    static let toolbarHeight: CGFloat = 38
    static let tabHeight: CGFloat = 30
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 250
    static let aiPanelWidth: CGFloat = 340
    static let statusBarHeight: CGFloat = 22
    static let gutterWidth: CGFloat = 52
}
