import AppKit

/// User-tunable editor behaviour, persisted in UserDefaults.
final class EditorSettings {
    static let shared = EditorSettings()

    private let d = UserDefaults.standard

    var tabWidth: Int {
        get { d.object(forKey: "tabWidth") as? Int ?? 4 }
        set { d.set(newValue, forKey: "tabWidth") }
    }
    var useSpaces: Bool {
        get { d.object(forKey: "useSpaces") as? Bool ?? true }
        set { d.set(newValue, forKey: "useSpaces") }
    }
    var wrapLines: Bool {
        get { d.object(forKey: "wrapLines") as? Bool ?? true }
        set { d.set(newValue, forKey: "wrapLines") }
    }
    var autoCloseBrackets: Bool {
        get { d.object(forKey: "autoCloseBrackets") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoCloseBrackets") }
    }
    var highlightCurrentLine: Bool {
        get { d.object(forKey: "highlightCurrentLine") as? Bool ?? true }
        set { d.set(newValue, forKey: "highlightCurrentLine") }
    }
    var showLineNumbers: Bool {
        get { d.object(forKey: "showLineNumbers") as? Bool ?? true }
        set { d.set(newValue, forKey: "showLineNumbers") }
    }
    var highlightMatchingBracket: Bool {
        get { d.object(forKey: "highlightMatchingBracket") as? Bool ?? true }
        set { d.set(newValue, forKey: "highlightMatchingBracket") }
    }
    var autoCompletionEnabled: Bool {
        get { d.object(forKey: "autoCompletion") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoCompletion") }
    }
    var autoSaveOnRun: Bool {
        get { d.object(forKey: "autoSaveOnRun") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoSaveOnRun") }
    }

    var indentUnit: String {
        useSpaces ? String(repeating: " ", count: tabWidth) : "\t"
    }
}
