import AppKit

/// Semantic roles the syntax highlighter assigns to token spans.
enum SyntaxRole {
    case plain
    case keyword
    case string
    case number
    case comment
    case function
    case type
    case annotation
    case tag
    case attribute
    case constant
    case punctuation
    case variable
    case inserted
    case deleted
    case invalid
}

struct Theme {
    let id: String
    let displayName: String
    let isDark: Bool

    // Chrome
    let windowBackground: NSColor
    let sidebarBackground: NSColor
    let toolbarBackground: NSColor
    let panelBackground: NSColor
    let editorBackground: NSColor
    let gutterBackground: NSColor
    let tabBarBackground: NSColor
    let tabActiveBackground: NSColor
    let tabInactiveBackground: NSColor
    let border: NSColor
    let subtleBorder: NSColor
    let hover: NSColor
    let selection: NSColor
    let inactiveSelection: NSColor
    let currentLine: NSColor
    let accent: NSColor
    let accentSoft: NSColor

    // Text
    let text: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let gutterText: NSColor
    let gutterTextActive: NSColor
    let caretColor: NSColor

    // Syntax
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let function: NSColor
    let type: NSColor
    let annotation: NSColor
    let tag: NSColor
    let attribute: NSColor
    let constant: NSColor
    let punctuation: NSColor

    // Diff
    let diffAddedBackground: NSColor
    let diffRemovedBackground: NSColor
    let diffAddedInline: NSColor
    let diffRemovedInline: NSColor
    let diffHunkHeader: NSColor
    let diffAddedText: NSColor
    let diffRemovedText: NSColor

    // Terminal
    let terminalBackground: NSColor
    let terminalForeground: NSColor
    let terminalCursor: NSColor
    let terminalSelection: NSColor
    let ansi: [NSColor]   // 16 standard colors

    // Git status — one distinct hue per change kind, so a glance is enough
    let gitAdded: NSColor
    let gitModified: NSColor
    let gitDeleted: NSColor
    let gitRenamed: NSColor
    let gitUntracked: NSColor
    let gitConflicted: NSColor

    // Git graph lanes
    let graphLanes: [NSColor]

    func color(for role: SyntaxRole) -> NSColor {
        switch role {
        case .plain: return text
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .comment: return comment
        case .function: return function
        case .type: return type
        case .annotation: return annotation
        case .tag: return tag
        case .attribute: return attribute
        case .constant: return constant
        case .punctuation: return punctuation
        case .variable: return text
        case .inserted: return diffAddedText
        case .deleted: return diffRemovedText
        case .invalid: return NSColor.hex(0xE5484D)
        }
    }
}

// MARK: - Light theme (IDEA Light inspired, toned down)

extension Theme {
    static let light = Theme(
        id: "light",
        displayName: "Bone Light",
        isDark: false,

        windowBackground: .hex(0xFFFFFF),
        sidebarBackground: .hex(0xF7F8FA),
        toolbarBackground: .hex(0xF2F3F5),
        panelBackground: .hex(0xFAFBFC),
        editorBackground: .hex(0xFFFFFF),
        gutterBackground: .hex(0xFFFFFF),
        tabBarBackground: .hex(0xF2F3F5),
        tabActiveBackground: .hex(0xFFFFFF),
        tabInactiveBackground: .hex(0xE9EBEF),
        border: .hex(0xDDE1E6),
        subtleBorder: .hex(0xEBEDF0),
        hover: .hex(0xEDEFF3),
        selection: .hex(0xCDE0F7),
        inactiveSelection: .hex(0xE8EAEE),
        currentLine: .hex(0xF6F8FA),
        accent: .hex(0x2F6FEB),
        accentSoft: .hex(0xE1EBFD),

        text: .hex(0x1F2328),
        secondaryText: .hex(0x656D76),
        tertiaryText: .hex(0x8B949E),
        gutterText: .hex(0xA8B0B9),
        gutterTextActive: .hex(0x57606A),
        caretColor: .hex(0x1F2328),

        keyword: .hex(0x0033B3),
        string: .hex(0x067D17),
        number: .hex(0x1750EB),
        comment: .hex(0x8C8C8C),
        function: .hex(0x00627A),
        type: .hex(0x7A3E9D),
        annotation: .hex(0x9E880D),
        tag: .hex(0x0033B3),
        attribute: .hex(0x174AD4),
        constant: .hex(0x871094),
        punctuation: .hex(0x5A6270),

        diffAddedBackground: .hex(0xE6FFEC),
        diffRemovedBackground: .hex(0xFFEBE9),
        diffAddedInline: .hex(0xABF2BC),
        diffRemovedInline: .hex(0xFFC9C4),
        diffHunkHeader: .hex(0xDDF4FF),
        diffAddedText: .hex(0x1A7F37),
        diffRemovedText: .hex(0xCF222E),

        terminalBackground: .hex(0xFFFFFF),
        terminalForeground: .hex(0x24292F),
        terminalCursor: .hex(0x2F6FEB),
        terminalSelection: .hex(0xCDE0F7),
        ansi: [
            .hex(0x24292F), .hex(0xCF222E), .hex(0x116329), .hex(0x7D4E00),
            .hex(0x0969DA), .hex(0x8250DF), .hex(0x1B7C83), .hex(0x6E7781),
            .hex(0x57606A), .hex(0xA40E26), .hex(0x1A7F37), .hex(0x9A6700),
            .hex(0x218BFF), .hex(0xA475F9), .hex(0x3192AA), .hex(0x8C959F)
        ],

        gitAdded: .hex(0x1A7F37),        // green   — 新增
        gitModified: .hex(0x0969DA),     // blue    — 修改
        gitDeleted: .hex(0xCF222E),      // red     — 删除
        gitRenamed: .hex(0x8250DF),      // purple  — 重命名
        gitUntracked: .hex(0xBC4C00),    // amber   — 未跟踪（未加入 Git）
        gitConflicted: .hex(0xA40E26),   // dark red— 冲突

        graphLanes: [
            .hex(0x2F6FEB), .hex(0x1A7F37), .hex(0x8250DF), .hex(0xBC4C00),
            .hex(0x0969DA), .hex(0xCF222E), .hex(0x1B7C83), .hex(0x9A6700)
        ]
    )

    // MARK: Dark theme (Darcula inspired)

    static let dark = Theme(
        id: "dark",
        displayName: "Bone Dark",
        isDark: true,

        windowBackground: .hex(0x1E1F22),
        sidebarBackground: .hex(0x2B2D30),
        toolbarBackground: .hex(0x2B2D30),
        panelBackground: .hex(0x232529),
        editorBackground: .hex(0x1E1F22),
        gutterBackground: .hex(0x1E1F22),
        tabBarBackground: .hex(0x2B2D30),
        tabActiveBackground: .hex(0x1E1F22),
        tabInactiveBackground: .hex(0x26282C),
        border: .hex(0x3C3F41),
        subtleBorder: .hex(0x303336),
        hover: .hex(0x35373B),
        selection: .hex(0x214283),
        inactiveSelection: .hex(0x373A3D),
        currentLine: .hex(0x26282C),
        accent: .hex(0x3574F0),
        accentSoft: .hex(0x1E3A63),

        text: .hex(0xBCBEC4),
        secondaryText: .hex(0x9DA0A8),
        tertiaryText: .hex(0x7A7E85),
        gutterText: .hex(0x606366),
        gutterTextActive: .hex(0xA1A3A7),
        caretColor: .hex(0xD8DAE0),

        keyword: .hex(0xCF8E6D),
        string: .hex(0x6AAB73),
        number: .hex(0x2AACB8),
        comment: .hex(0x7A7E85),
        function: .hex(0x56A8F5),
        type: .hex(0xB5B6E3),
        annotation: .hex(0xB3AE60),
        tag: .hex(0xE8BF6A),
        attribute: .hex(0xBABABA),
        constant: .hex(0xC77DBB),
        punctuation: .hex(0x9DA0A8),

        diffAddedBackground: .hex(0x1E3A24),
        diffRemovedBackground: .hex(0x3A1F22),
        diffAddedInline: .hex(0x2F6B3C),
        diffRemovedInline: .hex(0x6E3038),
        diffHunkHeader: .hex(0x1E3550),
        diffAddedText: .hex(0x6AAB73),
        diffRemovedText: .hex(0xF75464),

        terminalBackground: .hex(0x1E1F22),
        terminalForeground: .hex(0xBCBEC4),
        terminalCursor: .hex(0x56A8F5),
        terminalSelection: .hex(0x214283),
        ansi: [
            .hex(0x3F4144), .hex(0xF75464), .hex(0x6AAB73), .hex(0xD5B778),
            .hex(0x56A8F5), .hex(0xC77DBB), .hex(0x2AACB8), .hex(0xBCBEC4),
            .hex(0x6F737A), .hex(0xFF7B86), .hex(0x8CD98F), .hex(0xE8C57A),
            .hex(0x7CB8F7), .hex(0xD7A0D0), .hex(0x4FC3CE), .hex(0xFFFFFF)
        ],

        gitAdded: .hex(0x6AAB73),
        gitModified: .hex(0x56A8F5),
        gitDeleted: .hex(0xF75464),
        gitRenamed: .hex(0xC77DBB),
        gitUntracked: .hex(0xE8BF6A),
        gitConflicted: .hex(0xFF7B86),

        graphLanes: [
            .hex(0x3574F0), .hex(0x6AAB73), .hex(0xC77DBB), .hex(0xE08855),
            .hex(0x56A8F5), .hex(0xF75464), .hex(0x2AACB8), .hex(0xD5B778)
        ]
    )
}

// MARK: - Manager

final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var current: Theme = .light
    var codeFontSize: CGFloat = 13
    var uiFontSize: CGFloat = 12

    var codeFont: NSFont { Fonts.code(size: codeFontSize) }
    var codeFontBold: NSFont { Fonts.code(size: codeFontSize, bold: true) }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "themeID"),
           let t = [Theme.light, Theme.dark].first(where: { $0.id == saved }) {
            current = t
        } else {
            // Follow the system appearance on first launch.
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            current = dark ? .dark : .light
        }
        if let size = UserDefaults.standard.object(forKey: "codeFontSize") as? Double, size >= 9, size <= 28 {
            codeFontSize = CGFloat(size)
        }
    }

    func apply(_ theme: Theme) {
        current = theme
        UserDefaults.standard.set(theme.id, forKey: "themeID")
        NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    func toggle() {
        apply(current.isDark ? .light : .dark)
    }

    func setCodeFontSize(_ size: CGFloat) {
        codeFontSize = min(28, max(9, size))
        UserDefaults.standard.set(Double(codeFontSize), forKey: "codeFontSize")
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
}
