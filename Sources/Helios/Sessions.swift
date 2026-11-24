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
        scheduleFullRepaint()
        onOutput?()
    }

    private var repaintWork: DispatchWorkItem?

    /// SwiftTerm's partial redraws can leave stale rows on screen (e.g. ECH `ESC[nX` never marks
    /// its row dirty), which garbled multi-line command editing under tmux. Once output pauses,
    /// repaint the whole pane so anything missed heals within a frame or two.
    private func scheduleFullRepaint() {
        repaintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            getTerminal().updateFullScreen()
            setNeedsDisplay(bounds)
        }
        repaintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    // Clicks and drags always select natively (tmux mouse mode would otherwise grab them into
    // copy-mode, whose selection never reaches the macOS clipboard). The wheel still goes to
    // tmux, since `scrollWheel` reads `allowMouseReporting` outside these overrides.
    override func mouseDown(with event: NSEvent) { withoutMouseReporting { super.mouseDown(with: event) } }
    override func mouseDragged(with event: NSEvent) { withoutMouseReporting { super.mouseDragged(with: event) } }
    override func mouseUp(with event: NSEvent) { withoutMouseReporting { super.mouseUp(with: event) } }

    private func withoutMouseReporting(_ body: () -> Void) {
        allowMouseReporting = false
        body()
        allowMouseReporting = true
    }

    /// The default clears the selection on every linefeed, so streaming output made it vanish.
    override func linefeed(source: Terminal) {}

    /// Cmd-C with nothing selected would otherwise wipe the clipboard. Text that claude wrapped to
    /// the pane width is copied as the original single line, so pasting it needs no cleanup.
    override func copy(_ sender: Any) {
        guard selection.active else { return }
        let (s, e) = (selection.start, selection.end)
        let firstColumn = (s.row, s.col) < (e.row, e.col) ? s.col : e.col
        let text = selection.getSelectedText()
        let unwrapped = WrappedText.unwrap(text, firstColumn: firstColumn, cols: getTerminal().cols)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(unwrapped ?? text, forType: .string)
    }

    /// macOS line-editing shortcuts, sent the way Ghostty/iTerm do. SwiftTerm sends Option-←/→ as
    /// `ESC[1;3D`-style sequences that shells (and claude, via tmux) print as stray "D"/"C", and its
    /// `keyDown` isn't overridable, so a local monitor rewrites these keys before it sees them.
    private static let lineEditingMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard let view = NSApp.keyWindow?.firstResponder as? HeliosTerminalView,
              let bytes = lineEditingBytes(for: event) else { return event }
        view.selection.active = false
        view.send(bytes)
        return nil
    }

    static func installLineEditingKeys() { _ = lineEditingMonitor }

    private static func lineEditingBytes(for event: NSEvent) -> [UInt8]? {
        switch (event.modifierFlags.intersection([.command, .shift, .option, .control]), event.specialKey) {
        case (.option, .leftArrow?): [0x1b, 0x62]   // ESC b: word back
        case (.option, .rightArrow?): [0x1b, 0x66]  // ESC f: word forward
        case (.option, .delete?): [0x1b, 0x7f]      // ESC DEL: delete word back
        case (.command, .leftArrow?): [0x01]        // Ctrl-A: start of line
        case (.command, .rightArrow?): [0x05]       // Ctrl-E: end of line
        case (.command, .delete?): [0x15]           // Ctrl-U: delete to start of line
        default: nil
        }
    }
}

@MainActor
private func makeTerminalView() -> HeliosTerminalView {
    HeliosTerminalView.installLineEditingKeys()
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
/// and mouse mode makes the wheel scroll tmux history. Clicks and drags stay native (see HeliosTerminalView).
let tmuxSessionOptions = [("status", "off"), ("mouse", "on")]

/// Local tmux, used so the left pane (e.g. a running `claude`) survives app restarts.
enum LocalTmux {
    static let path: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

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

    /// Kills every local tmux session belonging to a context (all its local sub-tabs).
    static func kill(_ context: WorkContext) {
        context.localTabs.forEach { kill(session: context.localTmuxSession(for: $0)) }
    }

    static func kill(session name: String) {
        run(["kill-session", "-t", "=" + name])
    }
}

/// A local sub-tab: a login shell in the context's directory. The primary tab also runs the
/// startup command (Claude). Lives in a local tmux session when tmux is installed, so it
/// outlives the app.
@MainActor
final class LocalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let terminal = makeTerminalView()
    @Published private(set) var isRunning = false
    private let context: WorkContext
    let tab: PaneTab

    init(context: WorkContext, tab: PaneTab) {
        self.context = context
        self.tab = tab
        super.init()
        terminal.processDelegate = self
        start()
    }

    private var isPrimary: Bool { tab.id == context.localTabs.first?.id }

    func start() {
        let dir = expandTilde(context.localDir.isEmpty ? "~" : context.localDir)
        isRunning = true

        if let tmux = LocalTmux.path {
            let name = context.localTmuxSession(for: tab)
            // Only a new session runs the startup command; an existing one (from before an
            // app restart) is just reattached. The command is run by an interactive login shell
            // rather than typed in, since zsh startup can discard early keystrokes. When it
            // exits, the pane falls back to a normal shell.
            if LocalTmux.run(["has-session", "-t", "=" + name]) != 0 {
                let cmd = startupCommand()
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

        let cmd = startupCommand()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(executable: shell, args: ["-l"], environment: terminalEnvironment(), currentDirectory: dir)
        if !cmd.isEmpty {
            // The pty buffers this until the shell is ready to read it.
            terminal.send(data: ArraySlice(Array((cmd + "\r").utf8)))
        }
    }

    /// The primary tab's startup command, pointed at the context's Claude conversation.
    /// Records which conversation that is, so the next fresh start returns to it.
    private func startupCommand() -> String {
        guard isPrimary else { return "" }
        let launch = ClaudeHistory.launch(for: context, pinned: ClaudePins.shared[context.id])
        if let id = launch.sessionID { ClaudePins.shared[context.id] = id }
        return launch.command
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
    let tab: PaneTab
    private var attempt = 0
    private var startedAt = Date()
    private var retryTask: Task<Void, Never>?
    private var isStopping = false

    /// ssh exits with 255 on connection/auth errors; anything else came from the remote command.
    private static let sshErrorExit: Int32 = 255
    private static let maxAttempts = 8
    /// A session that stayed up this long counts as healthy and resets the backoff.
    private static let healthyDuration: TimeInterval = 30

    init(context: WorkContext, tab: PaneTab) {
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

    /// Kills ssh even while it looks connected (e.g. a frozen pane) and reattaches tmux.
    /// `terminate()` doesn't call `processTerminated`, so no auto-retry races this connect.
    func refresh() {
        attempt = 0
        if state == .running { terminal.terminate() }
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
    @Published private(set) var localSessions: [UUID: LocalSession] = [:]
    @Published var selectedLocalTab: UUID?
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
        git = GitMonitor(directory: context.localDir, host: context.hasHost ? context.host : nil, remoteDir: context.remoteDir)
        jobs = context.hasHost ? JobsMonitor(host: context.host) : nil
        files = context.hasHost ? FileBrowser(host: context.host, startDir: context.remoteDir, localDir: context.localDir) : nil
        selectedRemoteTab = context.remoteTabs.first?.id
        if context.hasHost, let first = context.remoteTabs.first {
            remoteSessions[first.id] = makeSSHSession(first)
        }
        selectedLocalTab = context.localTabs.first?.id
        if let first = context.localTabs.first {
            localSessions[first.id] = makeLocalSession(first)
        }
    }

    private func makeLocalSession(_ tab: PaneTab) -> LocalSession {
        let session = LocalSession(context: context, tab: tab)
        session.terminal.onBell = { [weak self] in self?.onAttention?(.bell) }
        // "Went quiet" is only meaningful for the primary tab, where Claude runs.
        if tab.id == context.localTabs.first?.id {
            session.terminal.onOutput = { [weak self] in self?.noteLocalOutput() }
        }
        return session
    }

    /// The primary local session (Claude).
    var primaryLocal: LocalSession? {
        context.localTabs.first.flatMap { localSessions[$0.id] }
    }

    /// The local sub-tab currently shown.
    var visibleLocal: LocalSession? {
        (selectedLocalTab ?? context.localTabs.first?.id).flatMap { localSessions[$0] }
    }

    /// The SSH sub-tab currently shown.
    var visibleSSH: SSHSession? {
        (selectedRemoteTab ?? context.remoteTabs.first?.id).flatMap { remoteSessions[$0] }
    }

    /// Local session for a sub-tab, starting it the first time it is shown.
    func localSession(for tab: PaneTab) -> LocalSession {
        if let existing = localSessions[tab.id] { return existing }
        let session = makeLocalSession(tab)
        localSessions[tab.id] = session
        return session
    }

    /// Replaces the primary local tab with a fresh session (killing its tmux session), so the
    /// startup command runs again, e.g. to open a different Claude conversation.
    func restartPrimaryLocal() {
        guard let tab = context.localTabs.first else { return }
        localSessions[tab.id]?.stop()
        LocalTmux.kill(session: context.localTmuxSession(for: tab))
        localSessions[tab.id] = makeLocalSession(tab)
    }

    /// Which pane a terminal view belongs to, if any.
    func side(of view: NSView) -> PaneSide? {
        if localSessions.values.contains(where: { $0.terminal === view }) { return .local }
        if remoteSessions.values.contains(where: { $0.terminal === view }) { return .remote }
        return nil
    }

    private func makeSSHSession(_ tab: PaneTab) -> SSHSession {
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
    func session(for tab: PaneTab) -> SSHSession? {
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
        let liveLocal = Set(context.localTabs.map(\.id))
        for (id, session) in localSessions where !liveLocal.contains(id) {
            session.stop()
            localSessions[id] = nil
        }
        if let selected = selectedLocalTab, !liveLocal.contains(selected) {
            selectedLocalTab = context.localTabs.first?.id
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
        localSessions.values.forEach { $0.stop() }
        remoteSessions.values.forEach { $0.stop() }
    }
}
