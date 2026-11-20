import AppKit
import SwiftTerm

/// Environment for child processes: the app's own plus sane terminal defaults.
private func terminalEnvironment() -> [String] {
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "Helios"
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    return env.map { "\($0.key)=\($0.value)" }
}

/// Terminal view that reports bells and output so background contexts can flag attention.
final class HeliosTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    var onOutput: (() -> Void)?

    override func bell(source: Terminal) {
        onBell?()
        super.bell(source: source)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }
}

@MainActor
private func makeTerminalView() -> HeliosTerminalView {
    let view = HeliosTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.optionAsMetaKey = true
    Theme.current.apply(to: view)
    return view
}

func expandTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

/// Single-quotes a string for a POSIX shell.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Single-quotes a string for a POSIX shell, keeping a leading `~/` expandable.
func remoteShellPath(_ path: String) -> String {
    let quote = shellQuote
    if path == "~" { return "~" }
    if path.hasPrefix("~/") { return "~/" + quote(String(path.dropFirst(2))) }
    return quote(path)
}

/// Session-scoped (not global) tmux options for Helios-owned sessions: Helios draws its own tabs,
/// and mouse mode makes the wheel scroll tmux history. Shift+drag still selects text natively.
let tmuxSessionOptions = [("status", "off"), ("mouse", "on")]

/// Local tmux, used so the left pane (e.g. a running `claude`) survives app restarts.
enum LocalTmux {
    static let path: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func sessionName(for context: WorkContext) -> String {
        "helios-local-" + context.id.uuidString.prefix(8).lowercased()
    }

    /// Runs a short tmux command synchronously; returns its exit status.
    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        guard let path else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Block on a semaphore rather than waitUntilExit(): that spins the run loop, which can
        // re-enter SwiftUI mid-update and crash (AttributeGraph precondition failure).
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return -1 }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return -1
        }
        return process.terminationStatus
    }

    static func kill(_ context: WorkContext) {
        run(["kill-session", "-t", "=" + sessionName(for: context)])
    }
}

enum ClaudeHistory {
    /// Claude Code stores conversations per project in ~/.claude/projects/<path with separators as '-'>.
    static func hasConversations(in directory: String) -> Bool {
        let path = expandTilde(directory)
        let encoded = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let folder = (expandTilde("~/.claude/projects") as NSString).appendingPathComponent(encoded)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    /// The command to start a new session with: `claude` gains `--continue` when there is a
    /// previous conversation to resume and the user didn't already pass a resume flag.
    static func startupCommand(for context: WorkContext) -> String {
        let cmd = context.startupCommand.trimmingCharacters(in: .whitespaces)
        let words = cmd.split(separator: " ").map(String.init)
        guard context.resumeConversation, words.first == "claude",
              !words.contains(where: { ["--continue", "-c", "--resume", "-r"].contains($0) }),
              hasConversations(in: context.localDir.isEmpty ? "~" : context.localDir)
        else { return cmd }
        return cmd + " --continue"
    }
}

/// The left panel: a login shell in the context's directory that runs the startup command.
/// Lives in a local tmux session when tmux is installed, so it outlives the app.
@MainActor
final class LocalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let terminal = makeTerminalView()
    @Published private(set) var isRunning = false
    private let context: WorkContext

    init(context: WorkContext) {
        self.context = context
        super.init()
        terminal.processDelegate = self
        start()
    }

    func start() {
        let dir = expandTilde(context.localDir.isEmpty ? "~" : context.localDir)
        let cmd = ClaudeHistory.startupCommand(for: context)
        isRunning = true

        if let tmux = LocalTmux.path {
            let name = LocalTmux.sessionName(for: context)
            // Only a new session runs the startup command; an existing one (from before an
            // app restart) is just reattached. The command is run by an interactive login shell
            // rather than typed in, since zsh startup can discard early keystrokes. When it
            // exits, the pane falls back to a normal shell.
            if LocalTmux.run(["has-session", "-t", "=" + name]) != 0 {
                var args = ["new-session", "-d", "-s", name, "-c", dir]
                if !cmd.isEmpty {
                    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                    args.append("exec \(shell) -lic \(shellQuote(cmd + "; exec " + shell + " -l"))")
                }
                LocalTmux.run(args)
            }
            for (option, value) in tmuxSessionOptions {
                // set-option takes a pane target, so an exact session match needs the trailing colon.
                LocalTmux.run(["set-option", "-t", "=" + name + ":", option, value])
            }
            terminal.startProcess(executable: tmux, args: ["attach-session", "-t", "=" + name],
                                  environment: terminalEnvironment(), currentDirectory: dir)
            return
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(executable: shell, args: ["-l"], environment: terminalEnvironment(), currentDirectory: dir)
        if !cmd.isEmpty {
            // The pty buffers this until the shell is ready to read it.
            terminal.send(data: ArraySlice(Array((cmd + "\r").utf8)))
        }
    }

    func stop() { if isRunning { terminal.terminate() } }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        terminal.feed(text: "\r\n\u{1b}[2m[helios] shell exited — press Restart to start a new one\u{1b}[0m\r\n")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// The right panel: ssh into the host and attach a per-context tmux session,
/// reconnecting automatically when the connection drops.
@MainActor
final class SSHSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        /// ssh is running (authenticating or attached).
        case running
        /// Connection lost; next attempt scheduled at the given date.
        case waiting(attempt: Int, retryAt: Date)
        /// Remote side ended normally (tmux exited or detached); no auto-reconnect.
        case ended
        /// Gave up after too many consecutive failures.
        case failed
    }

    let terminal = makeTerminalView()
    @Published private(set) var state: State = .running
    private let context: WorkContext
    let tab: RemoteTab
    private var attempt = 0
    private var startedAt = Date()
    private var retryTask: Task<Void, Never>?
    private var isStopping = false

    /// ssh exits with 255 on connection/auth errors; anything else came from the remote command.
    private static let sshErrorExit: Int32 = 255
    private static let maxAttempts = 8
    /// A session that stayed up this long counts as healthy and resets the backoff.
    private static let healthyDuration: TimeInterval = 30

    init(context: WorkContext, tab: RemoteTab) {
        self.context = context
        self.tab = tab
        super.init()
        terminal.processDelegate = self
        connect()
    }

    private var sshArguments: [String] {
        var tmux = "tmux new-session -A -s \(context.tmuxSession(for: tab))"
        let dir = context.remoteDir.trimmingCharacters(in: .whitespaces)
        if !dir.isEmpty { tmux += " -c \(remoteShellPath(dir))" }
        for (option, value) in tmuxSessionOptions { tmux += " \\; set-option \(option) \(value)" }
        // Fall back to a plain login shell if tmux is missing on this host.
        let remote = "command -v tmux >/dev/null 2>&1 && exec \(tmux) || exec $SHELL -l"
        return [
            "-t",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ] + SSHOptions.connectionSharing + [context.host, remote]
    }

    func connect() {
        retryTask?.cancel()
        retryTask = nil
        isStopping = false
        state = .running
        startedAt = Date()
        terminal.startProcess(executable: "/usr/bin/ssh", args: sshArguments, environment: terminalEnvironment())
    }

    /// Manual reconnect: resets the backoff and skips any pending wait.
    func reconnectNow() {
        attempt = 0
        if state == .running { return }
        connect()
    }

    func stop() {
        isStopping = true
        retryTask?.cancel()
        if state == .running { terminal.terminate() }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isStopping else { return }
        if Date().timeIntervalSince(startedAt) > Self.healthyDuration { attempt = 0 }

        // nil means killed by a signal (e.g. network teardown); treat like a connection error.
        let connectionError = exitCode == nil || exitCode == Self.sshErrorExit
        guard connectionError else {
            state = .ended
            note("session ended (exit \(exitCode ?? 0)) — press Reconnect to reattach")
            return
        }

        attempt += 1
        guard attempt <= Self.maxAttempts else {
            state = .failed
            note("could not reconnect after \(Self.maxAttempts) attempts — press Reconnect to try again")
            return
        }
        let delay = min(30, pow(2, Double(attempt - 1)))
        state = .waiting(attempt: attempt, retryAt: Date().addingTimeInterval(delay))
        note("connection lost — reconnecting in \(Int(delay))s (attempt \(attempt)/\(Self.maxAttempts))")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func note(_ message: String) {
        terminal.feed(text: "\r\n\u{1b}[33m[helios] \(message)\u{1b}[0m\r\n")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Live terminals and monitors for one context. Kept alive across tab switches so sessions keep running.
@MainActor
final class ContextRuntime: ObservableObject {
    let local: LocalSession
    @Published private(set) var remoteSessions: [UUID: SSHSession] = [:]
    @Published var selectedRemoteTab: UUID?
    let git: GitMonitor
    let jobs: JobsMonitor?
    let files: FileBrowser?
    private var context: WorkContext

    enum Attention: Int, Comparable {
        /// Local output burst ended (e.g. Claude finished or is waiting for input).
        case done = 1
        /// A terminal rang the bell.
        case bell = 2
        static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
    }

    /// Called when something in this context wants the user's attention.
    var onAttention: ((Attention) -> Void)?
    private var burstStart: Date?
    private var lastOutput = Date.distantPast
    private var quietWatch: Task<Void, Never>?
    /// Output must run at least this long, then stop for `quietPeriod`, to count as "done".
    /// Claude's spinner redraws continuously while working, so it going quiet is the signal.
    private static let minBurst: TimeInterval = 3
    private static let quietPeriod: TimeInterval = 4

    init(context: WorkContext) {
        self.context = context
        local = LocalSession(context: context)
        git = GitMonitor(directory: context.localDir)
        jobs = context.hasHost ? JobsMonitor(host: context.host) : nil
        files = context.hasHost ? FileBrowser(host: context.host, startDir: context.remoteDir, localDir: context.localDir) : nil
        selectedRemoteTab = context.remoteTabs.first?.id
        if context.hasHost, let first = context.remoteTabs.first {
            remoteSessions[first.id] = makeSSHSession(first)
        }
        local.terminal.onBell = { [weak self] in self?.onAttention?(.bell) }
        local.terminal.onOutput = { [weak self] in self?.noteLocalOutput() }
    }

    private func makeSSHSession(_ tab: RemoteTab) -> SSHSession {
        let session = SSHSession(context: context, tab: tab)
        session.terminal.onBell = { [weak self] in self?.onAttention?(.bell) }
        return session
    }

    private func noteLocalOutput() {
        let now = Date()
        if burstStart == nil { burstStart = now }
        lastOutput = now
        guard quietWatch == nil else { return }
        quietWatch = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard Date().timeIntervalSince(self.lastOutput) >= Self.quietPeriod else { continue }
                if let start = self.burstStart, self.lastOutput.timeIntervalSince(start) >= Self.minBurst {
                    self.onAttention?(.done)
                }
                self.burstStart = nil
                self.quietWatch = nil
                return
            }
        }
    }

    /// The primary SSH session, used for the sidebar status dot.
    var primarySSH: SSHSession? {
        context.remoteTabs.first.flatMap { remoteSessions[$0.id] }
    }

    /// Session for a sub-tab, connecting lazily the first time it is shown.
    func session(for tab: RemoteTab) -> SSHSession? {
        guard context.hasHost else { return nil }
        if let existing = remoteSessions[tab.id] { return existing }
        let session = makeSSHSession(tab)
        remoteSessions[tab.id] = session
        return session
    }

    /// Picks up edits that don't require restarting terminals (names, notes, sub-tabs).
    func update(_ context: WorkContext) {
        self.context = context
        let live = Set(context.remoteTabs.map(\.id))
        for (id, session) in remoteSessions where !live.contains(id) {
            session.stop()
            remoteSessions[id] = nil
        }
        if let selected = selectedRemoteTab, !live.contains(selected) {
            selectedRemoteTab = context.remoteTabs.first?.id
        }
    }

    /// Polling only runs for the context on screen.
    func setActive(_ active: Bool) {
        git.setActive(active)
        jobs?.setActive(active)
    }

    func shutdown() {
        setActive(false)
        quietWatch?.cancel()
        local.stop()
        remoteSessions.values.forEach { $0.stop() }
    }
}
