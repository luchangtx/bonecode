import AppKit

struct RunConfig: Codable, Hashable {
    var id: String
    var name: String
    var command: String
    var workingDirectory: String
    var kind: String
    var symbolName: String
    var detectedPort: Int?
    var autoOpenBrowser: Bool
    var isCustom: Bool

    static func make(id: String, name: String, command: String, directory: String,
                     kind: String, symbol: String, port: Int? = nil,
                     autoOpen: Bool = false, custom: Bool = false) -> RunConfig {
        RunConfig(id: id, name: name, command: command, workingDirectory: directory,
                  kind: kind, symbolName: symbol, detectedPort: port,
                  autoOpenBrowser: autoOpen, isCustom: custom)
    }
}

/// Detects how to build/run the current workspace and launches it in the terminal.
final class ProjectRunner {

    private(set) var configs: [RunConfig] = []
    private(set) var workspaceRoot: URL?
    private(set) var projectSummary: String = ""

    var onConfigsChanged: (() -> Void)?

    /// True while a configuration launched from here is still running.
    private(set) var isRunning = false
    /// Notifies the toolbar so the run controls can reflect the state.
    var onRunningStateChanged: ((Bool) -> Void)?
    private var runningSession: TerminalSession?

    private var portWatchTimer: Timer?
    private var watchedSession: TerminalSession?
    private var didOpenBrowser = false

    // MARK: - Detection

    func refreshConfigs() {
        configs = []
        projectSummary = ""
        guard let root = AppState.shared.workspaceRoot else {
            workspaceRoot = nil
            onConfigsChanged?()
            return
        }
        workspaceRoot = root
        let fm = FileManager.default
        let path = root.path
        var kinds: [String] = []

        // ---- Java / Maven
        if fm.fileExists(atPath: path + "/pom.xml") {
            kinds.append("Maven")
            let pom = (try? String(contentsOfFile: path + "/pom.xml", encoding: .utf8)) ?? ""
            let isSpringBoot = pom.contains("spring-boot")
            let wrapper = fm.isExecutableFile(atPath: path + "/mvnw")
            let mvn = wrapper ? "./mvnw" : (ProcessRunner.which("mvn") != nil ? "mvn" : nil)
            let port = detectSpringPort(root: root)

            if isSpringBoot {
                kinds.append("Spring Boot")
                if let mvn {
                    configs.append(.make(
                        id: "spring-boot-run",
                        name: "Spring Boot 运行",
                        command: "\(mvn) spring-boot:run",
                        directory: path,
                        kind: "Spring Boot",
                        symbol: "leaf",
                        port: port,
                        autoOpen: false
                    ))
                    configs.append(.make(
                        id: "spring-boot-debug",
                        name: "Spring Boot 运行（dev 配置）",
                        command: "\(mvn) spring-boot:run -Dspring-boot.run.profiles=dev",
                        directory: path,
                        kind: "Spring Boot",
                        symbol: "leaf",
                        port: port,
                        autoOpen: false
                    ))
                } else {
                    configs.append(.make(
                        id: "spring-boot-missing",
                        name: "Spring Boot 运行（缺少 Maven）",
                        command: "echo '未找到 mvn，也没有 ./mvnw 包装器。请先安装 Maven 或在项目里生成包装器：mvn -N wrapper:wrapper'",
                        directory: path,
                        kind: "Spring Boot",
                        symbol: "exclamationmark.triangle"
                    ))
                }
            }
            if let mvn {
                configs.append(.make(
                    id: "maven-package",
                    name: "Maven 打包（跳过测试）",
                    command: "\(mvn) clean package -DskipTests",
                    directory: path, kind: "Maven", symbol: "shippingbox"
                ))
                configs.append(.make(
                    id: "maven-test",
                    name: "Maven 测试",
                    command: "\(mvn) test",
                    directory: path, kind: "Maven", symbol: "checkmark.seal"
                ))
            }
        }

        // ---- Gradle
        if fm.fileExists(atPath: path + "/build.gradle") || fm.fileExists(atPath: path + "/build.gradle.kts") {
            kinds.append("Gradle")
            let wrapper = fm.isExecutableFile(atPath: path + "/gradlew")
            let gradle = wrapper ? "./gradlew" : (ProcessRunner.which("gradle") != nil ? "gradle" : nil)
            let buildText = ((try? String(contentsOfFile: path + "/build.gradle", encoding: .utf8)) ?? "")
                + ((try? String(contentsOfFile: path + "/build.gradle.kts", encoding: .utf8)) ?? "")
            if buildText.contains("org.springframework.boot") {
                kinds.append("Spring Boot")
                if let gradle {
                    configs.append(.make(
                        id: "gradle-bootrun", name: "Spring Boot 运行",
                        command: "\(gradle) bootRun", directory: path,
                        kind: "Spring Boot", symbol: "leaf", port: detectSpringPort(root: root)
                    ))
                }
            }
            if let gradle {
                configs.append(.make(id: "gradle-build", name: "Gradle 构建",
                                     command: "\(gradle) build -x test", directory: path,
                                     kind: "Gradle", symbol: "shippingbox"))
            }
        }

        // ---- Node / front-end
        let packageURL = root.appendingPathComponent("package.json")
        if fm.fileExists(atPath: packageURL.path),
           let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = json["scripts"] as? [String: String] ?? [:]
            var deps: [String: Any] = (json["dependencies"] as? [String: Any]) ?? [:]
            for (k, v) in (json["devDependencies"] as? [String: Any]) ?? [:] { deps[k] = v }

            var framework = "Node"
            if deps["vue"] != nil { framework = "Vue" }
            else if deps["next"] != nil { framework = "Next.js" }
            else if deps["nuxt"] != nil { framework = "Nuxt" }
            else if deps["react"] != nil { framework = "React" }
            else if deps["svelte"] != nil { framework = "Svelte" }
            else if deps["express"] != nil { framework = "Express" }
            if deps["vite"] != nil { framework += " + Vite" }
            kinds.append(framework)

            let pm = packageManager(in: root)
            let hasNodeModules = fm.fileExists(atPath: path + "/node_modules")

            let devScript = ["dev", "serve", "start", "develop"].first { scripts[$0] != nil }
            if let devScript {
                var command = "\(pm) run \(devScript)"
                if !hasNodeModules { command = "\(pm) install && " + command }
                configs.append(.make(
                    id: "node-dev",
                    name: "\(framework) 开发服务器",
                    command: command,
                    directory: path,
                    kind: framework,
                    symbol: "play.rectangle",
                    port: guessDevPort(root: root),
                    autoOpen: true
                ))
            } else if !hasNodeModules {
                configs.append(.make(id: "node-install", name: "安装依赖 (\(pm) install)",
                                     command: "\(pm) install", directory: path,
                                     kind: framework, symbol: "shippingbox"))
            }
            if scripts["build"] != nil {
                configs.append(.make(id: "node-build", name: "构建生产包",
                                     command: "\(pm) run build", directory: path,
                                     kind: framework, symbol: "shippingbox"))
            }
            if scripts["test"] != nil {
                configs.append(.make(id: "node-test", name: "运行测试",
                                     command: "\(pm) test", directory: path,
                                     kind: framework, symbol: "checkmark.seal"))
            }
            if scripts["lint"] != nil {
                configs.append(.make(id: "node-lint", name: "代码检查",
                                     command: "\(pm) run lint", directory: path,
                                     kind: framework, symbol: "text.magnifyingglass"))
            }
        }

        // ---- Go
        if fm.fileExists(atPath: path + "/go.mod") {
            kinds.append("Go")
            configs.append(.make(id: "go-run", name: "go run", command: "go run .",
                                 directory: path, kind: "Go", symbol: "play.fill"))
            configs.append(.make(id: "go-test", name: "go test", command: "go test ./...",
                                 directory: path, kind: "Go", symbol: "checkmark.seal"))
            configs.append(.make(id: "go-build", name: "go build", command: "go build ./...",
                                 directory: path, kind: "Go", symbol: "shippingbox"))
        }

        // ---- Rust
        if fm.fileExists(atPath: path + "/Cargo.toml") {
            kinds.append("Rust")
            configs.append(.make(id: "cargo-run", name: "cargo run", command: "cargo run",
                                 directory: path, kind: "Rust", symbol: "play.fill"))
            configs.append(.make(id: "cargo-test", name: "cargo test", command: "cargo test",
                                 directory: path, kind: "Rust", symbol: "checkmark.seal"))
        }

        // ---- Python
        let pythonMarkers = ["pyproject.toml", "requirements.txt", "setup.py", "manage.py"]
        if pythonMarkers.contains(where: { fm.fileExists(atPath: path + "/" + $0) }) {
            kinds.append("Python")
            if fm.fileExists(atPath: path + "/manage.py") {
                configs.append(.make(id: "django-run", name: "Django 开发服务器",
                                     command: "python3 manage.py runserver", directory: path,
                                     kind: "Python", symbol: "play.rectangle",
                                     port: 8000, autoOpen: true))
            }
            if fm.fileExists(atPath: path + "/main.py") {
                configs.append(.make(id: "python-main", name: "运行 main.py",
                                     command: "python3 main.py", directory: path,
                                     kind: "Python", symbol: "play.fill"))
            }
            if fm.fileExists(atPath: path + "/app.py") {
                configs.append(.make(id: "python-app", name: "运行 app.py",
                                     command: "python3 app.py", directory: path,
                                     kind: "Python", symbol: "play.fill"))
            }
            configs.append(.make(id: "pytest", name: "pytest", command: "python3 -m pytest -q",
                                 directory: path, kind: "Python", symbol: "checkmark.seal"))
        }

        // ---- Docker Compose
        if fm.fileExists(atPath: path + "/docker-compose.yml") || fm.fileExists(atPath: path + "/docker-compose.yaml")
            || fm.fileExists(atPath: path + "/compose.yml") {
            kinds.append("Docker")
            configs.append(.make(id: "compose-up", name: "docker compose up",
                                 command: "docker compose up", directory: path,
                                 kind: "Docker", symbol: "shippingbox"))
            configs.append(.make(id: "compose-down", name: "docker compose down",
                                 command: "docker compose down", directory: path,
                                 kind: "Docker", symbol: "stop.circle"))
        }

        // ---- Makefile
        if fm.fileExists(atPath: path + "/Makefile") {
            kinds.append("Make")
            configs.append(.make(id: "make", name: "make", command: "make", directory: path,
                                 kind: "Make", symbol: "hammer"))
        }

        // ---- Custom configs persisted by the user
        configs.append(contentsOf: loadCustomConfigs())

        if configs.isEmpty {
            configs.append(.make(
                id: "generic-shell",
                name: "打开终端",
                command: "",
                directory: path,
                kind: "通用",
                symbol: "terminal"
            ))
        }

        projectSummary = kinds.isEmpty ? "通用项目" : kinds.joined(separator: " · ")
        onConfigsChanged?()
        NotificationCenter.default.post(name: .runConfigsChanged, object: nil)
    }

    // MARK: - Helpers

    private func packageManager(in root: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if fm.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if fm.fileExists(atPath: root.appendingPathComponent("bun.lockb").path) { return "bun" }
        return "npm"
    }

    private func detectSpringPort(root: URL) -> Int? {
        let candidates = [
            "src/main/resources/application.properties",
            "src/main/resources/application.yml",
            "src/main/resources/application.yaml",
            "src/main/resources/application-dev.properties"
        ]
        for rel in candidates {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let port = firstPortMatch(in: text) { return port }
        }
        return nil
    }

    private func guessDevPort(root: URL) -> Int? {
        let candidates = ["vite.config.js", "vite.config.ts", "vue.config.js", "webpack.config.js", ".env"]
        for rel in candidates {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let port = firstPortMatch(in: text) { return port }
        }
        return 5173
    }

    private func firstPortMatch(in text: String) -> Int? {
        let patterns = [
            #"(?:port|PORT)\s*[:=]\s*['\"]?(\d{2,5})"#,
            #"port\(s\):\s*(\d{2,5})"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            if let match = re.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 {
                if let value = Int((text as NSString).substring(with: match.range(at: 1))) { return value }
            }
        }
        return nil
    }

    // MARK: - Custom configs

    private let customKey = "customRunConfigs"

    func loadCustomConfigs() -> [RunConfig] {
        guard let data = UserDefaults.standard.data(forKey: customKey),
              let list = try? JSONDecoder().decode([RunConfig].self, from: data) else { return [] }
        return list
    }

    func addCustomConfig(_ config: RunConfig) {
        var list = loadCustomConfigs()
        list.append(config)
        saveCustom(list)
        refreshConfigs()
    }

    func removeCustomConfig(id: String) {
        var list = loadCustomConfigs()
        list.removeAll { $0.id == id }
        saveCustom(list)
        refreshConfigs()
    }

    private func saveCustom(_ list: [RunConfig]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
    }

    // MARK: - Running

    func run(_ config: RunConfig) {
        guard let terminal = AppState.shared.terminalPanel else { return }

        if EditorSettings.shared.autoSaveOnRun {
            AppState.shared.editorArea?.saveAll()
        }

        // The terminal panel starts collapsed. Without this the command really
        // runs but there is nothing on screen, so the button looks dead.
        NotificationCenter.default.post(name: .revealTerminal, object: nil)

        guard !config.command.isEmpty else {
            terminal.newTerminal()
            AppState.shared.postStatus("已打开终端")
            return
        }

        let session = terminal.runCommand(config.command,
                                         cwd: config.workingDirectory,
                                         title: config.name,
                                         workingDirectory: config.workingDirectory)
        runningSession = session
        session.onProcessExit = { [weak self] in
            self?.setRunning(false)
        }
        setRunning(true)
        AppState.shared.postStatus("已启动「\(config.name)」，输出在下方终端面板")

        if config.autoOpenBrowser || config.detectedPort != nil {
            startPortWatch(port: config.detectedPort, autoOpen: config.autoOpenBrowser)
        }
    }

    func runDefault() {
        NotificationCenter.default.post(name: .revealTerminal, object: nil)
        guard let first = configs.first else {
            AppState.shared.terminalPanel?.newTerminal()
            AppState.shared.postStatus("未检测到运行配置，已打开终端")
            return
        }
        run(first)
    }

    /// First press sends Ctrl-C. A second press within five seconds escalates to
    /// SIGKILL, because plenty of processes (dev servers, Maven) ignore or
    /// swallow the interrupt.
    func stop() {
        stopPortWatch()
        guard let terminal = AppState.shared.terminalPanel else { return }

        if let requested = stopRequestedAt, Date().timeIntervalSince(requested) < 5 {
            stopRequestedAt = nil
            terminal.forceKillActiveProcess()
            AppState.shared.postStatus("已强制结束进程 (SIGKILL)")
            return
        }

        stopRequestedAt = Date()
        terminal.stopActiveProcess()
        AppState.shared.postStatus("已发送 Ctrl-C；若进程仍在运行，请再点一次强制结束")
    }

    private var stopRequestedAt: Date?

    private func setRunning(_ value: Bool) {
        guard isRunning != value else { return }
        isRunning = value
        if !value { runningSession = nil }
        onRunningStateChanged?(value)
    }

    // MARK: - Port detection → browser

    private func startPortWatch(port: Int?, autoOpen: Bool) {
        stopPortWatch()
        didOpenBrowser = false
        watchedSession = AppState.shared.terminalPanel?.activeSession

        var ticks = 0
        portWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            if ticks > 90 { timer.invalidate(); return }

            guard let session = self.watchedSession else { return }
            let text = session.emulator.recentText(lines: 60)
            guard let url = Self.firstLocalURL(in: text) else { return }

            timer.invalidate()
            guard !self.didOpenBrowser else { return }
            self.didOpenBrowser = true

            AppState.shared.postStatus("服务已启动：\(url)")
            if autoOpen {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
    }

    private func stopPortWatch() {
        portWatchTimer?.invalidate()
        portWatchTimer = nil
        watchedSession = nil
    }

    static func firstLocalURL(in text: String) -> String? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::(\d{2,5}))?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var url = (text as NSString).substring(with: match.range)
        if url.contains("0.0.0.0") { url = url.replacingOccurrences(of: "0.0.0.0", with: "localhost") }
        return url
    }
}
