import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { exitCode == 0 }
    var combined: String {
        var s = stdout
        if !stderr.isEmpty {
            if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
            s += stderr
        }
        return s
    }
}

/// Thin wrapper over `Process` with a GUI-friendly environment.
///
/// A GUI app launched from Finder inherits a minimal PATH, so `node`, `mvn`,
/// `npm` etc. would not be found. We merge in the usual install locations and,
/// when available, the login shell's PATH.
enum ProcessRunner {

    private static var cachedLoginPath: String?

    static let defaultPath: String = {
        var parts: [String] = []
        let home = NSHomeDirectory()
        parts.append(contentsOf: [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ])
        // Version managers people actually use
        parts.append("\(home)/.nvm/versions/node/\(ProcessRunner.newestNodeVersion())/bin")
        parts.append("\(home)/.volta/bin")
        parts.append("\(home)/.bun/bin")
        parts.append("\(home)/.cargo/bin")
        parts.append("\(home)/.pyenv/shims")
        parts.append("\(home)/.local/share/mise/shims")
        parts.append("\(home)/Library/pnpm")
        parts.append("\(home)/.gradle/bin")
        return parts.joined(separator: ":")
    }()

    private static func newestNodeVersion() -> String {
        let base = "\(NSHomeDirectory())/.nvm/versions/node"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else { return "current" }
        return items.sorted().last ?? "current"
    }

    /// Environment for spawned processes.
    static func environment(extra: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? ""
        env["PATH"] = defaultPath + (existing.isEmpty ? "" : ":" + existing)
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        // Keep git from opening interactive editors / pagers inside the GUI.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        env["GIT_CONFIG_PARAMETERS"] = "'core.pager=cat'"
        if let extra { for (k, v) in extra { env[k] = v } }
        return env
    }

    /// Run to completion and capture output. Safe to call from any queue; it
    /// blocks, so call it off the main thread.
    @discardableResult
    static func run(
        _ launchPath: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        stdin: String? = nil
    ) -> ProcessResult {
        let process = Process()
        if launchPath.contains("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath] + args
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = environment(extra: env)

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "无法启动 \(launchPath): \(error.localizedDescription)")
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        // Read before waiting so a chatty process cannot deadlock on a full pipe.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Run asynchronously off the main thread.
    static func runAsync(
        _ launchPath: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        completion: @escaping (ProcessResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = run(launchPath, args, cwd: cwd, env: env)
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Start a process and stream its merged output.
    @discardableResult
    static func stream(
        _ launchPath: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) -> Process? {
        let process = Process()
        if launchPath.contains("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath] + args
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = environment(extra: env)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { onOutput(text) }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.availableData
            if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) {
                DispatchQueue.main.async { onOutput(text) }
            }
            DispatchQueue.main.async { onExit(p.terminationStatus) }
        }

        do {
            try process.run()
            return process
        } catch {
            DispatchQueue.main.async {
                onOutput("无法启动 \(launchPath): \(error.localizedDescription)\n")
                onExit(-1)
            }
            return nil
        }
    }

    /// Locate an executable across the GUI PATH.
    static func which(_ tool: String) -> String? {
        for dir in defaultPath.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func gitPath() -> String {
        which("git") ?? "/usr/bin/git"
    }
}
