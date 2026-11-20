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

@MainActor
private func makeTerminalView() -> LocalProcessTerminalView {
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.optionAsMetaKey = true
    Theme.current.apply(to: view)
    return view
}

func expandTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

/// Single-quotes a string for a POSIX shell, keeping a leading `~/` expandable.
func remoteShellPath(_ path: String) -> String {
    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    if path == "~" { return "~" }
    if path.hasPrefix("~/") { return "~/" + quote(String(path.dropFirst(2))) }
    return quote(path)
}

/// The left panel: a login shell in the context's directory that runs the startup command.
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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let dir = expandTilde(context.localDir.isEmpty ? "~" : context.localDir)
        terminal.startProcess(executable: shell, args: ["-l"], environment: terminalEnvironment(), currentDirectory: dir)
        isRunning = true
        let cmd = context.startupCommand.trimmingCharacters(in: .whitespaces)
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

    init(context: WorkContext) {
        self.context = context
        local = LocalSession(context: context)
        git = GitMonitor(directory: context.localDir)
        jobs = context.hasHost ? JobsMonitor(host: context.host) : nil
        files = context.hasHost ? FileBrowser(host: context.host, startDir: context.remoteDir, localDir: context.localDir) : nil
        selectedRemoteTab = context.remoteTabs.first?.id
        if context.hasHost, let first = context.remoteTabs.first {
            remoteSessions[first.id] = SSHSession(context: context, tab: first)
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
        let session = SSHSession(context: context, tab: tab)
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
        local.stop()
        remoteSessions.values.forEach { $0.stop() }
    }
}
