import Darwin
import Foundation

/// A pseudo-terminal running a login shell.
///
/// Uses `forkpty(3)` so the child gets its own session and controlling terminal —
/// that is what makes job control (`Ctrl-C`, `Ctrl-Z`, `fg`) behave the way a
/// real terminal does.
final class PTY {

    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = -1
    private(set) var isRunning = false

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "bonecode.pty", qos: .userInteractive)
    private var didSignalExit = false
    private var interrupts = 0

    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var cols: Int
    private(set) var rows: Int

    init?(shell: String, cwd: String?, extraEnv: [String: String] = [:], cols: Int, rows: Int) {
        self.cols = max(20, cols)
        self.rows = max(4, rows)

        var env = ProcessRunner.environment(extra: extraEnv)
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "BoneCode"
        env["COLORTERM"] = "truecolor"
        env["SHELL"] = shell
        env.removeValue(forKey: "GIT_PAGER")
        env.removeValue(forKey: "GIT_EDITOR")
        env.removeValue(forKey: "GIT_CONFIG_PARAMETERS")
        env.removeValue(forKey: "GIT_TERMINAL_PROMPT")

        // Build argv/envp before forking: the child must not allocate or call
        // into the Swift runtime between fork and exec.
        var argvStorage: [UnsafeMutablePointer<CChar>?] = [
            strdup(shell),
            strdup("-l"),
            nil
        ]
        var envStorage: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envStorage.append(nil)
        let cwdC = cwd.map { strdup($0) }

        defer {
            for p in argvStorage where p != nil { free(p) }
            for p in envStorage where p != nil { free(p) }
            if let cwdC { free(cwdC) }
        }

        var master: Int32 = -1
        var ws = winsize(ws_row: UInt16(self.rows), ws_col: UInt16(self.cols), ws_xpixel: 0, ws_ypixel: 0)

        let child = argvStorage.withUnsafeMutableBufferPointer { argvBuf -> pid_t in
            envStorage.withUnsafeMutableBufferPointer { envBuf in
                forkpty(&master, nil, nil, &ws)
            }
        }

        if child < 0 {
            return nil
        }

        if child == 0 {
            // ---- child ----
            if let cwdC { _ = chdir(cwdC) }
            _ = argvStorage.withUnsafeMutableBufferPointer { argvBuf in
                envStorage.withUnsafeMutableBufferPointer { envBuf in
                    execve(shell, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            _exit(127)
        }

        // ---- parent ----
        self.pid = child
        self.masterFD = master
        self.isRunning = true

        // Non-blocking reads so a slow consumer never stalls the shell.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        startReading()
        startExitMonitor()
    }

    deinit {
        terminate()
    }

    // MARK: - IO

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(self.masterFD, &buffer, buffer.count)
                if n > 0 {
                    let data = Data(buffer[0..<n])
                    DispatchQueue.main.async { self.onOutput?(data) }
                    if n < buffer.count { break }
                } else if n == 0 {
                    self.finish()
                    return
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    if errno == EINTR {
                        self.interrupts += 1
                        if self.interrupts > 100 { break }   // never spin forever
                        continue
                    }
                    self.finish()
                    return
                }
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            close(self.masterFD)
            self.masterFD = -1
        }
        readSource = src
        src.resume()
    }

    private func startExitMonitor() {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            let reaped = waitpid(self.pid, &status, WNOHANG)
            let code: Int32
            if reaped > 0 {
                code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : (status & 0x7F) + 128
            } else {
                code = 0
            }
            self.drainRemaining()
            DispatchQueue.main.async { self.signalExit(code) }
            src.cancel()
        }
        exitSource = src
        src.resume()
    }

    private func drainRemaining() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<64 {
            let n = read(masterFD, &buffer, buffer.count)
            guard n > 0 else { break }
            let data = Data(buffer[0..<n])
            DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
            if n < buffer.count { break }
        }
    }

    private func signalExit(_ code: Int32) {
        guard !didSignalExit else { return }
        didSignalExit = true
        isRunning = false
        onExit?(code)
    }

    /// EOF on the master fd means the shell closed its terminal. The process
    /// source reports the real status a moment later, so we only fall back to a
    /// neutral code if that never arrives.
    private func finish() {
        readSource?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.signalExit(0)
        }
    }

    // MARK: - Control

    func write(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            var stalls = 0
            while offset < data.count {
                let n = Darwin.write(masterFD, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                    stalls = 0
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // The pty buffer is full and the child is not reading. Busy
                    // looping here pegs a core and never returns; wait briefly
                    // and give up rather than freeze the caller.
                    stalls += 1
                    if stalls > 250 { break }
                    usleep(2000)
                } else {
                    break
                }
            }
        }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        let c = max(20, cols), r = max(4, rows)
        guard c != self.cols || r != self.rows else { return }
        self.cols = c
        self.rows = r
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(r), ws_col: UInt16(c), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        if pid > 0 { kill(-pid, SIGWINCH) }
    }

    /// Interrupt the foreground job (Ctrl-C).
    func sendInterrupt() {
        guard pid > 0 else { return }
        kill(-pid, SIGINT)
    }

    func terminate() {
        guard pid > 0 else { return }
        let p = pid
        pid = -1
        isRunning = false
        kill(-p, SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
            kill(-p, SIGKILL)
        }
        kill(p, SIGKILL)
        readSource?.cancel()
        exitSource?.cancel()
        readSource = nil
        exitSource = nil
    }
}
