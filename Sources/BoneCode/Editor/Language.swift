import Foundation

/// Which hand-written scanner the highlighter should use for a language.
enum ScannerKind {
    case cLike        // Java / Kotlin / Swift / C / Go / Rust / Scala / JS / TS
    case hashLike     // YAML / TOML / properties / conf
    case shell
    case python
    case ruby
    case lua
    case php
    case markup       // HTML / XML / Vue / Svelte / JSP
    case css
    case json
    case markdown
    case sql
    case plain
}

struct Language {
    let id: String
    let displayName: String
    let kind: ScannerKind
    let keywords: Set<String>
    let types: Set<String>
    let constants: Set<String>
    /// Built-in / stdlib functions highlighted as `.function` even without a call paren.
    let builtins: Set<String>
    let annotationPrefix: Character?
    let stringDelimiters: [Character]
    let lineComments: [String]
    let blockComments: [(String, String)]
    /// Swift / Rust allow nested `/* /* */ */`.
    let nestedBlockComments: Bool
    /// Extra characters legal inside identifiers (e.g. `$` in JS, `?` in Ruby).
    let identifierExtra: Set<Character>
    let caseSensitive: Bool

    static let plain = Language(
        id: "plain", displayName: "Plain Text", kind: .plain,
        keywords: [], types: [], constants: [], builtins: [],
        annotationPrefix: nil, stringDelimiters: [],
        lineComments: [], blockComments: [], nestedBlockComments: false,
        identifierExtra: [], caseSensitive: true
    )
}

// MARK: - Registry

enum LanguageRegistry {

    private static let cacheLock = NSLock()
    private static var byID: [String: Language] = {
        var map: [String: Language] = [:]
        for l in all { map[l.id] = l }
        return map
    }()

    static func language(forID id: String) -> Language {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return byID[id] ?? .plain
    }

    /// Resolve a language from a file path.
    static func language(forPath path: String) -> Language {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        // Files without a useful extension, matched by name.
        switch name {
        case "dockerfile", "containerfile": return language(forID: "dockerfile")
        case "makefile", "gnumakefile": return language(forID: "makefile")
        case ".gitignore", ".gitattributes", ".dockerignore": return language(forID: "gitignore")
        case ".env", ".env.local", ".env.development": return language(forID: "properties")
        case "pom.xml": return language(forID: "xml")
        default: break
        }
        if name.hasPrefix(".env") { return language(forID: "properties") }

        switch ext {
        case "java": return language(forID: "java")
        case "kt", "kts": return language(forID: "kotlin")
        case "groovy", "gradle": return language(forID: "groovy")
        case "scala", "sc": return language(forID: "scala")
        case "swift": return language(forID: "swift")
        case "c", "h": return language(forID: "c")
        case "cpp", "cc", "cxx", "hpp", "hh", "mm": return language(forID: "cpp")
        case "cs": return language(forID: "csharp")
        case "go": return language(forID: "go")
        case "rs": return language(forID: "rust")
        case "m", "mm_objc": return language(forID: "c")
        case "js", "mjs", "cjs", "jsx": return language(forID: "javascript")
        case "ts", "tsx", "mts", "cts": return language(forID: "typescript")
        case "vue": return language(forID: "vue")
        case "svelte": return language(forID: "svelte")
        case "html", "htm": return language(forID: "html")
        case "xml", "xsd", "xsl", "xslt", "svg", "plist", "storyboard", "xib": return language(forID: "xml")
        case "jsp", "ftl", "vm", "ejs", "hbs", "mustache", "twig", "erb": return language(forID: "html")
        case "css": return language(forID: "css")
        case "scss", "sass", "less": return language(forID: "scss")
        case "json": return language(forID: "json")
        case "jsonc", "json5": return language(forID: "jsonc")
        case "yaml", "yml": return language(forID: "yaml")
        case "toml": return language(forID: "toml")
        case "properties", "ini", "cfg", "conf", "env": return language(forID: "properties")
        case "py", "pyw", "pyi": return language(forID: "python")
        case "rb", "rake", "gemspec": return language(forID: "ruby")
        case "php": return language(forID: "php")
        case "pl", "pm": return language(forID: "perl")
        case "lua": return language(forID: "lua")
        case "r": return language(forID: "r")
        case "sh", "bash", "zsh", "fish", "ksh": return language(forID: "shell")
        case "sql": return language(forID: "sql")
        case "md", "markdown", "mdx": return language(forID: "markdown")
        case "diff", "patch": return language(forID: "diff")
        case "log", "out": return language(forID: "plain")
        default: return language(forID: "plain")
        }
    }

    // MARK: Language table

    static let plain = Language.plain

    static let all: [Language] = [
        java, kotlin, groovy, scala, swift, c, cpp, csharp, go, rust,
        javascript, typescript, vue, svelte, html, xml, css, scss, json, jsonc,
        yaml, toml, properties, python, ruby, php, perl, lua, r, shell, sql,
        markdown, dockerfile, makefile, gitignore, diff, plain
    ]

    private static func mk(
        _ id: String, _ name: String, _ kind: ScannerKind,
        keywords: Set<String> = [], types: Set<String> = [], constants: Set<String> = [],
        builtins: Set<String> = [], annotation: Character? = nil,
        strings: [Character] = ["\"", "'"],
        line: [String] = ["//"], block: [(String, String)] = [("/*", "*/")],
        nested: Bool = false, extra: String = "", caseSensitive: Bool = true
    ) -> Language {
        Language(
            id: id, displayName: name, kind: kind,
            keywords: Set(keywords), types: Set(types), constants: Set(constants),
            builtins: Set(builtins), annotationPrefix: annotation,
            stringDelimiters: strings, lineComments: line, blockComments: block,
            nestedBlockComments: nested,
            identifierExtra: Set(extra), caseSensitive: caseSensitive
        )
    }

    // MARK: Java family

    static let java = mk(
        "java", "Java", .cLike,
        keywords: ["abstract", "assert", "break", "case", "catch", "class", "const", "continue",
                   "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto",
                   "if", "implements", "import", "instanceof", "interface", "native", "new",
                   "package", "private", "protected", "public", "return", "sealed", "static",
                   "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
                   "transient", "try", "volatile", "while", "yield", "record", "permits", "var",
                   "non-sealed", "module", "requires", "exports", "opens", "uses", "provides",
                   "with", "transitive", "to", "open"],
        types: ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void",
                "String", "Object", "Integer", "Long", "Double", "Float", "Boolean", "Character",
                "Byte", "Short", "List", "Map", "Set", "ArrayList", "HashMap", "HashSet",
                "Optional", "Stream", "Collection", "Iterable", "Exception", "RuntimeException",
                "Override", "Autowired", "Component", "Service", "Repository", "Controller",
                "RestController", "Configuration", "Bean", "Entity", "Table", "RequestMapping",
                "GetMapping", "PostMapping", "PutMapping", "DeleteMapping", "RequestParam",
                "RequestBody", "PathVariable", "SpringBootApplication", "EnableAutoConfiguration",
                "Transactional", "Slf4j", "Data", "Builder", "Getter", "Setter", "NoArgsConstructor",
                "AllArgsConstructor", "RequiredArgsConstructor", "Value"],
        constants: ["true", "false", "null"],
        builtins: ["System", "Math", "Arrays", "Collections", "Objects", "Stream", "Thread",
                   "StringBuilder", "BigDecimal", "BigInteger", "LocalDate", "LocalDateTime",
                   "Instant", "Duration", "UUID", "Logger", "log"],
        annotation: "@"
    )

    static let kotlin = mk(
        "kotlin", "Kotlin", .cLike,
        keywords: ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if",
                   "in", "interface", "is", "null", "object", "package", "return", "super", "this",
                   "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while",
                   "by", "catch", "constructor", "delegate", "dynamic", "field", "file", "finally",
                   "get", "import", "init", "param", "property", "receiver", "set", "setparam",
                   "where", "actual", "abstract", "annotation", "companion", "const", "crossinline",
                   "data", "enum", "expect", "external", "final", "infix", "inline", "inner",
                   "internal", "lateinit", "noinline", "open", "operator", "out", "override",
                   "private", "protected", "public", "reified", "sealed", "suspend", "tailrec",
                   "vararg", "it", "also", "apply", "let", "run", "with"],
        types: ["Int", "Long", "Double", "Float", "Boolean", "Char", "String", "Any", "Unit",
                "Nothing", "List", "MutableList", "Map", "MutableMap", "Set", "MutableSet",
                "Array", "Sequence", "Flow", "Result", "Pair", "Triple", "Lazy"],
        constants: ["true", "false", "null"],
        builtins: ["println", "print", "listOf", "mapOf", "setOf", "mutableListOf", "arrayOf",
                   "launch", "async", "await", "runBlocking", "coroutineScope", "withContext"],
        annotation: "@", strings: ["\"", "'"], nested: true
    )

    static let groovy = mk(
        "groovy", "Groovy / Gradle", .cLike,
        keywords: ["abstract", "as", "assert", "break", "case", "catch", "class", "const",
                   "continue", "def", "default", "do", "else", "enum", "extends", "final",
                   "finally", "for", "goto", "if", "implements", "import", "in", "instanceof",
                   "interface", "new", "package", "return", "super", "switch", "this", "throw",
                   "throws", "trait", "try", "while", "it", "plugins", "apply", "dependencies",
                   "repositories", "task", "sourceSets", "buildscript", "ext"],
        types: ["String", "Object", "List", "Map", "Set", "Integer", "Long", "Double", "Boolean"],
        constants: ["true", "false", "null"], builtins: ["println", "printf"],
        annotation: "@", line: ["//"], block: [("/*", "*/")], extra: "$"
    )

    static let scala = mk(
        "scala", "Scala", .cLike,
        keywords: ["abstract", "case", "catch", "class", "def", "do", "else", "extends",
                   "final", "finally", "for", "forSome", "if", "implicit", "import", "lazy",
                   "match", "new", "object", "override", "package", "private", "protected",
                   "return", "sealed", "super", "this", "throw", "trait", "try", "type", "val",
                   "var", "while", "with", "yield", "given", "using", "enum", "export", "then"],
        types: ["Int", "Long", "Double", "Float", "Boolean", "Char", "String", "Any", "Unit",
                "Nothing", "List", "Seq", "Map", "Set", "Option", "Some", "None", "Either", "Future"],
        constants: ["true", "false", "null", "None"], builtins: ["println", "print"],
        annotation: "@", nested: true
    )

    static let swift = mk(
        "swift", "Swift", .cLike,
        keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                   "func", "import", "init", "inout", "internal", "let", "open", "operator",
                   "private", "precedencegroup", "protocol", "public", "rethrows", "static",
                   "struct", "subscript", "typealias", "var", "break", "case", "catch",
                   "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
                   "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as",
                   "await", "async", "actor", "some", "any", "throws", "try", "is", "self",
                   "Self", "super", "nil", "true", "false", "convenience", "required", "weak",
                   "unowned", "lazy", "mutating", "nonmutating", "override", "final", "indirect",
                   "dynamic", "optional", "package", "consuming", "borrowing", "each", "macro"],
        types: ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "Double", "Float", "Bool",
                "String", "Character", "Array", "Dictionary", "Set", "Optional", "Result",
                "Any", "AnyObject", "Void", "Never", "Error", "URL", "Data", "Date", "NSObject"],
        constants: ["true", "false", "nil"],
        builtins: ["print", "dump", "fatalError", "assert", "precondition", "min", "max", "abs"],
        annotation: "@", nested: true
    )

    static let c = mk(
        "c", "C / Objective-C", .cLike,
        keywords: ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum",
                   "extern", "for", "goto", "if", "inline", "register", "restrict", "return",
                   "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while",
                   "interface", "implementation", "protocol", "property", "synthesize", "nonatomic",
                   "strong", "weak", "assign", "retain", "copy", "readonly", "atomic", "strong",
                   "instancetype", "id", "SEL", "IMP"],
        types: ["char", "double", "float", "int", "long", "short", "signed", "unsigned", "void",
                "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
                "uint16_t", "uint32_t", "uint64_t", "bool", "NSString", "NSArray", "NSDictionary"],
        constants: ["NULL", "nil", "YES", "NO", "true", "false", "NULL"],
        builtins: ["malloc", "free", "printf", "memcpy", "memset", "strlen", "strcmp"],
        annotation: "@", line: ["//"], block: [("/*", "*/")], nested: true
    )

    static let cpp = mk(
        "cpp", "C++", .cLike,
        keywords: ["alignas", "alignof", "asm", "auto", "break", "case", "catch", "class",
                   "concept", "const", "consteval", "constexpr", "constinit", "const_cast",
                   "continue", "co_await", "co_return", "co_yield", "decltype", "default",
                   "delete", "do", "dynamic_cast", "else", "enum", "explicit", "export", "extern",
                   "for", "friend", "goto", "if", "inline", "mutable", "namespace", "new",
                   "noexcept", "operator", "private", "protected", "public", "register",
                   "reinterpret_cast", "requires", "return", "sizeof", "static", "static_assert",
                   "static_cast", "struct", "switch", "template", "this", "thread_local", "throw",
                   "try", "typedef", "typeid", "typename", "union", "using", "virtual", "volatile",
                   "while", "override", "final", "nullptr", "true", "false"],
        types: ["bool", "char", "char8_t", "char16_t", "char32_t", "double", "float", "int",
                "long", "short", "signed", "unsigned", "void", "wchar_t", "size_t", "string",
                "vector", "map", "unordered_map", "set", "shared_ptr", "unique_ptr", "optional"],
        constants: ["true", "false", "nullptr", "NULL"],
        builtins: ["std", "cout", "cin", "cerr", "endl", "printf", "malloc", "free"],
        nested: true
    )

    static let csharp = mk(
        "csharp", "C#", .cLike,
        keywords: ["abstract", "as", "base", "break", "case", "catch", "checked", "class",
                   "const", "continue", "default", "delegate", "do", "else", "enum", "event",
                   "explicit", "extern", "finally", "fixed", "for", "foreach", "goto", "if",
                   "implicit", "in", "interface", "internal", "is", "lock", "namespace", "new",
                   "operator", "out", "override", "params", "private", "protected", "public",
                   "readonly", "ref", "return", "sealed", "sizeof", "stackalloc", "static",
                   "struct", "switch", "this", "throw", "try", "typeof", "unchecked", "unsafe",
                   "using", "virtual", "volatile", "while", "async", "await", "var", "record",
                   "init", "required", "nameof", "when", "yield", "get", "set"],
        types: ["bool", "byte", "char", "decimal", "double", "float", "int", "long", "object",
                "sbyte", "short", "string", "uint", "ulong", "ushort", "void", "dynamic",
                "Task", "List", "Dictionary", "IEnumerable", "DateTime", "Guid"],
        constants: ["true", "false", "null"], builtins: ["Console", "Math", "String", "Convert"],
        annotation: nil, nested: true
    )

    static let go = mk(
        "go", "Go", .cLike,
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else",
                   "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                   "package", "range", "return", "select", "struct", "switch", "type", "var",
                   "defer", "any", "comparable"],
        types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
                "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
                "uint32", "uint64", "uintptr", "any"],
        constants: ["true", "false", "nil", "iota"], builtins: ["make", "new", "len", "cap",
                   "append", "copy", "delete", "panic", "recover", "print", "println", "fmt"],
        strings: ["\"", "'", "`"]
    )

    static let rust = mk(
        "rust", "Rust", .cLike,
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                   "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
                   "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
                   "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where",
                   "while", "union", "macro_rules", "unsized", "virtual", "yield", "try"],
        types: ["bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
                "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option", "Result",
                "Box", "Rc", "Arc", "HashMap", "HashSet", "BTreeMap"],
        constants: ["true", "false", "None", "Some", "Ok", "Err"],
        builtins: ["println", "print", "eprintln", "format", "vec", "panic", "assert", "todo"],
        annotation: "#", nested: true
    )

    // MARK: JS family

    static let javascript = mk(
        "javascript", "JavaScript", .cLike,
        keywords: ["async", "await", "break", "case", "catch", "class", "const", "continue",
                   "debugger", "default", "delete", "do", "else", "export", "extends", "finally",
                   "for", "function", "if", "import", "in", "instanceof", "let", "new", "of",
                   "return", "static", "super", "switch", "this", "throw", "try", "typeof", "var",
                   "void", "while", "with", "yield", "get", "set", "from", "as"],
        types: ["Object", "Array", "String", "Number", "Boolean", "Symbol", "BigInt", "Function",
                "Promise", "Map", "Set", "WeakMap", "WeakSet", "Date", "RegExp", "Error", "JSON",
                "Math", "Proxy", "Reflect", "ArrayBuffer", "Uint8Array", "Int32Array", "Float64Array"],
        constants: ["true", "false", "null", "undefined", "NaN", "Infinity", "globalThis"],
        builtins: ["console", "document", "window", "process", "require", "module", "exports",
                   "setTimeout", "setInterval", "clearTimeout", "fetch", "parseInt", "parseFloat",
                   "isNaN", "encodeURIComponent", "decodeURIComponent", "structuredClone"],
        strings: ["\"", "'", "`"], extra: "$"
    )

    static let typescript = mk(
        "typescript", "TypeScript", .cLike,
        keywords: javascript.keywords.union([
            "type", "interface", "enum", "namespace", "declare", "abstract", "readonly",
            "implements", "private", "protected", "public", "override", "satisfies", "infer",
            "keyof", "is", "asserts", "unique", "module", "global", "require", "any", "unknown",
            "never", "object", "string", "number", "boolean", "symbol", "bigint", "void",
            "undefined", "null", "this"
        ]),
        types: javascript.types.union([
            "Partial", "Required", "Readonly", "Record", "Pick", "Omit", "Exclude", "Extract",
            "NonNullable", "Parameters", "ReturnType", "Awaited", "Ref", "Reactive", "ComputedRef",
            "Component", "DefineComponent", "PropType", "VNode", "RouteLocationRaw"
        ]),
        constants: javascript.constants, builtins: javascript.builtins,
        strings: ["\"", "'", "`"], extra: "$"
    )

    static let vue = mk(
        "vue", "Vue", .markup,
        keywords: [], types: [], constants: [], builtins: [],
        strings: ["\"", "'"], line: [], block: [], extra: ""
    )

    static let svelte = mk("svelte", "Svelte", .markup, strings: ["\"", "'"], line: [], block: [])

    // MARK: Markup

    static let html = mk("html", "HTML", .markup, strings: ["\"", "'"], line: [], block: [])
    static let xml = mk("xml", "XML", .markup, strings: ["\"", "'"], line: [], block: [])

    static let css = mk(
        "css", "CSS", .css,
        keywords: ["important", "media", "supports", "keyframes", "import", "charset",
                   "font-face", "page", "layer", "container", "property", "from", "to",
                   "and", "or", "not", "only", "screen", "print", "all"],
        types: [], constants: [], builtins: [], strings: ["\"", "'"],
        line: [], block: [("/*", "*/")]
    )

    static let scss = mk(
        "scss", "SCSS / Less", .css,
        keywords: css.keywords.union(["mixin", "include", "extend", "function", "return", "if",
                                      "else", "each", "for", "while", "use", "forward", "at-root",
                                      "debug", "warn", "error", "content"]),
        strings: ["\"", "'"], line: ["//"], block: [("/*", "*/")], extra: "$@"
    )

    static let json = mk(
        "json", "JSON", .json, constants: ["true", "false", "null"],
        strings: ["\""], line: [], block: []
    )

    static let jsonc = mk(
        "jsonc", "JSON with Comments", .json, constants: ["true", "false", "null"],
        strings: ["\""], line: ["//"], block: [("/*", "*/")]
    )

    static let yaml = mk(
        "yaml", "YAML", .hashLike, constants: ["true", "false", "null", "yes", "no", "on", "off", "~"],
        strings: ["\"", "'"], line: ["#"], block: []
    )

    static let toml = mk(
        "toml", "TOML", .hashLike, constants: ["true", "false"],
        strings: ["\"", "'"], line: ["#"], block: []
    )

    static let properties = mk(
        "properties", "Properties", .hashLike, constants: ["true", "false"],
        strings: ["\"", "'"], line: ["#", "!"], block: []
    )

    // MARK: Scripting

    static let python = mk(
        "python", "Python", .python,
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                   "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                   "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                   "return", "try", "while", "with", "yield", "match", "case", "self", "cls"],
        types: ["bool", "bytes", "complex", "dict", "float", "frozenset", "int", "list", "object",
                "range", "set", "str", "tuple", "type", "Any", "List", "Dict", "Optional",
                "Tuple", "Union", "Callable", "Iterable", "Sequence"],
        constants: ["True", "False", "None", "NotImplemented", "Ellipsis", "__name__"],
        builtins: ["print", "len", "range", "enumerate", "zip", "map", "filter", "sorted", "sum",
                   "min", "max", "abs", "round", "open", "input", "isinstance", "getattr",
                   "setattr", "hasattr", "super", "repr", "str", "int", "float", "list", "dict",
                   "set", "tuple", "type", "id", "hash", "iter", "next"],
        annotation: "@", strings: ["\"", "'"], line: ["#"], block: []
    )

    static let ruby = mk(
        "ruby", "Ruby", .ruby,
        keywords: ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def",
                   "defined?", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module",
                   "next", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
                   "then", "undef", "unless", "until", "when", "while", "yield", "require",
                   "attr_accessor", "attr_reader", "attr_writer", "include", "extend"],
        types: ["Array", "Hash", "String", "Integer", "Float", "Symbol", "Proc", "Range", "Time"],
        constants: ["true", "false", "nil", "__FILE__", "__LINE__"],
        builtins: ["puts", "print", "p", "gets", "loop", "lambda", "proc", "raise"],
        annotation: nil, line: ["#"], block: [("=begin", "=end")], extra: "@$?:"
    )

    static let php = mk(
        "php", "PHP", .php,
        keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                   "class", "clone", "const", "continue", "declare", "default", "do", "echo",
                   "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif",
                   "endswitch", "endwhile", "enum", "extends", "final", "finally", "fn", "for",
                   "foreach", "function", "global", "goto", "if", "implements", "include",
                   "include_once", "instanceof", "insteadof", "interface", "isset", "list",
                   "match", "namespace", "new", "or", "print", "private", "protected", "public",
                   "readonly", "require", "require_once", "return", "static", "switch", "throw",
                   "trait", "try", "unset", "use", "var", "while", "xor", "yield", "public"],
        types: ["bool", "int", "float", "string", "array", "object", "mixed", "void", "null",
                "iterable", "self", "parent", "static"],
        constants: ["true", "false", "null", "TRUE", "FALSE", "NULL"],
        builtins: ["echo", "print_r", "var_dump", "count", "array_map", "array_filter", "implode",
                   "explode", "strlen", "sprintf", "json_encode", "json_decode"],
        annotation: nil, line: ["//", "#"], block: [("/*", "*/")], extra: "$"
    )

    static let perl = mk(
        "perl", "Perl", .hashLike,
        keywords: ["my", "our", "local", "sub", "use", "package", "require", "if", "elsif",
                   "else", "unless", "while", "until", "for", "foreach", "do", "return", "last",
                   "next", "redo", "die", "warn", "print", "say", "chomp", "chop", "split",
                   "join", "push", "pop", "shift", "unshift", "keys", "values", "exists",
                   "delete", "defined", "ref", "bless", "new"],
        constants: ["undef"], builtins: [], line: ["#"], block: [], extra: "$@%&"
    )

    static let lua = mk(
        "lua", "Lua", .lua,
        keywords: ["and", "break", "do", "else", "elseif", "end", "false", "for", "function",
                   "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
                   "true", "until", "while", "self"],
        types: ["string", "table", "number", "boolean", "function", "thread", "userdata"],
        constants: ["true", "false", "nil"],
        builtins: ["print", "pairs", "ipairs", "type", "tostring", "tonumber", "require", "pcall",
                   "error", "assert", "table", "string", "math", "io", "os"],
        strings: ["\"", "'"], line: ["--"], block: [("--[[", "]]")]
    )

    static let r = mk(
        "r", "R", .hashLike,
        keywords: ["if", "else", "repeat", "while", "function", "for", "in", "next", "break",
                   "TRUE", "FALSE", "NULL", "Inf", "NaN", "library", "require", "return"],
        constants: ["TRUE", "FALSE", "NULL", "NA", "NaN", "Inf"], builtins: ["print", "cat", "c",
                   "list", "data.frame", "matrix", "seq", "mean", "sd", "sum", "length"],
        line: ["#"], block: []
    )

    static let shell = mk(
        "shell", "Shell", .shell,
        keywords: ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until",
                   "do", "done", "in", "function", "select", "time", "return", "exit", "break",
                   "continue", "local", "export", "readonly", "declare", "typeset", "unset",
                   "shift", "source", "alias", "trap", "set", "eval", "exec", "printf"],
        types: [], constants: ["true", "false"],
        builtins: ["echo", "cd", "pwd", "ls", "cat", "grep", "sed", "awk", "curl", "wget", "git",
                   "mkdir", "rm", "cp", "mv", "touch", "chmod", "chown", "find", "sort", "uniq",
                   "head", "tail", "wc", "xargs", "tar", "zip", "unzip", "npm", "node", "python",
                   "java", "mvn", "gradle", "docker", "kubectl", "ssh", "scp", "ps", "kill",
                   "which", "env", "test", "read", "sleep", "date", "basename", "dirname"],
        strings: ["\"", "'", "`"], line: ["#"], block: []
    )

    static let sql = mk(
        "sql", "SQL", .sql,
        keywords: ["add", "all", "alter", "and", "any", "as", "asc", "backup", "between", "by",
                   "case", "check", "column", "constraint", "create", "database", "default",
                   "delete", "desc", "distinct", "drop", "exec", "exists", "foreign", "from",
                   "full", "group", "having", "in", "index", "inner", "insert", "into", "is",
                   "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or",
                   "order", "outer", "primary", "procedure", "references", "right", "rownum",
                   "select", "set", "table", "top", "truncate", "union", "unique", "update",
                   "values", "view", "where", "with", "replace", "if", "else", "end", "begin",
                   "commit", "rollback", "declare", "cursor", "trigger", "function", "returns",
                   "auto_increment", "engine", "charset", "collate", "unsigned", "comment"],
        types: ["bigint", "binary", "bit", "blob", "boolean", "char", "date", "datetime",
                "decimal", "double", "enum", "float", "int", "integer", "json", "longblob",
                "longtext", "mediumint", "numeric", "real", "smallint", "text", "time",
                "timestamp", "tinyint", "varbinary", "varchar", "varchar2", "serial", "uuid"],
        constants: ["true", "false", "null"],
        builtins: ["count", "sum", "avg", "min", "max", "now", "coalesce", "cast", "convert",
                   "substring", "concat", "trim", "upper", "lower", "round", "ifnull", "group_concat"],
        strings: ["'", "\"", "`"], line: ["--"], block: [("/*", "*/")]
    )

    static let markdown = mk(
        "markdown", "Markdown", .markdown, strings: [], line: [], block: []
    )

    static let dockerfile = mk(
        "dockerfile", "Dockerfile", .hashLike,
        keywords: ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
                   "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
                   "HEALTHCHECK", "SHELL", "AS"],
        constants: [], builtins: [], strings: ["\"", "'"], line: ["#"], block: [], caseSensitive: false
    )

    static let makefile = mk(
        "makefile", "Makefile", .hashLike,
        keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define",
                   "endef", "export", "unexport", "override", "vpath"],
        constants: [], builtins: ["all", "clean", "install", "test", "build", "run"], line: ["#"], block: []
    )

    static let gitignore = mk(
        "gitignore", "Git Ignore", .hashLike, strings: [], line: ["#"], block: []
    )

    static let diff = mk(
        "diff", "Diff", .plain, strings: [], line: [], block: []
    )
}
