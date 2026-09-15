import Foundation

struct Token {
    let location: Int
    let length: Int
    let role: SyntaxRole

    var range: NSRange { NSRange(location: location, length: length) }
}

/// Hand-written, allocation-light tokenizer.
///
/// Why not regex: code has multi-line state (block comments, template literals,
/// nested generics) that regular expressions cannot express without becoming
/// slower than a single linear scan. This scans the UTF-16 buffer exactly once.
final class SyntaxHighlighter {

    static let shared = SyntaxHighlighter()

    /// Beyond this size we refuse to tokenize the whole document and let the
    /// editor fall back to visible-range-only highlighting.
    static let maxTokenizableLength = 800_000

    private var cache: [String: [Token]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 40
    private let lock = NSLock()

    func tokenize(_ text: String, language: Language) -> [Token] {
        let units = Array(text.utf16)
        guard units.count <= Self.maxTokenizableLength else { return [] }

        var out: [Token] = []
        out.reserveCapacity(units.count / 5)
        let ctx = Ctx(units: units, lang: language)
        scan(ctx, 0, units.count, &out)
        return out
    }

    /// Tokenize with caching, keyed by language + content hash.
    func cachedTokens(_ text: String, language: Language) -> [Token] {
        let key = "\(language.id):\(text.hashValue):\(text.utf16.count)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let tokens = tokenize(text, language: language)

        lock.lock()
        if cache[key] == nil {
            cache[key] = tokens
            cacheOrder.append(key)
            while cacheOrder.count > cacheLimit {
                let oldest = cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        lock.unlock()
        return tokens
    }

    // MARK: - Context

    private struct Ctx {
        let u: [UInt16]
        let lang: Language
        let lineComments: [[UInt16]]
        let blockStarts: [[UInt16]]
        let blockEnds: [[UInt16]]
        let quotes: [UInt16]
        let sigils: Set<UInt16>
        let keywordSet: Set<String>
        let typeSet: Set<String>
        let constSet: Set<String>
        let builtinSet: Set<String>
        let caseSensitive: Bool

        init(units: [UInt16], lang: Language) {
            self.u = units
            self.lang = lang
            self.lineComments = lang.lineComments.map { Array($0.utf16) }
            self.blockStarts = lang.blockComments.map { Array($0.0.utf16) }
            self.blockEnds = lang.blockComments.map { Array($0.1.utf16) }
            self.quotes = lang.stringDelimiters.map { UInt16($0.asciiValue ?? 0x22) }
            self.sigils = Set(lang.identifierExtra.map { UInt16($0.asciiValue ?? 0) })
            self.caseSensitive = lang.caseSensitive
            self.keywordSet = lang.caseSensitive ? lang.keywords : Set(lang.keywords.map { $0.lowercased() })
            self.typeSet = lang.caseSensitive ? lang.types : Set(lang.types.map { $0.lowercased() })
            self.constSet = lang.caseSensitive ? lang.constants : Set(lang.constants.map { $0.lowercased() })
            self.builtinSet = lang.caseSensitive ? lang.builtins : Set(lang.builtins.map { $0.lowercased() })
        }

        func norm(_ s: String) -> String { caseSensitive ? s : s.lowercased() }
    }

    // MARK: - Character classes (ASCII fast paths)

    private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isHex(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
    private func isLetter(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80
    }
    private func isSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
    }
    private func isNewline(_ c: UInt16) -> Bool { c == 0x0A || c == 0x0D }
    private func isIdentStart(_ c: UInt16, _ ctx: Ctx) -> Bool {
        isLetter(c) || c == 0x5F || c == 0x24 || ctx.sigils.contains(c)
    }
    private func isIdentPart(_ c: UInt16, _ ctx: Ctx) -> Bool {
        isLetter(c) || isDigit(c) || c == 0x5F || c == 0x24 || ctx.sigils.contains(c)
    }
    private func isPunct(_ c: UInt16) -> Bool {
        switch c {
        case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3C, 0x3E, 0x2C, 0x3B, 0x3A,
             0x2E, 0x3D, 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E, 0x21,
             0x7E, 0x40, 0x23, 0x3F, 0x5C, 0x22, 0x27, 0x60:
            return true
        default: return false
        }
    }

    private func match(_ u: [UInt16], _ i: Int, _ pattern: [UInt16]) -> Bool {
        guard !pattern.isEmpty, i + pattern.count <= u.count else { return false }
        for k in 0..<pattern.count where u[i + k] != pattern[k] { return false }
        return true
    }

    private func matchCI(_ u: [UInt16], _ i: Int, _ pattern: [UInt16]) -> Bool {
        guard !pattern.isEmpty, i + pattern.count <= u.count else { return false }
        for k in 0..<pattern.count {
            var a = u[i + k], b = pattern[k]
            if a >= 0x41 && a <= 0x5A { a += 32 }
            if b >= 0x41 && b <= 0x5A { b += 32 }
            if a != b { return false }
        }
        return true
    }

    private func emit(_ out: inout [Token], _ start: Int, _ end: Int, _ role: SyntaxRole) {
        guard end > start else { return }
        out.append(Token(location: start, length: end - start, role: role))
    }

    private func string(from u: [UInt16], _ start: Int, _ end: Int) -> String {
        let slice = Array(u[start..<end])
        return String(decoding: slice, as: UTF16.self)
    }

    // MARK: - Dispatch

    private func scan(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        switch ctx.lang.kind {
        case .cLike: scanCLike(ctx, start, end, &out)
        case .hashLike: scanHashLike(ctx, start, end, &out)
        case .shell: scanShell(ctx, start, end, &out)
        case .python: scanPython(ctx, start, end, &out)
        case .ruby: scanRuby(ctx, start, end, &out)
        case .lua: scanLua(ctx, start, end, &out)
        case .php: scanPHP(ctx, start, end, &out)
        case .markup: scanMarkup(ctx, start, end, &out)
        case .css: scanCSS(ctx, start, end, &out)
        case .json: scanJSON(ctx, start, end, &out)
        case .markdown: scanMarkdown(ctx, start, end, &out)
        case .sql: scanSQL(ctx, start, end, &out)
        case .plain: break
        }
    }

    /// Classify a bare identifier.
    private func classify(_ name: String, _ ctx: Ctx, followedByParen: Bool) -> SyntaxRole {
        let key = ctx.norm(name)
        if ctx.constSet.contains(key) { return .constant }
        if ctx.keywordSet.contains(key) { return .keyword }
        if ctx.typeSet.contains(key) { return .type }
        if ctx.builtinSet.contains(key) { return .function }
        if followedByParen { return .function }
        if let f = name.first, f.isUppercase, name.count > 1, name.allSatisfy({ !$0.isNumber }) {
            return .type
        }
        return .plain
    }

    /// Skip whitespace / newlines, returning the next significant char (or 0).
    private func peekSignificant(_ u: [UInt16], _ i: Int, _ end: Int) -> UInt16 {
        var j = i
        while j < end, isSpace(u[j]) { j += 1 }
        return j < end ? u[j] : 0
    }

    // MARK: - C-like family

    private func scanCLike(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            // ---- comments
            var matchedComment = false
            for lc in ctx.lineComments where match(u, i, lc) {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                matchedComment = true
                break
            }
            if matchedComment { continue }

            for (idx, bs) in ctx.blockStarts.enumerated() where match(u, i, bs) {
                let be = ctx.blockEnds[idx]
                var j = i + bs.count
                var depth = 1
                while j < end {
                    if ctx.lang.nestedBlockComments, match(u, j, bs) {
                        depth += 1; j += bs.count; continue
                    }
                    if match(u, j, be) {
                        depth -= 1; j += be.count
                        if depth == 0 { break }
                        continue
                    }
                    j += 1
                }
                emit(&out, i, min(j, end), .comment)
                i = min(j, end)
                matchedComment = true
                break
            }
            if matchedComment { continue }

            // ---- strings
            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                continue
            }

            // ---- numbers
            if isDigit(c) || (c == 0x2E && i + 1 < end && isDigit(u[i + 1])) {
                var j = i
                if c == 0x30, i + 1 < end, u[i + 1] == 0x78 || u[i + 1] == 0x58 || u[i + 1] == 0x62 || u[i + 1] == 0x42 || u[i + 1] == 0x6F {
                    j = i + 2
                    while j < end, isHex(u[j]) || u[j] == 0x5F { j += 1 }
                } else {
                    while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x5F
                        || u[j] == 0x65 || u[j] == 0x45
                        || ((u[j] == 0x2B || u[j] == 0x2D) && j > i && (u[j - 1] == 0x65 || u[j - 1] == 0x45)) {
                        j += 1
                    }
                    // numeric suffixes: L, f, d, u, i64, n, m ...
                    while j < end, isLetter(u[j]) || isDigit(u[j]) { j += 1 }
                }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            // ---- annotations / attributes
            if let ap = ctx.lang.annotationPrefix, c == UInt16(ap.asciiValue ?? 0),
               i + 1 < end, isIdentStart(u[i + 1], ctx) {
                var j = i + 1
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                emit(&out, i, j, .annotation)
                i = j
                continue
            }

            // ---- identifiers
            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let raw = string(from: u, i, j)
                // strip leading sigils ($, @) before classifying
                var core = raw
                while let f = core.first, ctx.sigils.contains(UInt16(f.asciiValue ?? 0)) {
                    core.removeFirst()
                }
                if core.isEmpty { core = raw }
                let next = peekSignificant(u, j, end)
                var role = classify(core, ctx, followedByParen: next == 0x28)
                // `Foo.bar` -> keep Foo as type, bar as function
                if role == .type, next == 0x2E { role = .type }
                emit(&out, i, j, role)
                i = j
                continue
            }

            // ---- punctuation
            if isPunct(c) {
                emit(&out, i, i + 1, .punctuation)
                i += 1
                continue
            }

            // unknown / whitespace / other: skip one unit, avoiding splitting surrogates
            i += (c >= 0xD800 && c <= 0xDBFF && i + 1 < end) ? 2 : 1
        }
    }

    /// Consume a string literal starting at `start` (which holds the opening quote).
    /// Handles escapes, triple quotes, and multi-line template literals.
    private func scanString(_ ctx: Ctx, _ start: Int, _ end: Int, _ quote: UInt16) -> Int {
        let u = ctx.u
        var i = start + 1

        // triple-quoted?
        let triple = (i + 1 < end && u[i] == quote && u[i + 1] == quote)
        if triple { i += 2 }

        // backtick template literals span lines; normal quotes stop at EOL
        let multiline = triple || quote == 0x60

        while i < end {
            let c = u[i]
            if c == 0x5C { // backslash escape
                i += 2
                continue
            }
            if triple {
                if c == quote, i + 2 < end, u[i + 1] == quote, u[i + 2] == quote { return i + 3 }
                i += 1
                continue
            }
            if c == quote { return i + 1 }
            if isNewline(c) && !multiline { return i }
            i += 1
        }
        return end
    }

    // MARK: - Hash-like (yaml / toml / properties / dockerfile / makefile)

    private func scanHashLike(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start
        var lineStart = true

        while i < end {
            let c = u[i]

            if isNewline(c) { lineStart = true; i += 1; continue }
            if isSpace(c) { i += 1; continue }

            // comments
            var isComment = false
            for lc in ctx.lineComments where match(u, i, lc) { isComment = true; break }
            if isComment {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                continue
            }

            // quoted strings
            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                lineStart = false
                continue
            }

            // numbers
            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x5F { j += 1 }
                emit(&out, i, j, .number)
                i = j
                lineStart = false
                continue
            }

            if isIdentStart(c, ctx) || c == 0x2E || c == 0x2F || c == 0x2D {
                var j = i
                while j < end, isIdentPart(u[j], ctx) || u[j] == 0x2E || u[j] == 0x2D || u[j] == 0x2F {
                    j += 1
                }
                let word = string(from: u, i, j)
                let next = peekSignificant(u, j, end)

                var role: SyntaxRole = .plain
                let key = ctx.norm(word)
                if ctx.constSet.contains(key) {
                    role = .constant
                } else if ctx.keywordSet.contains(key) {
                    role = .keyword
                } else if next == 0x3A || next == 0x3D || lineStart {
                    // `key:` / `key =` / bare directive at line start
                    role = (next == 0x3A || next == 0x3D) ? .attribute : .plain
                } else {
                    role = .plain
                }
                emit(&out, i, j, role)
                i = j
                lineStart = false
                continue
            }

            if isPunct(c) {
                emit(&out, i, i + 1, .punctuation)
                i += 1
                lineStart = (c == 0x3A || c == 0x3D || c == 0x2D) ? false : false
                continue
            }

            i += 1
        }
    }

    // MARK: - Shell

    private func scanShell(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start
        var atCommandPosition = true

        while i < end {
            let c = u[i]

            if isNewline(c) { atCommandPosition = true; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            if c == 0x3B || c == 0x7C || c == 0x26 { atCommandPosition = true; i += 1; continue }

            if c == 0x23 { // '#'
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                continue
            }

            // $VAR / ${VAR} / $(...) / $?
            if c == 0x24 {
                var j = i + 1
                if j < end, u[j] == 0x7B {
                    while j < end, u[j] != 0x7D { j += 1 }
                    if j < end { j += 1 }
                } else if j < end, u[j] == 0x28 {
                    var depth = 1; j += 1
                    while j < end, depth > 0 {
                        if u[j] == 0x28 { depth += 1 }
                        if u[j] == 0x29 { depth -= 1 }
                        j += 1
                    }
                } else {
                    while j < end, isIdentPart(u[j], ctx) || isDigit(u[j]) { j += 1 }
                }
                emit(&out, i, j, .constant)
                i = j
                continue
            }

            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                atCommandPosition = false
                continue
            }

            if c == 0x2D, i + 1 < end, isLetter(u[i + 1]) || u[i + 1] == 0x2D {
                var j = i
                while j < end, isIdentPart(u[j], ctx) || u[j] == 0x2D { j += 1 }
                emit(&out, i, j, .attribute)
                i = j
                continue
            }

            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let word = string(from: u, i, j)
                let role = classify(word, ctx, followedByParen: false)
                if role == .function { emit(&out, i, j, .function) }
                else if role == .keyword { emit(&out, i, j, .keyword) }
                else { emit(&out, i, j, atCommandPosition ? .function : .plain) }
                i = j
                atCommandPosition = false
                continue
            }

            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - Python

    private func scanPython(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            if c == 0x23 {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                continue
            }

            // string prefixes: f"", r"", b"", rb"", u""
            var qStart = i
            if isLetter(c), i + 1 < end {
                var k = i
                while k < end, k - i < 3, isLetter(u[k]) { k += 1 }
                if k < end, ctx.quotes.contains(u[k]) { qStart = k }
            }
            if ctx.quotes.contains(u[qStart]) {
                let j = scanString(ctx, qStart, end, u[qStart])
                emit(&out, i, j, .string)
                i = j
                continue
            }

            if let ap = ctx.lang.annotationPrefix, c == UInt16(ap.asciiValue ?? 0), i + 1 < end, isLetter(u[i + 1]) {
                var j = i + 1
                while j < end, isIdentPart(u[j], ctx) || u[j] == 0x2E { j += 1 }
                emit(&out, i, j, .annotation)
                i = j
                continue
            }

            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x5F
                    || u[j] == 0x78 || u[j] == 0x62 || u[j] == 0x6F
                    || (u[j] >= 0x41 && u[j] <= 0x46) || (u[j] >= 0x61 && u[j] <= 0x66) { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let word = string(from: u, i, j)
                let next = peekSignificant(u, j, end)
                emit(&out, i, j, classify(word, ctx, followedByParen: next == 0x28))
                i = j
                continue
            }

            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - Ruby

    private func scanRuby(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            if c == 0x23 {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                continue
            }

            // =begin / =end block comment (must be at column 0)
            if match(u, i, Array("=begin".utf16)) {
                var j = i
                while j < end, !match(u, j, Array("=end".utf16)) { j += 1 }
                var k = min(end, j + 4)
                while k < end, !isNewline(u[k]) { k += 1 }
                emit(&out, i, k, .comment)
                i = k
                continue
            }

            if c == 0x3A, i + 1 < end, isIdentStart(u[i + 1], ctx) { // :symbol
                var j = i + 1
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                emit(&out, i, j, .constant)
                i = j
                continue
            }

            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                continue
            }

            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x5F { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let word = string(from: u, i, j)
                let next = peekSignificant(u, j, end)
                emit(&out, i, j, classify(word, ctx, followedByParen: next == 0x28))
                i = j
                continue
            }

            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - Lua

    private func scanLua(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            if match(u, i, Array("--".utf16)) {
                if match(u, i, Array("--[[".utf16)) {
                    var j = i + 4
                    while j < end, !match(u, j, Array("]]".utf16)) { j += 1 }
                    emit(&out, i, min(end, j + 2), .comment)
                    i = min(end, j + 2)
                } else {
                    var j = i
                    while j < end, !isNewline(u[j]) { j += 1 }
                    emit(&out, i, j, .comment)
                    i = j
                }
                continue
            }

            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                continue
            }

            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x78
                    || (u[j] >= 0x41 && u[j] <= 0x46) || (u[j] >= 0x61 && u[j] <= 0x66) { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let word = string(from: u, i, j)
                let next = peekSignificant(u, j, end)
                var role = classify(word, ctx, followedByParen: next == 0x28)
                if role == .plain, next == 0x2E || next == 0x3A { role = .type }
                emit(&out, i, j, role)
                i = j
                continue
            }

            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - PHP

    private func scanPHP(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            if match(u, i, Array("<?php".utf16)) || match(u, i, Array("?>".utf16)) || match(u, i, Array("<?=".utf16)) {
                let len = match(u, i, Array("<?php".utf16)) ? 5 : 2
                emit(&out, i, i + len, .tag)
                i += len
                continue
            }
            if c == 0x23 || match(u, i, Array("//".utf16)) {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                continue
            }
            if match(u, i, Array("/*".utf16)) {
                var j = i + 2
                while j < end, !match(u, j, Array("*/".utf16)) { j += 1 }
                emit(&out, i, min(end, j + 2), .comment)
                i = min(end, j + 2)
                continue
            }
            if c == 0x24 { // $var
                var j = i + 1
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                emit(&out, i, j, .variable)
                i = j
                continue
            }
            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                continue
            }
            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x5F { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }
            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let word = string(from: u, i, j)
                let next = peekSignificant(u, j, end)
                emit(&out, i, j, classify(word, ctx, followedByParen: next == 0x28))
                i = j
                continue
            }
            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - Markup (HTML / XML / Vue / Svelte)

    private func scanMarkup(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            // comments: <!-- --> and Vue {{-- --}}
            if match(u, i, Array("<!--".utf16)) {
                var j = i + 4
                while j < end, !match(u, j, Array("-->".utf16)) { j += 1 }
                emit(&out, i, min(end, j + 3), .comment)
                i = min(end, j + 3)
                continue
            }
            // doctype
            if matchCI(u, i, Array("<!doctype".utf16)) {
                var j = i
                while j < end, u[j] != 0x3E { j += 1 }
                emit(&out, i, min(end, j + 1), .keyword)
                i = min(end, j + 1)
                continue
            }

            if c == 0x3C { // '<'
                let isClose = i + 1 < end && u[i + 1] == 0x2F
                let nameStart = i + (isClose ? 2 : 1)
                guard nameStart < end, isLetter(u[nameStart]) || u[nameStart] == 0x21 else {
                    emit(&out, i, i + 1, .punctuation); i += 1; continue
                }
                emit(&out, i, nameStart, .punctuation)
                var nameEnd = nameStart
                while nameEnd < end, isIdentPart(u[nameEnd], ctx) || u[nameEnd] == 0x2D || u[nameEnd] == 0x3A {
                    nameEnd += 1
                }
                let tagName = string(from: u, nameStart, nameEnd).lowercased()
                emit(&out, nameStart, nameEnd, .tag)
                i = nameEnd

                // attributes
                var selfClosing = false
                var langAttr = ""
                while i < end {
                    let d = u[i]
                    if isSpace(d) { i += 1; continue }
                    if d == 0x3E { i += 1; break }
                    if d == 0x2F {
                        selfClosing = true
                        emit(&out, i, i + 1, .punctuation)
                        i += 1
                        continue
                    }
                    if isIdentStart(d, ctx) || d == 0x2D || d == 0x40 || d == 0x3A || d == 0x5B {
                        var j = i
                        while j < end, isIdentPart(u[j], ctx) || u[j] == 0x2D || u[j] == 0x40
                            || u[j] == 0x3A || u[j] == 0x2E || u[j] == 0x5B || u[j] == 0x5D {
                            j += 1
                        }
                        let attrName = string(from: u, i, j).lowercased()
                        emit(&out, i, j, .attribute)
                        i = j
                        // optional = "value"
                        var k = i
                        while k < end, isSpace(u[k]) { k += 1 }
                        if k < end, u[k] == 0x3D {
                            emit(&out, k, k + 1, .punctuation)
                            k += 1
                            while k < end, isSpace(u[k]) { k += 1 }
                            if k < end, u[k] == 0x22 || u[k] == 0x27 {
                                let j2 = scanString(ctx, k, end, u[k])
                                if attrName == "lang" {
                                    langAttr = string(from: u, k + 1, max(k + 1, j2 - 1)).lowercased()
                                }
                                emit(&out, k, j2, .string)
                                k = j2
                            }
                        }
                        i = k
                        continue
                    }
                    if d == 0x22 || d == 0x27 {
                        let j = scanString(ctx, i, end, d)
                        emit(&out, i, j, .string)
                        i = j
                        continue
                    }
                    i += 1
                }

                // ---- embedded blocks for <script> / <style>
                if !isClose, !selfClosing, tagName == "script" || tagName == "style" {
                    let closeTag = Array("</\(tagName)".utf16)
                    var j = i
                    while j < end, !matchCI(u, j, closeTag) { j += 1 }
                    let contentEnd = j

                    if tagName == "script" {
                        let embedded: Language
                        switch langAttr {
                        case "ts", "typescript": embedded = LanguageRegistry.language(forID: "typescript")
                        case "jsx": embedded = LanguageRegistry.language(forID: "javascript")
                        default: embedded = LanguageRegistry.language(forID: "javascript")
                        }
                        scanCLike(Ctx(units: u, lang: embedded), i, contentEnd, &out)
                    } else {
                        let embedded: Language
                        switch langAttr {
                        case "scss", "sass": embedded = LanguageRegistry.language(forID: "scss")
                        case "less": embedded = LanguageRegistry.language(forID: "scss")
                        default: embedded = LanguageRegistry.language(forID: "css")
                        }
                        scanCSS(Ctx(units: u, lang: embedded), i, contentEnd, &out)
                    }
                    i = contentEnd
                }
                continue
            }

            // Vue / Svelte interpolations {{ expr }}
            if c == 0x7B, i + 1 < end, u[i + 1] == 0x7B {
                var j = i + 2
                while j < end, !(u[j] == 0x7D && j + 1 < end && u[j + 1] == 0x7D) { j += 1 }
                let stop = min(end, j + 2)
                emit(&out, i, min(end, i + 2), .punctuation)
                scanCLike(Ctx(units: u, lang: LanguageRegistry.language(forID: "javascript")),
                          i + 2, max(i + 2, stop - 2), &out)
                emit(&out, max(i, stop - 2), stop, .punctuation)
                i = stop
                continue
            }

            // plain text run
            var j = i
            while j < end, u[j] != 0x3C, !(u[j] == 0x7B && j + 1 < end && u[j + 1] == 0x7B) { j += 1 }
            if j == i { j += 1 }
            emit(&out, i, j, .plain)
            i = j
        }
    }

    // MARK: - CSS / SCSS / Less

    private func scanCSS(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start
        var depth = 0
        var inValue = false

        while i < end {
            let c = u[i]

            if match(u, i, Array("/*".utf16)) {
                var j = i + 2
                while j < end, !match(u, j, Array("*/".utf16)) { j += 1 }
                emit(&out, i, min(end, j + 2), .comment)
                i = min(end, j + 2)
                continue
            }
            var cssLineComment = false
            for lc in ctx.lineComments where match(u, i, lc) {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment)
                i = j
                cssLineComment = true
                break
            }
            if cssLineComment { continue }

            if c == 0x7B { // {
                depth += 1
                inValue = false
                emit(&out, i, i + 1, .punctuation)
                i += 1
                continue
            }
            if c == 0x7D { // }
                depth = max(0, depth - 1)
                inValue = false
                emit(&out, i, i + 1, .punctuation)
                i += 1
                continue
            }
            if c == 0x3B { inValue = false; emit(&out, i, i + 1, .punctuation); i += 1; continue }

            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                continue
            }

            // at-rules
            if c == 0x40 {
                var j = i + 1
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                emit(&out, i, j, .keyword)
                i = j
                continue
            }

            // colors #rrggbb
            if c == 0x23, i + 1 < end, isHex(u[i + 1]) {
                var j = i + 1
                while j < end, isHex(u[j]) { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            if isDigit(c) || (c == 0x2E && i + 1 < end && isDigit(u[i + 1])) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x25 { j += 1 }
                while j < end, isLetter(u[j]) { j += 1 }   // px / rem / vh
                emit(&out, i, j, .number)
                i = j
                continue
            }

            // identifiers: property / selector / function / value keyword
            if isIdentStart(c, ctx) || c == 0x2D {
                var j = i
                if u[i] == 0x2D { j = i + 1 }
                while j < end, isIdentPart(u[j], ctx) || u[j] == 0x2D { j += 1 }
                let word = string(from: u, i, j)
                var k = j
                while k < end, isSpace(u[k]) { k += 1 }
                let next = k < end ? u[k] : 0

                var role: SyntaxRole
                if depth > 0, next == 0x3A {
                    role = .attribute          // property name
                    inValue = true
                } else if next == 0x28 {
                    role = .function           // rgb() / calc()
                } else if depth == 0 {
                    role = .tag                // selector
                } else if inValue, ctx.keywordSet.contains(ctx.norm(word)) {
                    role = .keyword
                } else if ctx.constSet.contains(ctx.norm(word)) || ctx.keywordSet.contains(ctx.norm(word)) {
                    role = .constant
                } else {
                    role = .plain
                }
                emit(&out, i, j, role)
                i = j
                continue
            }

            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - JSON

    private func scanJSON(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            if match(u, i, Array("//".utf16)) {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment); i = j; continue
            }
            if match(u, i, Array("/*".utf16)) {
                var j = i + 2
                while j < end, !match(u, j, Array("*/".utf16)) { j += 1 }
                emit(&out, i, min(end, j + 2), .comment); i = min(end, j + 2); continue
            }

            if c == 0x22 {
                let j = scanString(ctx, i, end, 0x22)
                let next = peekSignificant(u, j, end)
                emit(&out, i, j, next == 0x3A ? .attribute : .string)
                i = j
                continue
            }

            if isDigit(c) || c == 0x2D {
                var j = i + 1
                while j < end, isDigit(u[j]) || u[j] == 0x2E || u[j] == 0x65 || u[j] == 0x45
                    || u[j] == 0x2B || u[j] == 0x2D { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }

            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isLetter(u[j]) { j += 1 }
                let word = string(from: u, i, j)
                emit(&out, i, j, ctx.constSet.contains(ctx.norm(word)) ? .constant : .plain)
                i = j
                continue
            }

            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - SQL

    private func scanSQL(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            let c = u[i]

            if match(u, i, Array("--".utf16)) {
                var j = i
                while j < end, !isNewline(u[j]) { j += 1 }
                emit(&out, i, j, .comment); i = j; continue
            }
            if match(u, i, Array("/*".utf16)) {
                var j = i + 2
                while j < end, !match(u, j, Array("*/".utf16)) { j += 1 }
                emit(&out, i, min(end, j + 2), .comment); i = min(end, j + 2); continue
            }
            if ctx.quotes.contains(c) {
                let j = scanString(ctx, i, end, c)
                emit(&out, i, j, .string)
                i = j
                continue
            }
            if isDigit(c) {
                var j = i
                while j < end, isDigit(u[j]) || u[j] == 0x2E { j += 1 }
                emit(&out, i, j, .number)
                i = j
                continue
            }
            if isIdentStart(c, ctx) {
                var j = i
                while j < end, isIdentPart(u[j], ctx) { j += 1 }
                let word = string(from: u, i, j)
                let key = ctx.norm(word)
                var role: SyntaxRole = .plain
                if ctx.keywordSet.contains(key) { role = .keyword }
                else if ctx.typeSet.contains(key) { role = .type }
                else if ctx.constSet.contains(key) { role = .constant }
                else if ctx.builtinSet.contains(key) { role = .function }
                emit(&out, i, j, role)
                i = j
                continue
            }
            if isPunct(c) { emit(&out, i, i + 1, .punctuation); i += 1; continue }
            i += 1
        }
    }

    // MARK: - Markdown

    private func scanMarkdown(_ ctx: Ctx, _ start: Int, _ end: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = start

        while i < end {
            // line-oriented
            var lineEnd = i
            while lineEnd < end, !isNewline(u[lineEnd]) { lineEnd += 1 }
            scanMarkdownLine(ctx, i, lineEnd, &out)
            i = lineEnd + 1
        }
    }

    private func scanMarkdownLine(_ ctx: Ctx, _ ls: Int, _ le: Int, _ out: inout [Token]) {
        let u = ctx.u
        var i = ls

        // leading indentation
        while i < le, isSpace(u[i]) { i += 1 }
        guard i < le else { return }

        // fenced code block
        if match(u, i, Array("```".utf16)) || match(u, i, Array("~~~".utf16)) {
            emit(&out, i, le, .string)
            return
        }

        // heading
        if u[i] == 0x23 {
            var j = i
            while j < le, u[j] == 0x23 { j += 1 }
            emit(&out, i, min(le, j + 1), .keyword)
            emit(&out, min(le, j + 1), le, .keyword)
            return
        }

        // horizontal rule
        if (u[i] == 0x2D || u[i] == 0x2A || u[i] == 0x5F) {
            var all = true
            var j = i
            var count = 0
            while j < le {
                if u[j] != u[i] { all = false; break }
                j += 1; count += 1
            }
            if all, count >= 3 { emit(&out, i, le, .punctuation); return }
        }

        // blockquote
        if u[i] == 0x3E {
            emit(&out, i, le, .comment)
            return
        }

        // list marker
        if u[i] == 0x2D || u[i] == 0x2A || u[i] == 0x2B {
            if i + 1 < le, isSpace(u[i + 1]) {
                emit(&out, i, i + 1, .punctuation)
                i += 1
            }
        } else if isDigit(u[i]) {
            var j = i
            while j < le, isDigit(u[j]) { j += 1 }
            if j < le, u[j] == 0x2E {
                emit(&out, i, j + 1, .punctuation)
                i = j + 1
            }
        }

        // inline: `code`, **bold**, *em*, [text](url)
        var j = i
        while j < le {
            let c = u[j]
            if c == 0x60 { // `code`
                var k = j + 1
                while k < le, u[k] != 0x60 { k += 1 }
                emit(&out, j, min(le, k + 1), .string)
                j = min(le, k + 1)
                continue
            }
            if c == 0x2A || c == 0x5F { // emphasis
                let marker = c
                var count = 0
                var k = j
                while k < le, u[k] == marker { k += 1; count += 1 }
                // find closing run
                var close = k
                while close < le, !(u[close] == marker) { close += 1 }
                if close < le {
                    var e = close
                    while e < le, u[e] == marker { e += 1 }
                    emit(&out, j, k, .punctuation)
                    emit(&out, k, close, count >= 2 ? .keyword : .type)
                    emit(&out, close, e, .punctuation)
                    j = e
                    continue
                }
                j = k
                continue
            }
            if c == 0x5B { // [text](url)
                var k = j + 1
                while k < le, u[k] != 0x5D { k += 1 }
                if k < le {
                    emit(&out, j, j + 1, .punctuation)
                    emit(&out, j + 1, k, .function)
                    emit(&out, k, k + 1, .punctuation)
                    var m = k + 1
                    if m < le, u[m] == 0x28 {
                        var n = m + 1
                        while n < le, u[n] != 0x29 { n += 1 }
                        emit(&out, m, m + 1, .punctuation)
                        emit(&out, m + 1, n, .string)
                        if n < le { emit(&out, n, n + 1, .punctuation) }
                        m = n + 1
                    }
                    j = m
                    continue
                }
            }
            if c == 0x3C { // <https://...> autolink
                var k = j + 1
                while k < le, u[k] != 0x3E { k += 1 }
                if k < le { emit(&out, j, k + 1, .string); j = k + 1; continue }
            }
            j += 1
        }
    }
}
