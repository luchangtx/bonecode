import Foundation

enum ResetMode: String {
    case soft = "--soft"
    case mixed = "--mixed"
    case hard = "--hard"

    var displayName: String {
        switch self {
        case .soft: return "保留暂存与工作区"
        case .mixed: return "保留工作区，取消暂存"
        case .hard: return "丢弃所有改动"
        }
    }
}

/// All Git access goes through the `git` CLI.
///
/// Reimplementing the object database would be a project of its own, and every
/// user already has a `git` that handles their credential helpers, SSH agent and
/// hooks correctly. We shell out and parse.
final class GitService {

    static let shared = GitService()

    private(set) var root: String?
    private(set) var gitDir: String?
    private let queue = DispatchQueue(label: "bonecode.git", qos: .userInitiated)

    var isOpen: Bool { root != nil }

    // MARK: - Repository

    @discardableResult
    func openRepository(at path: String) -> Bool {
        let r = ProcessRunner.run(ProcessRunner.gitPath(), ["rev-parse", "--show-toplevel"], cwd: path)
        guard r.ok else {
            root = nil
            gitDir = nil
            return false
        }
        root = r.stdout.trimmed
        let g = ProcessRunner.run(ProcessRunner.gitPath(), ["rev-parse", "--git-dir"], cwd: path)
        if g.ok {
            let d = g.stdout.trimmed
            gitDir = d.hasPrefix("/") ? d : (root.map { $0 + "/" + d })
        }
        return root != nil
    }

    func close() {
        root = nil
        gitDir = nil
    }

    @discardableResult
    func initRepository(at path: String) -> ProcessResult {
        ProcessRunner.run(ProcessRunner.gitPath(), ["init"], cwd: path)
    }

    // MARK: - Execution

    /// Async on a serial queue so rapid UI actions cannot interleave.
    func run(_ args: [String], completion: @escaping (ProcessResult) -> Void) {
        guard let root else {
            completion(ProcessResult(exitCode: -1, stdout: "", stderr: "未打开 Git 仓库"))
            return
        }
        queue.async {
            let r = ProcessRunner.run(ProcessRunner.gitPath(), args, cwd: root)
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Streaming variant for long operations (push / pull / fetch).
    @discardableResult
    func runStreaming(
        _ args: [String],
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) -> Process? {
        guard let root else {
            onOutput("未打开 Git 仓库\n")
            onExit(-1)
            return nil
        }
        return ProcessRunner.stream(ProcessRunner.gitPath(), args, cwd: root,
                                    onOutput: onOutput, onExit: onExit)
    }

    /// Synchronous, for use inside background work only.
    func runSync(_ args: [String]) -> ProcessResult {
        guard let root else {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "未打开 Git 仓库")
        }
        return ProcessRunner.run(ProcessRunner.gitPath(), args, cwd: root)
    }

    // MARK: - Status

    func state(completion: @escaping (GitRepoState?) -> Void) {
        guard let root else { completion(nil); return }
        queue.async {
            let r = ProcessRunner.run(
                ProcessRunner.gitPath(),
                ["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "-z"],
                cwd: root
            )
            guard r.ok else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let op = Self.detectOperation(gitDir: self.gitDir)
            let stash = ProcessRunner.run(ProcessRunner.gitPath(), ["stash", "list"], cwd: root)
            let stashCount = stash.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
            let parsed = Self.parseStatus(r.stdout, root: root, operation: op, stashCount: stashCount)
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    private static func detectOperation(gitDir: String?) -> String? {
        guard let gitDir else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(gitDir)/rebase-merge") || fm.fileExists(atPath: "\(gitDir)/rebase-apply") {
            return "rebase"
        }
        if fm.fileExists(atPath: "\(gitDir)/MERGE_HEAD") { return "merge" }
        if fm.fileExists(atPath: "\(gitDir)/CHERRY_PICK_HEAD") { return "cherry-pick" }
        if fm.fileExists(atPath: "\(gitDir)/REVERT_HEAD") { return "revert" }
        return nil
    }

    private static func parseStatus(_ raw: String, root: String, operation: String?, stashCount: Int) -> GitRepoState {
        var branch = "HEAD"
        var detached = false
        var ahead = 0, behind = 0
        var hasUpstream = false
        var upstreamName: String?
        var changes: [GitFileChange] = []

        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            if f.isEmpty { continue }

            if f.hasPrefix("# branch.head ") {
                let name = String(f.dropFirst("# branch.head ".count))
                if name == "(detached)" { detached = true; branch = "HEAD（游离）" }
                else { branch = name }
                continue
            }
            if f.hasPrefix("# branch.upstream ") {
                hasUpstream = true
                upstreamName = String(f.dropFirst("# branch.upstream ".count))
                continue
            }
            if f.hasPrefix("# branch.ab ") {
                let ab = String(f.dropFirst("# branch.ab ".count))
                for part in ab.split(separator: " ") {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
                continue
            }
            if f.hasPrefix("#") { continue }

            let kind = f.first ?? " "
            switch kind {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = f.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count >= 9 else { continue }
                let xy = Array(parts[1])
                let path = String(parts[8])
                changes.append(GitFileChange(
                    path: path, oldPath: nil,
                    staged: GitFileStatus.from(xy.first ?? " "),
                    unstaged: GitFileStatus.from(xy.count > 1 ? xy[1] : " ")
                ))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path  (origPath in the next NUL field)
                let parts = f.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count >= 10 else { continue }
                let xy = Array(parts[1])
                let path = String(parts[9])
                var origPath: String?
                if i < fields.count {
                    origPath = fields[i]
                    i += 1
                }
                changes.append(GitFileChange(
                    path: path, oldPath: origPath,
                    staged: GitFileStatus.from(xy.first ?? " "),
                    unstaged: GitFileStatus.from(xy.count > 1 ? xy[1] : " ")
                ))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = f.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count >= 11 else { continue }
                let path = String(parts[10])
                changes.append(GitFileChange(
                    path: path, oldPath: nil,
                    staged: .conflicted, unstaged: .conflicted
                ))
            case "?":
                let path = String(f.dropFirst(2))
                changes.append(GitFileChange(
                    path: path, oldPath: nil, staged: .unmodified, unstaged: .untracked
                ))
            default:
                break
            }
        }

        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        return GitRepoState(
            root: root, branch: branch, isDetached: detached, changes: changes,
            ahead: ahead, behind: behind, hasUpstream: hasUpstream, upstreamName: upstreamName,
            operation: operation, stashCount: stashCount
        )
    }

    // MARK: - Log

    func log(limit: Int = 400, includeAllBranches: Bool = true, completion: @escaping ([GitCommit]) -> Void) {
        var args = ["log", "--date-order", "-n", "\(limit)",
                    "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%ar%x1f%s%x1f%D%x1f%b%x1e"]
        if includeAllBranches { args.insert("--all", at: 1) }
        run(args) { r in
            guard r.ok else { completion([]); return }
            completion(Self.parseLog(r.stdout))
        }
    }

    static func parseLog(_ raw: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        let records = raw.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        for rec in records {
            let trimmed = rec.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "\u{1f}")
            guard parts.count >= 9 else { continue }
            let parents = parts[2].split(separator: " ").map(String.init)
            let ts = Double(parts[5]) ?? 0
            let refs = parts[8].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            commits.append(GitCommit(
                hash: parts[0],
                shortHash: parts[1],
                parents: parents,
                author: parts[3],
                email: parts[4],
                date: Date(timeIntervalSince1970: ts),
                relativeDate: parts[6],
                subject: parts[7],
                body: parts.count > 9 ? parts[9].trimmingCharacters(in: .newlines) : "",
                refs: refs
            ))
        }
        return commits
    }

    // MARK: - Branches

    func branches(completion: @escaping ([GitBranch]) -> Void) {
        let fmt = "%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(HEAD)%1f%(objectname:short)%1f%(subject)%1f%(committerdate:unix)"
        run(["for-each-ref", "--sort=-committerdate", "--format=\(fmt)", "refs/heads", "refs/remotes"]) { r in
            guard r.ok else { completion([]); return }
            var out: [GitBranch] = []
            for line in r.stdout.split(separator: "\n") {
                let p = line.components(separatedBy: "\u{1f}")
                guard p.count >= 7 else { continue }
                let full = p[0]
                if full.hasSuffix("/HEAD") { continue }
                let isRemote = full.hasPrefix("refs/remotes/")
                let isCurrent = p[3] == "*"
                out.append(GitBranch(
                    name: p[1],
                    isRemote: isRemote,
                    upstream: p[2].isEmpty ? nil : p[2],
                    isCurrent: isCurrent,
                    ahead: 0, behind: 0,
                    subject: p[5],
                    updated: Double(p[6]).map { Date(timeIntervalSince1970: $0) }
                ))
            }
            out.sort { a, b in
                if a.isCurrent != b.isCurrent { return a.isCurrent }
                if a.isRemote != b.isRemote { return !a.isRemote }
                return (a.updated ?? .distantPast) > (b.updated ?? .distantPast)
            }
            completion(out)
        }
    }

    func tags(completion: @escaping ([String]) -> Void) {
        run(["tag", "--sort=-creatordate"]) { r in
            completion(r.ok ? r.stdout.split(separator: "\n").map(String.init) : [])
        }
    }

    func remotes(completion: @escaping ([String]) -> Void) {
        run(["remote"]) { r in
            completion(r.ok ? r.stdout.split(separator: "\n").map(String.init) : [])
        }
    }

    // MARK: - Staging

    func stage(_ paths: [String], completion: ((ProcessResult) -> Void)? = nil) {
        guard !paths.isEmpty else { completion?(ProcessResult(exitCode: 0, stdout: "", stderr: "")); return }
        run(["add", "--"] + paths) { completion?($0) }
    }

    func stageAll(completion: ((ProcessResult) -> Void)? = nil) {
        run(["add", "-A"]) { completion?($0) }
    }

    func unstage(_ paths: [String], completion: ((ProcessResult) -> Void)? = nil) {
        guard !paths.isEmpty else { completion?(ProcessResult(exitCode: 0, stdout: "", stderr: "")); return }
        run(["reset", "-q", "HEAD", "--"] + paths) { completion?($0) }
    }

    func unstageAll(completion: ((ProcessResult) -> Void)? = nil) {
        run(["reset", "-q", "HEAD"]) { completion?($0) }
    }

    /// Discard working-tree changes. Untracked files are removed with `clean`.
    func discard(_ paths: [String], untracked: Bool, completion: ((ProcessResult) -> Void)? = nil) {
        guard !paths.isEmpty else { return }
        if untracked {
            run(["clean", "-fd", "--"] + paths) { r in
                if r.ok {
                    self.run(["checkout", "--"] + paths) { completion?($0) }
                } else {
                    completion?(r)
                }
            }
        } else {
            run(["checkout", "--"] + paths) { completion?($0) }
        }
    }

    func revertFileToHead(_ path: String, completion: ((ProcessResult) -> Void)? = nil) {
        run(["checkout", "HEAD", "--", path]) { completion?($0) }
    }

    // MARK: - Commit

    func commit(message: String, amend: Bool = false, signOff: Bool = false,
                completion: @escaping (ProcessResult) -> Void) {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        if signOff { args.append("--signoff") }
        run(args, completion: completion)
    }

    func commitAll(message: String, amend: Bool = false, completion: @escaping (ProcessResult) -> Void) {
        var args = ["commit", "-a", "-m", message]
        if amend { args.append("--amend") }
        run(args, completion: completion)
    }

    /// Stage everything (including untracked) then commit — the "一键提交" path.
    func commitEverything(message: String, amend: Bool = false,
                          completion: @escaping (ProcessResult) -> Void) {
        run(["add", "-A"]) { addResult in
            guard addResult.ok else { completion(addResult); return }
            self.commit(message: message, amend: amend, completion: completion)
        }
    }

    // MARK: - Remote operations

    func fetch(prune: Bool = true, onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        var args = ["fetch", "--all"]
        if prune { args.append("--prune") }
        runStreaming(args, onOutput: onOutput, onExit: onExit)
    }

    func pull(rebase: Bool = false, onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        var args = ["pull"]
        if rebase { args.append("--rebase") }
        runStreaming(args, onOutput: onOutput, onExit: onExit)
    }

    func push(forceWithLease: Bool = false, setUpstream: Bool = false,
              remote: String? = nil, branch: String? = nil,
              onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        var args = ["push"]
        if forceWithLease { args.append("--force-with-lease") }
        if setUpstream {
            args.append("--set-upstream")
            args.append(remote ?? "origin")
            if let branch { args.append(branch) }
        } else {
            if let remote { args.append(remote) }
            if let branch { args.append(branch) }
        }
        runStreaming(args, onOutput: onOutput, onExit: onExit)
    }

    /// Undo a push by moving the remote ref back. Destructive: requires force.
    func undoPush(to ref: String, mode: ResetMode,
                  onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        runStreaming(["reset", mode.rawValue, ref]) { text in
            onOutput(text)
        } onExit: { code in
            guard code == 0 else { onExit(code); return }
            self.runStreaming(["push", "--force-with-lease"], onOutput: onOutput, onExit: onExit)
        }
    }

    func pushTag(_ tag: String, onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        runStreaming(["push", "origin", tag], onOutput: onOutput, onExit: onExit)
    }

    // MARK: - Branch operations

    func checkout(_ ref: String, completion: @escaping (ProcessResult) -> Void) {
        run(["checkout", ref], completion: completion)
    }

    func createBranch(_ name: String, at ref: String?, checkout: Bool = true,
                      completion: @escaping (ProcessResult) -> Void) {
        var args = ["branch", name]
        if let ref { args.append(ref) }
        run(args) { r in
            guard r.ok, checkout else { completion(r); return }
            self.run(["checkout", name], completion: completion)
        }
    }

    func deleteBranch(_ name: String, force: Bool, completion: @escaping (ProcessResult) -> Void) {
        run(["branch", force ? "-D" : "-d", name], completion: completion)
    }

    func renameBranch(_ from: String, to: String, completion: @escaping (ProcessResult) -> Void) {
        run(["branch", "-m", from, to], completion: completion)
    }

    func merge(_ branch: String, noFF: Bool = false, squash: Bool = false,
               completion: @escaping (ProcessResult) -> Void) {
        var args = ["merge", branch]
        if noFF { args.append("--no-ff") }
        if squash { args.append("--squash") }
        run(args, completion: completion)
    }

    func rebase(onto ref: String, completion: @escaping (ProcessResult) -> Void) {
        run(["rebase", ref], completion: completion)
    }

    func cherryPick(_ hashes: [String], noCommit: Bool = false,
                    completion: @escaping (ProcessResult) -> Void) {
        guard !hashes.isEmpty else { return }
        var args = ["cherry-pick"]
        if noCommit { args.append("-n") }
        args.append(contentsOf: hashes)
        run(args, completion: completion)
    }

    func revert(_ hashes: [String], noCommit: Bool = false,
                completion: @escaping (ProcessResult) -> Void) {
        guard !hashes.isEmpty else { return }
        var args = ["revert", "--no-edit"]
        if noCommit { args.append("-n") }
        args.append(contentsOf: hashes)
        run(args, completion: completion)
    }

    func reset(to ref: String, mode: ResetMode, completion: @escaping (ProcessResult) -> Void) {
        run(["reset", mode.rawValue, ref], completion: completion)
    }

    /// Move the current branch back to its upstream, keeping the work in the
    /// index — the safe half of "undo my pushed commits".
    func resetToUpstream(mode: ResetMode = .soft, completion: @escaping (ProcessResult) -> Void) {
        run(["reset", mode.rawValue, "@{u}"], completion: completion)
    }

    func createTag(_ name: String, at ref: String?, message: String?,
                   completion: @escaping (ProcessResult) -> Void) {
        var args = ["tag"]
        if let message { args.append(contentsOf: ["-a", name, "-m", message]) }
        else { args.append(name) }
        if let ref { args.append(ref) }
        run(args, completion: completion)
    }

    func deleteTag(_ name: String, completion: @escaping (ProcessResult) -> Void) {
        run(["tag", "-d", name], completion: completion)
    }

    // MARK: - Stash

    func stashes(completion: @escaping ([GitStashEntry]) -> Void) {
        run(["stash", "list", "--pretty=format:%gd%x1f%gs%x1f%cr"]) { r in
            guard r.ok else { completion([]); return }
            var out: [GitStashEntry] = []
            for (idx, line) in r.stdout.split(separator: "\n").enumerated() {
                let p = line.components(separatedBy: "\u{1f}")
                let msg = p.count > 1 ? p[1] : ""
                let date = p.count > 2 ? p[2] : ""
                // "WIP on main: abc123 subject"
                var branch = ""
                if let r1 = msg.range(of: "on "), let r2 = msg.range(of: ":", range: r1.upperBound..<msg.endIndex) {
                    branch = String(msg[r1.upperBound..<r2.lowerBound])
                }
                out.append(GitStashEntry(index: idx, message: msg, branch: branch, date: date))
            }
            completion(out)
        }
    }

    func stashSave(message: String?, includeUntracked: Bool = true,
                   completion: ((ProcessResult) -> Void)? = nil) {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message { args.append(contentsOf: ["-m", message]) }
        run(args) { completion?($0) }
    }

    func stashApply(index: Int, pop: Bool, completion: ((ProcessResult) -> Void)? = nil) {
        run(["stash", pop ? "pop" : "apply", "stash@{\(index)}"]) { completion?($0) }
    }

    func stashDrop(index: Int, completion: ((ProcessResult) -> Void)? = nil) {
        run(["stash", "drop", "stash@{\(index)}"]) { completion?($0) }
    }

    // MARK: - Diffs

    func diff(path: String, staged: Bool, completion: @escaping (String) -> Void) {
        var args = ["diff", "--no-color", "-U3"]
        if staged { args.append("--cached") }
        args.append(contentsOf: ["--", path])
        run(args) { completion($0.ok || !$0.stdout.isEmpty ? $0.stdout : $0.stderr) }
    }

    func diffAll(staged: Bool, completion: @escaping (String) -> Void) {
        var args = ["diff", "--no-color", "-U3"]
        if staged { args.append("--cached") }
        run(args) { completion($0.stdout) }
    }

    func showCommit(_ hash: String, completion: @escaping (String) -> Void) {
        run(["show", "--no-color", "-U3", "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n    %s%n%n%b", hash]) {
            completion($0.stdout)
        }
    }

    func diffBetween(_ a: String, _ b: String, completion: @escaping (String) -> Void) {
        run(["diff", "--no-color", "-U3", a, b]) { completion($0.stdout) }
    }

    func diffAgainstWorkingTree(_ ref: String, completion: @escaping (String) -> Void) {
        run(["diff", "--no-color", "-U3", ref]) { completion($0.stdout) }
    }

    /// Read a file's contents at a revision (used for side-by-side conflict view).
    func fileContent(at ref: String, path: String, completion: @escaping (String?) -> Void) {
        run(["show", "\(ref):\(path)"]) { r in
            completion(r.ok ? r.stdout : nil)
        }
    }

    func conflictSides(path: String, completion: @escaping (String?, String?, String?) -> Void) {
        guard let root else { completion(nil, nil, nil); return }
        queue.async {
            let base = ProcessRunner.run(ProcessRunner.gitPath(), ["show", ":1:\(path)"], cwd: root)
            let ours = ProcessRunner.run(ProcessRunner.gitPath(), ["show", ":2:\(path)"], cwd: root)
            let theirs = ProcessRunner.run(ProcessRunner.gitPath(), ["show", ":3:\(path)"], cwd: root)
            DispatchQueue.main.async {
                completion(base.ok ? base.stdout : nil, ours.ok ? ours.stdout : nil, theirs.ok ? theirs.stdout : nil)
            }
        }
    }

    func resolveConflict(path: String, useOurs: Bool, completion: ((ProcessResult) -> Void)? = nil) {
        run(["checkout", useOurs ? "--ours" : "--theirs", "--", path]) { r in
            guard r.ok else { completion?(r); return }
            self.run(["add", "--", path]) { completion?($0) }
        }
    }

    // MARK: - Sequencer control

    func abortOperation(_ operation: String, completion: @escaping (ProcessResult) -> Void) {
        let sub: String
        switch operation {
        case "merge": sub = "merge"
        case "rebase": sub = "rebase"
        case "cherry-pick": sub = "cherry-pick"
        case "revert": sub = "revert"
        default: sub = "merge"
        }
        run([sub, "--abort"], completion: completion)
    }

    func continueOperation(_ operation: String, completion: @escaping (ProcessResult) -> Void) {
        let sub: String
        switch operation {
        case "merge": sub = "merge"
        case "rebase": sub = "rebase"
        case "cherry-pick": sub = "cherry-pick"
        case "revert": sub = "revert"
        default: sub = "merge"
        }
        run([sub, "--continue"], completion: completion)
    }

    func skipOperation(_ operation: String, completion: @escaping (ProcessResult) -> Void) {
        run([operation == "rebase" ? "rebase" : "cherry-pick", "--skip"], completion: completion)
    }

    // MARK: - History surgery helpers

    /// Amend the message of the most recent commit.
    func rewordLastCommit(_ message: String, completion: @escaping (ProcessResult) -> Void) {
        run(["commit", "--amend", "-m", message], completion: completion)
    }

    /// Remove the most recent commit but keep its changes staged.
    func undoLastCommit(completion: @escaping (ProcessResult) -> Void) {
        run(["reset", "--soft", "HEAD~1"], completion: completion)
    }

    func lastCommitMessage(completion: @escaping (String) -> Void) {
        run(["log", "-1", "--pretty=%B"]) { completion($0.stdout.trimmed) }
    }

    func blame(path: String, completion: @escaping (String) -> Void) {
        run(["blame", "--date=short", "--", path]) { completion($0.stdout) }
    }

    func shortStatus(completion: @escaping (String) -> Void) {
        run(["status", "--short"]) { completion($0.stdout) }
    }

    func stagedDiffForAI(completion: @escaping (String) -> Void) {
        run(["diff", "--cached", "--no-color", "-U2"]) { completion($0.stdout) }
    }
}
