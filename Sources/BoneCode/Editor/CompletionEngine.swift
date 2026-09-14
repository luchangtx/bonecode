import AppKit

enum CompletionKind: String {
    case keyword, type, function, variable, snippet, symbol, constant, property, module

    /// Lower rank sorts first inside an equal match score.
    var rank: Int {
        switch self {
        case .snippet: return 0
        case .symbol: return 1
        case .type: return 2
        case .function: return 3
        case .variable: return 4
        case .property: return 5
        case .constant: return 6
        case .keyword: return 7
        case .module: return 8
        }
    }

    var iconName: String {
        switch self {
        case .keyword: return "k"
        case .type: return "C"
        case .function: return "M"
        case .variable: return "V"
        case .snippet: return "S"
        case .symbol: return "F"
        case .constant: return "K"
        case .property: return "P"
        case .module: return "N"
        }
    }

    var displayName: String {
        switch self {
        case .keyword: return "关键字"
        case .type: return "类型"
        case .function: return "方法"
        case .variable: return "变量"
        case .snippet: return "代码片段"
        case .symbol: return "符号"
        case .constant: return "常量"
        case .property: return "属性"
        case .module: return "模块"
        }
    }
}

struct CompletionItem {
    let label: String
    let insertText: String
    let kind: CompletionKind
    let detail: String?
}

/// A symbol discovered while scanning the project.
struct ProjectSymbol {
    let name: String
    let kind: CompletionKind
    let detail: String
}

// MARK: - Engine

final class CompletionEngine {

    static let shared = CompletionEngine()

    private var symbolsByName: [String: ProjectSymbol] = [:]
    private let symbolLock = NSLock()
    private var indexedRoot: String?
    private(set) var indexedFileCount = 0

    private static let codeExtensions: Set<String> = [
        "java", "kt", "kts", "groovy", "scala", "swift", "m", "mm", "c", "h", "cpp", "cc", "hpp",
        "cs", "go", "rs", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "py", "rb",
        "php", "lua", "sh", "bash", "zsh", "sql", "html", "css", "scss"
    ]

    // MARK: Project index

    func indexProject(root: URL, completion: (() -> Void)? = nil) {
        let path = root.path
        if indexedRoot == path, indexedFileCount > 0 {
            completion?()
            return
        }
        indexedRoot = path

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var found: [String: ProjectSymbol] = [:]
            var fileCount = 0
            let fm = FileManager.default
            var budget = 6 * 1024 * 1024   // bytes of source we are willing to read

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { completion?(); return }

            for case let url as URL in enumerator {
                if fileCount > 1200 || budget <= 0 { break }
                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if FileManager.ignoredDirectoryNames.contains(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard Self.codeExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0, size < 900_000 else { continue }
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
                budget -= data.count
                fileCount += 1
                Self.extractSymbols(from: text, path: url, into: &found)
            }

            self.symbolLock.lock()
            self.symbolsByName = found
            self.indexedFileCount = fileCount
            self.symbolLock.unlock()
            DispatchQueue.main.async { completion?() }
        }
    }

    func invalidateIndex() {
        symbolLock.lock()
        indexedRoot = nil
        symbolsByName = [:]
        indexedFileCount = 0
        symbolLock.unlock()
    }

    private static func extractSymbols(from text: String, path: URL, into out: inout [String: ProjectSymbol]) {
        let short = path.lastPathComponent
        let patterns: [(String, CompletionKind)] = [
            (#"\b(?:class|interface|enum|struct|record|trait|protocol|object|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .type),
            (#"\b(?:func|fun|function|def|fn|sub)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .function),
            (#"\b(?:const|let|val|var|static\s+final|final)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .variable),
            (#"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^)]*\))?\s*(?:async\s*)?\([^)]*\)\s*(?:=>|\{)"#, .function),
            (#"^\s*([A-Z][A-Za-z0-9_]{2,})\s*[:=]"#, .constant)
        ]
        let ns = text as NSString
        let whole = NSRange(location: 0, length: min(ns.length, 200_000))
        for (pattern, kind) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            let matches = re.matches(in: text, options: [], range: whole)
            for m in matches where m.numberOfRanges > 1 {
                let r = m.range(at: 1)
                guard r.location != NSNotFound, r.length >= 2, r.length <= 48 else { continue }
                let name = ns.substring(with: r)
                if out[name] == nil {
                    out[name] = ProjectSymbol(name: name, kind: kind, detail: short)
                }
                if out.count > 6000 { return }
            }
        }
    }

    func symbols(matching prefix: String, limit: Int) -> [ProjectSymbol] {
        symbolLock.lock()
        let all = symbolsByName
        symbolLock.unlock()
        guard !all.isEmpty else { return [] }
        var result: [ProjectSymbol] = []
        if prefix.isEmpty {
            for (_, s) in all.prefix(limit) { result.append(s) }
            return result
        }
        let lower = prefix.lowercased()
        for (name, s) in all {
            if name.hasPrefix(prefix) {
                result.append(s)
                if result.count >= limit { return result }
            } else if name.lowercased().hasPrefix(lower) {
                result.append(s)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    // MARK: Suggestions

    func suggestions(
        prefix: String,
        language: Language,
        documentWords: [String: Int],
        memberWords: Set<String>,
        isMemberAccess: Bool,
        fileURL: URL?,
        limit: Int = 200
    ) -> [CompletionItem] {
        var scored: [(item: CompletionItem, score: Int)] = []
        let lowerPrefix = prefix.lowercased()
        let seen = NSMutableSet()

        func push(_ item: CompletionItem, base: Int) {
            guard !seen.contains(item.label) else { return }
            let l = item.label.lowercased()
            var match: Int
            if prefix.isEmpty {
                match = 5
            } else if item.label.hasPrefix(prefix) {
                match = 40
            } else if l.hasPrefix(lowerPrefix) {
                match = 30
            } else if l.contains(lowerPrefix) {
                match = 12
            } else {
                return
            }
            // Shorter names win ties — they are usually what you meant.
            let lengthPenalty = min(item.label.count, 30)
            seen.add(item.label)
            scored.append((item, base + match * 10 - lengthPenalty))
        }

        // 1. Snippets
        if let list = Snippets.forLanguage(language.id) {
            for s in list {
                if prefix.isEmpty || s.label.lowercased().hasPrefix(lowerPrefix) {
                    push(CompletionItem(label: s.label, insertText: s.body, kind: .snippet, detail: s.detail), base: 1000)
                }
            }
        }

        // 2. Project symbols
        for sym in symbols(matching: prefix, limit: 120) {
            push(CompletionItem(label: sym.name, insertText: sym.name, kind: sym.kind, detail: sym.detail), base: 800)
        }

        // 3. Member access → prefer things seen after a dot, plus builtins
        if isMemberAccess {
            for w in memberWords where w.hasPrefix(prefix) || prefix.isEmpty {
                push(CompletionItem(label: w, insertText: w, kind: .property, detail: "成员"), base: 700)
            }
        }

        // 4. Words already present in this document, ranked by frequency
        if !documentWords.isEmpty {
            for (word, freq) in documentWords {
                guard word.count >= 2, word.count <= 48 else { continue }
                let l = word.lowercased()
                let matches = prefix.isEmpty ? false : (word.hasPrefix(prefix) || l.hasPrefix(lowerPrefix))
                if matches {
                    push(CompletionItem(label: word, insertText: word, kind: .variable, detail: "本文件 ×\(freq)"),
                         base: 500 + min(freq, 20) * 3)
                }
            }
        }

        // 5. Language vocabulary
        for kw in language.keywords {
            push(CompletionItem(label: kw, insertText: kw, kind: .keyword, detail: language.displayName), base: 300)
        }
        for t in language.types {
            push(CompletionItem(label: t, insertText: t, kind: .type, detail: language.displayName), base: 320)
        }
        for f in language.builtins {
            push(CompletionItem(label: f, insertText: f, kind: .function, detail: "内置"), base: 310)
        }
        for c in language.constants {
            push(CompletionItem(label: c, insertText: c, kind: .constant, detail: language.displayName), base: 305)
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.item.kind.rank != b.item.kind.rank { return a.item.kind.rank < b.item.kind.rank }
            return a.item.label < b.item.label
        }
        return scored.prefix(limit).map { $0.item }
    }

    // MARK: Document scanning helpers

    /// Frequency map of identifiers in a document, used to prefer local names.
    static func buildWordFrequency(_ text: String) -> [String: Int] {
        var freq: [String: Int] = [:]
        guard text.utf16.count <= 2_000_000 else { return freq }
        let u = Array(text.utf16)
        let n = u.count
        var i = 0
        while i < n {
            let c = u[i]
            let isStart = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
            if !isStart { i += 1; continue }
            var j = i
            while j < n {
                let d = u[j]
                let ok = (d >= 0x41 && d <= 0x5A) || (d >= 0x61 && d <= 0x7A)
                    || (d >= 0x30 && d <= 0x39) || d == 0x5F || d == 0x24 || d >= 0x80
                if !ok { break }
                j += 1
            }
            let len = j - i
            if len >= 2, len <= 48 {
                let word = String(decoding: u[i..<j], as: UTF16.self)
                freq[word, default: 0] += 1
            }
            i = max(j, i + 1)
        }
        // Keep the map small: the top 3000 identifiers are plenty.
        if freq.count > 3000 {
            var trimmed: [String: Int] = [:]
            trimmed.reserveCapacity(3000)
            for (k, v) in freq.sorted(by: { $0.value > $1.value }).prefix(3000) {
                trimmed[k] = v
            }
            return trimmed
        }
        return freq
    }

    /// Identifiers that appear immediately after a `.` — a cheap proxy for members.
    static func buildMemberWords(_ text: String) -> Set<String> {
        var out: Set<String> = []
        guard text.utf16.count <= 1_500_000 else { return out }
        let u = Array(text.utf16)
        let n = u.count
        var i = 0
        while i < n {
            if u[i] == 0x2E, i + 1 < n {
                var j = i + 1
                let first = u[j]
                let isStart = (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) || first == 0x5F
                if isStart {
                    while j < n {
                        let d = u[j]
                        let ok = (d >= 0x41 && d <= 0x5A) || (d >= 0x61 && d <= 0x7A)
                            || (d >= 0x30 && d <= 0x39) || d == 0x5F
                        if !ok { break }
                        j += 1
                    }
                    if j - i - 1 >= 2 {
                        out.insert(String(decoding: u[(i + 1)..<j], as: UTF16.self))
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return out
    }
}

// MARK: - Snippets

struct Snippet {
    let label: String
    let body: String
    let detail: String
}

enum Snippets {

    static func forLanguage(_ id: String) -> [Snippet]? { table[id] }

    private static let table: [String: [Snippet]] = [
        "java": [
            Snippet(label: "psvm", body: "public static void main(String[] args) {\n    |\n}", detail: "主方法"),
            Snippet(label: "sout", body: "System.out.println(|);", detail: "打印"),
            Snippet(label: "soutv", body: "System.out.println(\"| = \" + );", detail: "打印变量"),
            Snippet(label: "fori", body: "for (int i = 0; i < |; i++) {\n    \n}", detail: "for 循环"),
            Snippet(label: "foreach", body: "for (var item : collection) {\n    |\n}", detail: "增强 for"),
            Snippet(label: "try", body: "try {\n    |\n} catch (Exception e) {\n    e.printStackTrace();\n}", detail: "try-catch"),
            Snippet(label: "class", body: "public class | {\n    \n}", detail: "类"),
            Snippet(label: "if", body: "if (|) {\n    \n}", detail: "if"),
            Snippet(label: "log", body: "log.info(\"|\", );", detail: "日志")
        ],
        "kotlin": [
            Snippet(label: "main", body: "fun main() {\n    |\n}", detail: "入口"),
            Snippet(label: "fun", body: "fun |() {\n    \n}", detail: "函数"),
            Snippet(label: "data", body: "data class |(\n    \n)", detail: "数据类"),
            Snippet(label: "when", body: "when (|) {\n    else -> \n}", detail: "when"),
            Snippet(label: "forin", body: "for (item in |) {\n    \n}", detail: "for-in"),
            Snippet(label: "lazy", body: "val | by lazy {  }", detail: "lazy")
        ],
        "swift": [
            Snippet(label: "func", body: "func |() {\n    \n}", detail: "函数"),
            Snippet(label: "guard", body: "guard let | = else { return }", detail: "guard let"),
            Snippet(label: "iflet", body: "if let | =  {\n    \n}", detail: "if let"),
            Snippet(label: "struct", body: "struct | {\n    \n}", detail: "结构体"),
            Snippet(label: "closure", body: "{ | in\n    \n}", detail: "闭包")
        ],
        "javascript": jsSnippets,
        "typescript": jsSnippets,
        "vue": [
            Snippet(label: "ref", body: "const | = ref()", detail: "Vue ref"),
            Snippet(label: "reactive", body: "const | = reactive({\n    \n})", detail: "reactive"),
            Snippet(label: "computed", body: "const | = computed(() => )", detail: "computed"),
            Snippet(label: "watch", body: "watch(, (newVal, oldVal) => {\n    |\n})", detail: "watch"),
            Snippet(label: "onMounted", body: "onMounted(() => {\n    |\n})", detail: "生命周期"),
            Snippet(label: "props", body: "const props = defineProps({\n    |\n})", detail: "defineProps"),
            Snippet(label: "emits", body: "const emit = defineEmits([|])", detail: "defineEmits"),
            Snippet(label: "vfor", body: "v-for=\"(item, index) in |\" :key=\"index\"", detail: "v-for"),
            Snippet(label: "vif", body: "v-if=\"|\"", detail: "v-if"),
            Snippet(label: "template", body: "<template>\n    |\n</template>", detail: "模板")
        ],
        "html": [
            Snippet(label: "html5", body: "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n    <meta charset=\"UTF-8\">\n    <title>|</title>\n</head>\n<body>\n    \n</body>\n</html>", detail: "HTML5 骨架"),
            Snippet(label: "div", body: "<div class=\"|\"></div>", detail: "div"),
            Snippet(label: "a", body: "<a href=\"|\"></a>", detail: "链接"),
            Snippet(label: "img", body: "<img src=\"|\" alt=\"\">", detail: "图片"),
            Snippet(label: "input", body: "<input type=\"|\" name=\"\">", detail: "输入框"),
            Snippet(label: "script", body: "<script>\n    |\n</script>", detail: "脚本")
        ],
        "css": [
            Snippet(label: "flex", body: "display: flex;\nalign-items: center;\njustify-content: |;", detail: "flex 布局"),
            Snippet(label: "grid", body: "display: grid;\ngrid-template-columns: |;", detail: "grid 布局"),
            Snippet(label: "transition", body: "transition: all 0.2s ease|;", detail: "过渡"),
            Snippet(label: "media", body: "@media (max-width: |px) {\n    \n}", detail: "媒体查询"),
            Snippet(label: "center", body: "position: absolute;\ntop: 50%;\nleft: 50%;\ntransform: translate(-50%, -50%);|", detail: "绝对居中")
        ],
        "python": [
            Snippet(label: "def", body: "def |():\n    ", detail: "函数"),
            Snippet(label: "class", body: "class |:\n    def __init__(self):\n        ", detail: "类"),
            Snippet(label: "ifmain", body: "if __name__ == \"__main__\":\n    |", detail: "入口判断"),
            Snippet(label: "for", body: "for item in |:\n    ", detail: "for"),
            Snippet(label: "try", body: "try:\n    |\nexcept Exception as e:\n    print(e)", detail: "try-except"),
            Snippet(label: "with", body: "with open(\"|\") as f:\n    ", detail: "with")
        ],
        "go": [
            Snippet(label: "func", body: "func |() {\n    \n}", detail: "函数"),
            Snippet(label: "main", body: "func main() {\n    |\n}", detail: "入口"),
            Snippet(label: "struct", body: "type | struct {\n    \n}", detail: "结构体"),
            Snippet(label: "iferr", body: "if err != nil {\n    return err\n}|", detail: "错误处理")
        ],
        "rust": [
            Snippet(label: "fn", body: "fn |() {\n    \n}", detail: "函数"),
            Snippet(label: "main", body: "fn main() {\n    |\n}", detail: "入口"),
            Snippet(label: "impl", body: "impl | {\n    \n}", detail: "impl"),
            Snippet(label: "match", body: "match | {\n    _ => {}\n}", detail: "match")
        ],
        "shell": [
            Snippet(label: "shebang", body: "#!/usr/bin/env bash\nset -euo pipefail\n|", detail: "脚本头"),
            Snippet(label: "for", body: "for f in |; do\n    \ndone", detail: "for"),
            Snippet(label: "if", body: "if [ | ]; then\n    \nfi", detail: "if"),
            Snippet(label: "func", body: "function |() {\n    \n}", detail: "函数")
        ],
        "sql": [
            Snippet(label: "select", body: "SELECT |\nFROM \nWHERE ", detail: "查询"),
            Snippet(label: "insert", body: "INSERT INTO | (col1, col2)\nVALUES (v1, v2);", detail: "插入"),
            Snippet(label: "update", body: "UPDATE |\nSET col = value\nWHERE id = 1;", detail: "更新"),
            Snippet(label: "create", body: "CREATE TABLE | (\n    id BIGINT PRIMARY KEY AUTO_INCREMENT\n);", detail: "建表")
        ]
    ]

    private static let jsSnippets: [Snippet] = [
        Snippet(label: "log", body: "console.log(|)", detail: "打印"),
        Snippet(label: "fn", body: "function |() {\n    \n}", detail: "函数"),
        Snippet(label: "arrow", body: "const | = () => {\n    \n}", detail: "箭头函数"),
        Snippet(label: "async", body: "async function |() {\n    \n}", detail: "异步函数"),
        Snippet(label: "promise", body: "new Promise((resolve, reject) => {\n    |\n})", detail: "Promise"),
        Snippet(label: "try", body: "try {\n    |\n} catch (err) {\n    console.error(err)\n}", detail: "try-catch"),
        Snippet(label: "import", body: "import { | } from ''", detail: "import"),
        Snippet(label: "map", body: "arr.map((item) => |)", detail: "map"),
        Snippet(label: "filter", body: "arr.filter((item) => |)", detail: "filter"),
        Snippet(label: "fetch", body: "const res = await fetch('|')\nconst data = await res.json()", detail: "fetch")
    ]
}
