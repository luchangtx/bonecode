import AppKit

// MARK: - Working tree status

enum GitFileStatus: String {
    case unmodified = " "
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case ignored = "!"
    case conflicted = "U"

    static func from(_ code: Character) -> GitFileStatus {
        switch code {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "?": return .untracked
        case "!": return .ignored
        case "U": return .conflicted
        default: return .unmodified
        }
    }

    var letter: String { rawValue }

    var displayName: String {
        switch self {
        case .unmodified: return "未修改"
        case .modified: return "已修改"
        case .added: return "已新增"
        case .deleted: return "已删除"
        case .renamed: return "已重命名"
        case .copied: return "已复制"
        case .typeChanged: return "类型变更"
        case .untracked: return "未跟踪"
        case .ignored: return "已忽略"
        case .conflicted: return "冲突"
        }
    }

    /// One distinct hue per kind, so the change type is readable at a glance.
    func color(_ theme: Theme) -> NSColor {
        switch self {
        case .added: return theme.gitAdded
        case .modified: return theme.gitModified
        case .deleted: return theme.gitDeleted
        case .renamed, .copied: return theme.gitRenamed
        case .untracked: return theme.gitUntracked
        case .conflicted: return theme.gitConflicted
        case .typeChanged: return theme.gitRenamed
        case .ignored, .unmodified: return theme.tertiaryText
        }
    }

    /// Short label used in the badge tooltip.
    var badgeLabel: String {
        switch self {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        case .renamed: return "重命名"
        case .copied: return "复制"
        case .typeChanged: return "类型变更"
        case .untracked: return "新文件（未加入 Git）"
        case .conflicted: return "冲突"
        case .ignored: return "已忽略"
        case .unmodified: return "无变化"
        }
    }
}

struct GitFileChange {
    let path: String
    let oldPath: String?
    /// Status in the index (staged).
    let staged: GitFileStatus
    /// Status in the working tree (unstaged).
    let unstaged: GitFileStatus

    var isConflicted: Bool { staged == .conflicted || unstaged == .conflicted }
    var hasStaged: Bool { staged != .unmodified && staged != .untracked && staged != .ignored }
    var hasUnstaged: Bool { unstaged != .unmodified && unstaged != .ignored }
    var displayName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct GitBranch {
    let name: String
    let isRemote: Bool
    let upstream: String?
    let isCurrent: Bool
    let ahead: Int
    let behind: Int
    let subject: String
    let updated: Date?

    var shortName: String {
        isRemote ? name.replacingOccurrences(of: "origin/", with: "", options: .anchored) : name
    }
}

struct GitCommit {
    let hash: String
    let shortHash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let relativeDate: String
    let subject: String
    let body: String
    let refs: [String]

    var isMerge: Bool { parents.count > 1 }
    var shortRefs: [String] {
        refs.map {
            var s = $0
            s = s.replacingOccurrences(of: "HEAD -> ", with: "")
            s = s.replacingOccurrences(of: "tag: ", with: "🏷 ")
            return s.trimmingCharacters(in: .whitespaces)
        }
    }
}

struct GitRepoState {
    let root: String
    let branch: String
    let isDetached: Bool
    let changes: [GitFileChange]
    let ahead: Int
    let behind: Int
    let hasUpstream: Bool
    let upstreamName: String?
    let operation: String?
    let stashCount: Int

    var stagedCount: Int { changes.filter { $0.hasStaged }.count }
    var unstagedCount: Int { changes.filter { $0.hasUnstaged }.count }
    var conflictedCount: Int { changes.filter { $0.isConflicted }.count }
    var isClean: Bool { changes.isEmpty }
}

struct GitStashEntry {
    let index: Int
    let message: String
    let branch: String
    let date: String
}

// MARK: - Diff model

enum DiffLineKind {
    case context
    case added
    case removed
    case hunkHeader
    case fileHeader
    case meta
}

struct DiffLine {
    let kind: DiffLineKind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    var highlight: [NSRange] = []
}

struct DiffHunk {
    let header: String
    let oldStart: Int
    let newStart: Int
    var lines: [DiffLine]

    var addedCount: Int { lines.filter { $0.kind == .added }.count }
    var removedCount: Int { lines.filter { $0.kind == .removed }.count }
}

struct FileDiff {
    var path: String
    var oldPath: String?
    var isBinary: Bool = false
    var isNew: Bool = false
    var isDeleted: Bool = false
    var hunks: [DiffHunk] = []

    var addedCount: Int { hunks.reduce(0) { $0 + $1.addedCount } }
    var removedCount: Int { hunks.reduce(0) { $0 + $1.removedCount } }
    var isEmpty: Bool { hunks.isEmpty && !isBinary }
}

/// A bundle of parsed diffs plus the title to show in a diff tab.
struct DiffRequest {
    let diffs: [FileDiff]
    let title: String
    let subtitle: String
}

// MARK: - Diff parsing

enum DiffParser {

    static func parse(_ text: String) -> [FileDiff] {
        var results: [FileDiff] = []
        var current: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let c = current { results.append(c) }
            current = nil
        }

        text.enumerateLines { rawLine, _ in
            let line = rawLine

            if line.hasPrefix("diff --git ") {
                flushFile()
                let parts = line.split(separator: " ")
                var path = ""
                if parts.count >= 4 {
                    path = String(parts[3])
                    if path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
                }
                current = FileDiff(path: path, oldPath: nil)
                return
            }
            guard current != nil else { return }

            if line.hasPrefix("new file mode") { current?.isNew = true; return }
            if line.hasPrefix("deleted file mode") { current?.isDeleted = true; return }
            if line.hasPrefix("Binary files") { current?.isBinary = true; return }
            if line.hasPrefix("rename from ") {
                current?.oldPath = String(line.dropFirst("rename from ".count)); return
            }
            if line.hasPrefix("rename to ") {
                current?.path = String(line.dropFirst("rename to ".count)); return
            }
            if line.hasPrefix("--- ") {
                let p = String(line.dropFirst(4))
                if p != "/dev/null" {
                    current?.oldPath = p.hasPrefix("a/") ? String(p.dropFirst(2)) : p
                }
                return
            }
            if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4))
                if p != "/dev/null" {
                    current?.path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
                }
                return
            }
            if line.hasPrefix("@@") {
                flushHunk()
                let header = line
                let (os_, ns_) = parseHunkHeader(line)
                oldLine = os_
                newLine = ns_
                hunk = DiffHunk(header: header, oldStart: os_, newStart: ns_, lines: [])
                return
            }
            if line.hasPrefix("index ") || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("dissimilarity index") {
                return
            }

            guard hunk != nil else { return }

            if line.hasPrefix("\\") {
                hunk?.lines.append(DiffLine(kind: .meta, text: line, oldNumber: nil, newNumber: nil))
                return
            }

            let first = line.first ?? " "
            let content = line.isEmpty ? "" : String(line.dropFirst())
            switch first {
            case "+":
                hunk?.lines.append(DiffLine(kind: .added, text: content, oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                hunk?.lines.append(DiffLine(kind: .removed, text: content, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case " ":
                hunk?.lines.append(DiffLine(kind: .context, text: content, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            default:
                hunk?.lines.append(DiffLine(kind: .context, text: line, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }

        flushFile()
        for idx in results.indices {
            annotateIntraLine(&results[idx])
        }
        return results
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int) {
        // @@ -12,7 +14,9 @@ optional section
        var oldStart = 1, newStart = 1
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        _ = scanner.scanString("@@ -")
        oldStart = scanner.scanInt() ?? 1
        if scanner.scanString(",") != nil { _ = scanner.scanInt() }
        _ = scanner.scanString(" +")
        newStart = scanner.scanInt() ?? 1
        return (oldStart, newStart)
    }

    /// Pair up adjacent removed/added lines and mark what actually changed
    /// inside them, so the diff view can highlight words instead of whole lines.
    private static func annotateIntraLine(_ diff: inout FileDiff) {
        for hIndex in diff.hunks.indices {
            var lines = diff.hunks[hIndex].lines
            var i = 0
            while i < lines.count {
                guard lines[i].kind == .removed else { i += 1; continue }
                var removedIdx: [Int] = []
                var j = i
                while j < lines.count, lines[j].kind == .removed { removedIdx.append(j); j += 1 }
                var addedIdx: [Int] = []
                while j < lines.count, lines[j].kind == .added { addedIdx.append(j); j += 1 }
                let pairs = min(removedIdx.count, addedIdx.count)
                for k in 0..<pairs {
                    let old = lines[removedIdx[k]].text
                    let new = lines[addedIdx[k]].text
                    let (oldRanges, newRanges) = WordDiff.changedRanges(old: old, new: new)
                    lines[removedIdx[k]].highlight = oldRanges
                    lines[addedIdx[k]].highlight = newRanges
                }
                i = max(j, i + 1)
            }
            diff.hunks[hIndex].lines = lines
        }
    }
}

// MARK: - Word-level diff

enum WordDiff {

    /// Returns the character ranges that differ, for the old and new line.
    static func changedRanges(old: String, new: String) -> ([NSRange], [NSRange]) {
        let a = tokenize(old)
        let b = tokenize(new)
        if a.isEmpty || b.isEmpty || a.count > 400 || b.count > 400 {
            return (old.isEmpty ? [] : [NSRange(location: 0, length: (old as NSString).length)],
                    new.isEmpty ? [] : [NSRange(location: 0, length: (new as NSString).length)])
        }

        // Classic LCS table over tokens.
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i].text == b[j].text {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var keepA = [Bool](repeating: false, count: n)
        var keepB = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while i < n, j < m {
            if a[i].text == b[j].text {
                keepA[i] = true; keepB[j] = true; i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        let oldRanges = coalesce(a.enumerated().filter { !keepA[$0.offset] }.map { $0.element.range })
        let newRanges = coalesce(b.enumerated().filter { !keepB[$0.offset] }.map { $0.element.range })
        return (oldRanges, newRanges)
    }

    private struct WordToken {
        let text: String
        let range: NSRange
    }

    private static func tokenize(_ s: String) -> [WordToken] {
        var out: [WordToken] = []
        let ns = s as NSString
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            let isWord = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
            if isWord {
                var j = i
                while j < ns.length {
                    let d = ns.character(at: j)
                    let ok = (d >= 0x30 && d <= 0x39) || (d >= 0x41 && d <= 0x5A)
                        || (d >= 0x61 && d <= 0x7A) || d == 0x5F || d >= 0x80
                    if !ok { break }
                    j += 1
                }
                out.append(WordToken(text: ns.substring(with: NSRange(location: i, length: j - i)),
                                     range: NSRange(location: i, length: j - i)))
                i = j
            } else {
                // Merge runs of punctuation so "==" counts as one token.
                var j = i
                while j < ns.length {
                    let d = ns.character(at: j)
                    let isWordChar = (d >= 0x30 && d <= 0x39) || (d >= 0x41 && d <= 0x5A)
                        || (d >= 0x61 && d <= 0x7A) || d == 0x5F || d >= 0x80
                    if isWordChar || d == 0x20 { break }
                    j += 1
                }
                if j == i { j = i + 1 }
                out.append(WordToken(text: ns.substring(with: NSRange(location: i, length: j - i)),
                                     range: NSRange(location: i, length: j - i)))
                i = j
            }
        }
        return out
    }

    private static func coalesce(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var out: [NSRange] = []
        var cur = sorted[0]
        for r in sorted.dropFirst() {
            if r.location <= cur.location + cur.length + 1 {
                let end = max(cur.location + cur.length, r.location + r.length)
                cur = NSRange(location: cur.location, length: end - cur.location)
            } else {
                out.append(cur)
                cur = r
            }
        }
        out.append(cur)
        return out
    }
}
