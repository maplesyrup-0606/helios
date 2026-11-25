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

/// Local tmux, used so local panes (e.g. a running `claude`) survive app restarts.
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

    static func kill(session name: String) {
        run(["kill-session", "-t", "=" + name])
    }
}

/// Ends tmux sessions wherever a pane runs them.
enum PaneTmux {
    /// Kills the given sub-tabs' sessions (all of the pane's by default). Remote kills only use
    /// an existing shared connection, so they never prompt for 2FA.
    static func kill(_ context: WorkContext, _ side: PaneSide, tabs: [PaneTab]? = nil) async {
        let pane = context[side]
        let names = (tabs ?? pane.tabs).map { context.tmuxSession(side, for: $0) }
        if pane.isLocal {
            names.forEach(LocalTmux.kill(session:))
        } else if pane.isSSH, !names.isEmpty {
            let command = names.map { "tmux kill-session -t \(shellQuote("=" + $0)) 2>/dev/null" }.joined(separator: "; ")
            _ = await Shell.remote(pane.trimmedHost, command + "; true", timeout: 15)
        }
    }

    /// Kills only the local panes' sessions, synchronously.
    static func killLocal(_ context: WorkContext) {
        for side in PaneSide.allCases where context[side].isLocal {
            context[side].tabs.forEach { LocalTmux.kill(session: context.tmuxSession(side, for: $0)) }
        }
    }
}

/// One sub-tab's terminal: a login shell in the pane's directory, on this Mac or over ssh,
/// inside a tmux session so it outlives the app. The pane's primary tab also runs the startup
/// command (e.g. Claude) when its session is first created. Over ssh it reconnects
/// automatically when the connection drops.
@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        /// The process is running (for ssh: authenticating or attached).
        case running
        /// Connection lost; next attempt scheduled at the given date.
        case waiting(attempt: Int, retryAt: Date)
        /// The shell (or remote tmux) ended normally; no auto-reconnect.
        case ended
        /// Gave up after too many consecutive failures.
        case failed
    }

    let terminal = makeTerminalView()
    @Published private(set) var state: State = .running
    private let context: WorkContext
    let side: PaneSide
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

    init(context: WorkContext, side: PaneSide, tab: PaneTab) {
        self.context = context
        self.side = side
        self.tab = tab
        super.init()
        terminal.processDelegate = self
        start()
    }

    private var pane: PaneConfig { context[side] }
    var isRemote: Bool { pane.isSSH }
    var host: String { pane.trimmedHost }
    private var isPrimary: Bool { tab.id == pane.tabs.first?.id }
    private var tmuxName: String { context.tmuxSession(side, for: tab) }

    /// Starts (or, after it ended, restarts) the terminal.
    func start() {
        retryTask?.cancel()
        retryTask = nil
        isStopping = false
        state = .running
        startedAt = Date()
        if isRemote { startSSH() } else { startLocal() }
    }

    private func startLocal() {
        let dir = expandTilde(pane.trimmedDir.isEmpty ? "~" : pane.trimmedDir)
        if let tmux = LocalTmux.path {
            // Only a new session runs the startup command; an existing one (from before an
            // app restart) is just reattached. The command is run by an interactive login shell
            // rather than typed in, since zsh startup can discard early keystrokes. When it
            // exits, the pane falls back to a normal shell.
            if LocalTmux.run(["has-session", "-t", "=" + tmuxName]) != 0 {
                let cmd = startupCommand()
                var args = ["new-session", "-d", "-s", tmuxName, "-c", dir]
                if !cmd.isEmpty {
                    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                    args.append("exec \(shell) -lic \(shellQuote(cmd + "; exec " + shell + " -l"))")
                }
                LocalTmux.run(args)
            }
            for (option, value) in tmuxSessionOptions {
                // set-option takes a pane target, so an exact session match needs the trailing colon.
                LocalTmux.run(["set-option", "-t", "=" + tmuxName + ":", option, value])
            }
            terminal.startProcess(executable: tmux, args: ["attach-session", "-t", "=" + tmuxName],
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

    /// ssh into the host and attach (or create) the tab's tmux session. A newly created
    /// session runs the startup command through a login shell, like a local one.
    private var sshArguments: [String] {
        var tmux = "tmux new-session -A -s \(shellQuote(tmuxName))"
        let dir = pane.trimmedDir
        if !dir.isEmpty { tmux += " -c \(remoteShellPath(dir))" }
        let cmd = startupCommand()
        if !cmd.isEmpty {
            // tmux only uses this when it creates the session; -A reattaches an existing one.
            tmux += " " + shellQuote(#"exec "$SHELL" -lic "# + shellQuote(cmd + #"; exec "$SHELL" -l"#))
        }
        for (option, value) in tmuxSessionOptions { tmux += " \\; set-option \(option) \(value)" }
        // Fall back to a plain login shell if tmux is missing on this host.
        let remote = "command -v tmux >/dev/null 2>&1 && exec \(tmux) || exec $SHELL -l"
        return [
            "-t",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ] + SSHOptions.connectionSharing + [host, remote]
    }

    private func startSSH() {
        terminal.startProcess(executable: "/usr/bin/ssh", args: sshArguments, environment: terminalEnvironment())
    }

    /// The primary tab's startup command, pointed at the pane's Claude conversation.
    /// Records which conversation that is, so the next fresh start returns to it.
    private func startupCommand() -> String {
        guard isPrimary else { return "" }
        let pinned = ClaudePins.shared[context.id, side]
        let launch = isRemote ? ClaudeHistory.remoteLaunch(for: pane, pinned: pinned)
                              : ClaudeHistory.launch(for: pane, pinned: pinned)
        if let id = launch.sessionID { ClaudePins.shared[context.id, side] = id }
        return launch.command
    }

    /// Manual reconnect: resets the backoff and skips any pending wait.
    func reconnectNow() {
        attempt = 0
        if state == .running { return }
        start()
    }

    /// Kills the client even while it looks connected (e.g. a frozen pane) and reattaches tmux.
    /// `terminate()` doesn't call `processTerminated`, so no auto-retry races this start.
    func refresh() {
        attempt = 0
        if state == .running { terminal.terminate() }
        start()
    }

    func stop() {
        isStopping = true
        retryTask?.cancel()
        if state == .running { terminal.terminate() }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isStopping else { return }
        guard isRemote else {
            state = .ended
            terminal.feed(text: "\r\n\u{1b}[2m[helios] shell exited — press Restart to start a new one\u{1b}[0m\r\n")
            return
        }
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
            self?.start()
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
    /// Started sub-tabs of both panes, by tab id (ids are unique across panes).
    @Published private(set) var sessions: [UUID: TerminalSession] = [:]
    @Published private var selected: [PaneSide: UUID] = [:]
    let git: GitMonitor
    let jobs: JobsMonitor?
    let files: FileBrowser?
    private var context: WorkContext

    enum Attention: Int, Comparable {
        /// A primary tab's output burst ended (e.g. Claude finished or is waiting for input).
        case done = 1
        /// A terminal rang the bell.
        case bell = 2
        static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
    }

    /// Called when something in this context wants the user's attention.
    var onAttention: ((Attention) -> Void)?
    private var bursts: [PaneSide: Burst] = [:]
    /// Output must run at least this long, then stop for `quietPeriod`, to count as "done".
    /// Claude's spinner redraws continuously while working, so it going quiet is the signal.
    private static let minBurst: TimeInterval = 3
    private static let quietPeriod: TimeInterval = 4

    private struct Burst {
        var start: Date?
        var lastOutput = Date.distantPast
        var watch: Task<Void, Never>?
    }

    init(context: WorkContext) {
        self.context = context
        git = GitMonitor(directory: context.localDir, host: context.hasHost ? context.host : nil, remoteDir: context.remoteDir)
        jobs = context.hasHost ? JobsMonitor(host: context.host) : nil
        files = context.hasHost
            ? FileBrowser(host: context.host, startDir: context.remoteDir, localDir: context.localDir ?? "~/Downloads")
            : nil
        for side in PaneSide.allCases {
            selected[side] = context[side].tabs.first?.id
            if context[side].hasTerminal, let first = context[side].tabs.first {
                sessions[first.id] = makeSession(side, first)
            }
        }
    }

    private func makeSession(_ side: PaneSide, _ tab: PaneTab) -> TerminalSession {
        let session = TerminalSession(context: context, side: side, tab: tab)
        session.terminal.onBell = { [weak self] in self?.onAttention?(.bell) }
        // "Went quiet" is only meaningful for a primary tab running a startup command (Claude).
        if tab.id == context[side].tabs.first?.id, !context[side].startupCommand.isEmpty {
            session.terminal.onOutput = { [weak self] in self?.noteOutput(side) }
        }
        return session
    }

    func selectedTab(_ side: PaneSide) -> UUID? { selected[side] ?? context[side].tabs.first?.id }

    func select(_ tab: UUID, side: PaneSide) { selected[side] = tab }

    /// A pane's primary session (the first tab).
    func primary(_ side: PaneSide) -> TerminalSession? {
        context[side].tabs.first.flatMap { sessions[$0.id] }
    }

    /// The sub-tab currently shown in a pane.
    func visible(_ side: PaneSide) -> TerminalSession? {
        selectedTab(side).flatMap { sessions[$0] }
    }

    /// The primary session of the pane that jobs/files/remote git follow (sidebar status dot).
    var primarySSH: TerminalSession? { context.primarySSHSide.flatMap(primary) }

    /// Primary sessions of every ssh pane, one per host.
    var sshPrimaries: [TerminalSession] {
        var seen = Set<String>()
        return context.sshSides.compactMap(primary).filter { seen.insert($0.host).inserted }
    }

    /// Session for a sub-tab, starting it the first time it is shown; nil when the pane has
    /// no terminal.
    func session(for tab: PaneTab, side: PaneSide) -> TerminalSession? {
        guard context[side].hasTerminal else { return nil }
        if let existing = sessions[tab.id] { return existing }
        let session = makeSession(side, tab)
        sessions[tab.id] = session
        return session
    }

    /// Replaces a pane's primary tab with a fresh session (killing its tmux session), so the
    /// startup command runs again, e.g. to open a different Claude conversation.
    func restartPrimary(_ side: PaneSide) async {
        guard let tab = context[side].tabs.first else { return }
        sessions[tab.id]?.stop()
        sessions[tab.id] = nil
        await PaneTmux.kill(context, side, tabs: [tab])
        guard context[side].hasTerminal else { return }
        sessions[tab.id] = makeSession(side, tab)
    }

    /// Which pane a terminal view belongs to, if any.
    func side(of view: NSView) -> PaneSide? {
        sessions.values.first { $0.terminal === view }?.side
    }

    private func noteOutput(_ side: PaneSide) {
        let now = Date()
        var burst = bursts[side] ?? Burst()
        if burst.start == nil { burst.start = now }
        burst.lastOutput = now
        defer { bursts[side] = burst }
        guard burst.watch == nil else { return }
        burst.watch = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let current = self.bursts[side],
                      Date().timeIntervalSince(current.lastOutput) >= Self.quietPeriod else { continue }
                if let start = current.start, current.lastOutput.timeIntervalSince(start) >= Self.minBurst {
                    self.onAttention?(.done)
                }
                self.bursts[side] = Burst()
                return
            }
        }
    }

    /// Picks up edits that don't require restarting terminals (names, notes, sub-tabs).
    func update(_ context: WorkContext) {
        self.context = context
        let live = Set(PaneSide.allCases.flatMap { context[$0].tabs.map(\.id) })
        for (id, session) in sessions where !live.contains(id) {
            session.stop()
            sessions[id] = nil
        }
        for side in PaneSide.allCases {
            if let current = selected[side], !context[side].tabs.contains(where: { $0.id == current }) {
                selected[side] = context[side].tabs.first?.id
            }
        }
    }

    /// Polling only runs for the context on screen.
    func setActive(_ active: Bool) {
        git.setActive(active)
        jobs?.setActive(active)
    }

    func shutdown() {
        setActive(false)
        bursts.values.forEach { $0.watch?.cancel() }
        sessions.values.forEach { $0.stop() }
    }
}
