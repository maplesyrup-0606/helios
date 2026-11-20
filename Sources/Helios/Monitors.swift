import Foundation

/// Repeats an async action while active; restarting resets the interval.
@MainActor
final class Poller {
    private var task: Task<Void, Never>?
    private let interval: TimeInterval
    private let action: @MainActor () async -> Void

    init(every interval: TimeInterval, action: @escaping @MainActor () async -> Void) {
        self.interval = interval
        self.action = action
    }

    func setActive(_ active: Bool) {
        task?.cancel()
        task = nil
        guard active else { return }
        task = Task { [interval, action] in
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

// MARK: - Git

@MainActor
final class GitMonitor: ObservableObject {
    struct Change: Identifiable, Equatable {
        var id: String { path }
        let status: String
        let path: String
    }

    struct Commit: Identifiable, Equatable {
        let id: String
        let subject: String
        let age: String
    }

    @Published private(set) var isRepo = false
    @Published private(set) var branch = ""
    /// e.g. "ahead 1, behind 2"; empty when in sync or no upstream.
    @Published private(set) var tracking = ""
    @Published private(set) var changes: [Change] = []
    @Published private(set) var commits: [Commit] = []

    private let directory: String
    private lazy var poller = Poller(every: 10) { [weak self] in await self?.refresh() }

    init(directory: String) {
        self.directory = directory
    }

    func setActive(_ active: Bool) { poller.setActive(active) }

    func refresh() async {
        let dir = expandTilde(directory)
        let status = await Shell.run("/usr/bin/git", ["-C", dir, "status", "--porcelain=v1", "-b"], timeout: 10)
        guard status.ok else {
            isRepo = false
            return
        }
        isRepo = true
        var lines = status.stdout.split(separator: "\n").map(String.init)
        if let header = lines.first, header.hasPrefix("## ") {
            lines.removeFirst()
            parseHeader(String(header.dropFirst(3)))
        }
        changes = lines.compactMap { line in
            guard line.count > 3 else { return nil }
            return Change(status: String(line.prefix(2)).trimmingCharacters(in: .whitespaces), path: String(line.dropFirst(3)))
        }
        let log = await Shell.run("/usr/bin/git", ["-C", dir, "log", "-n", "12", "--format=%h%x09%s%x09%cr"], timeout: 10)
        commits = log.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            return parts.count == 3 ? Commit(id: parts[0], subject: parts[1], age: parts[2]) : nil
        }
    }

    /// Parses `main...origin/main [ahead 1, behind 2]` or `No commits yet on main`.
    private func parseHeader(_ header: String) {
        if header.hasPrefix("No commits yet on ") {
            branch = String(header.dropFirst("No commits yet on ".count))
            tracking = ""
            return
        }
        let name = header.split(separator: " ").first.map(String.init) ?? header
        branch = name.components(separatedBy: "...").first ?? name
        if let open = header.firstIndex(of: "["), let close = header.lastIndex(of: "]") {
            tracking = String(header[header.index(after: open)..<close])
        } else {
            tracking = ""
        }
    }
}

// MARK: - SLURM jobs

@MainActor
final class JobsMonitor: ObservableObject {
    struct Job: Identifiable, Equatable {
        let id: String
        let name: String
        let state: String
        let elapsed: String
        let limit: String
        let nodes: String
        let reason: String
        let partition: String

        var isRunning: Bool { state == "RUNNING" }
        var isPending: Bool { state == "PENDING" }
    }

    enum Status: Equatable {
        case loading
        case ok
        /// No shared connection yet (e.g. waiting on 2FA in the terminal).
        case notConnected
        /// Host has no SLURM.
        case unavailable
        case error(String)
    }

    /// Latest tqdm line from a running job's log, parsed.
    struct Progress: Equatable {
        var fraction: Double
        var label: String
        var counts: String
        var elapsed: String
        var remaining: String
        var rate: String
        var postfix: String
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var jobs: [Job] = []
    /// Keyed by job id; only running jobs whose logs contain a tqdm bar.
    @Published private(set) var progress: [String: Progress] = [:]
    @Published private(set) var lastUpdated: Date?
    /// Output of the last on-demand command (nvidia-smi, quota), shown in the drawer.
    @Published private(set) var detailTitle = ""
    @Published private(set) var detailOutput = ""
    @Published private(set) var isRunningDetail = false

    let host: String
    /// Ticks often so jobs appear soon after the terminal authenticates; squeue itself runs every 30s.
    private lazy var poller = Poller(every: 8) { [weak self] in await self?.poll() }
    private static let refreshInterval: TimeInterval = 30

    init(host: String) {
        self.host = host
    }

    var runningCount: Int { jobs.filter(\.isRunning).count }
    var pendingCount: Int { jobs.filter(\.isPending).count }

    func setActive(_ active: Bool) { poller.setActive(active) }

    private func poll() async {
        if status == .ok, let last = lastUpdated, Date().timeIntervalSince(last) < Self.refreshInterval { return }
        await refresh()
    }

    func refresh() async {
        let command = "command -v squeue >/dev/null 2>&1 || { echo __NO_SLURM__; exit 0; }; squeue -u \"$USER\" -h -o '%i|%j|%T|%M|%l|%D|%R|%P'"
        let result = await slurm(command, timeout: 20)
        if result.status == 255 {
            status = .notConnected
            return
        }
        if result.stdout.contains("__NO_SLURM__") {
            status = .unavailable
            jobs = []
            return
        }
        guard result.ok else {
            status = .error(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        jobs = result.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8 else { return nil }
            return Job(id: f[0], name: f[1], state: f[2], elapsed: f[3], limit: f[4], nodes: f[5], reason: f[6], partition: f[7])
        }
        status = .ok
        lastUpdated = Date()
        await refreshProgress()
    }

    /// Reads the tail of each running job's StdErr/StdOut and keeps the last tqdm line.
    private func refreshProgress() async {
        let running = jobs.filter(\.isRunning).map(\.id)
        guard !running.isEmpty else {
            progress = [:]
            return
        }
        let result = await slurm(Self.progressCommand(jobIDs: running), timeout: 20)
        guard result.ok else { return }
        var parsed: [String: Progress] = [:]
        var current: String?
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("@@@ ") {
                current = String(line.dropFirst(4))
            } else if let id = current, let p = Self.parseTqdm(line) {
                parsed[id] = p
            }
        }
        progress = parsed
    }

    /// Remote shell snippet printing `@@@ <id>` then that job's last tqdm line, per job.
    nonisolated static func progressCommand(jobIDs: [String]) -> String {
        // Job ids come from squeue (digits, `_`, `[`/`]` for arrays); quote them anyway.
        let ids = jobIDs.map { "'\($0)'" }.joined(separator: " ")
        return """
        for j in \(ids); do echo "@@@ $j"; \
        scontrol show job "$j" 2>/dev/null | sed -n 's/^ *Std\\(Out\\|Err\\)=//p' | sort -u | \
        while read -r f; do [ -r "$f" ] && tail -c 16384 "$f"; echo; done | \
        tr '\\r' '\\n' | grep -E '[0-9]{1,3}%\\|' | tail -n 1; done
        """
    }

    nonisolated private static let tqdmPattern = try! NSRegularExpression(pattern:
        #"^\s*(?:(.*?):?\s*)?(\d{1,3})%\|[^|]*\|\s*([^\s\[]+)\s*\[([^<\]]*)(?:<([^,\]]*))?(?:,\s*([^,\]]*))?(?:,\s*(.*))?\]"#)

    /// Parses e.g. `Epoch 2:  45%|████▌     | 450/1000 [01:23<01:40,  5.50it/s, loss=0.12]`.
    nonisolated static func parseTqdm(_ line: String) -> Progress? {
        let ns = line as NSString
        guard let m = tqdmPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
        }
        guard let percent = Double(group(2)) else { return nil }
        return Progress(fraction: min(1, percent / 100), label: group(1), counts: group(3),
                        elapsed: group(4), remaining: group(5), rate: group(6), postfix: group(7))
    }

    /// GPU usage on the login node, or inside a running job's allocation.
    func showGPU(for job: Job? = nil) async {
        let query = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv"
        let command = job.map { "srun --jobid=\($0.id) --overlap \(query)" } ?? query
        await runDetail(title: job.map { "GPU · job \($0.id) (\($0.name))" } ?? "GPU · \(host)", command: command)
    }

    func showQuota() async {
        // diskusage_report exists on Alliance (DRAC) clusters; fall back to quota/df elsewhere.
        let command = "if command -v diskusage_report >/dev/null 2>&1; then diskusage_report; else quota -s 2>/dev/null; df -h \"$HOME\" 2>/dev/null; fi"
        await runDetail(title: "Disk quota · \(host)", command: command)
    }

    func showJobDetails(_ job: Job) async {
        await runDetail(title: "Job \(job.id) · \(job.name)", command: "scontrol show job \(job.id)")
    }

    func cancel(_ job: Job) async {
        let result = await slurm("scancel \(job.id)", timeout: 20)
        if !result.ok {
            detailTitle = "scancel \(job.id) failed"
            detailOutput = result.stderr
        }
        await refresh()
    }

    /// Non-interactive ssh commands skip the login profile, which is often what puts SLURM on PATH
    /// (e.g. /opt/slurm/bin on UBC CS). Add the usual locations, then fall back to the login shell's PATH.
    private static let slurmPathSetup = #"export PATH="$PATH:/opt/slurm/bin:/usr/local/slurm/bin:/cm/shared/apps/slurm/current/bin"; "#
        + #"command -v squeue >/dev/null 2>&1 || PATH="$PATH:$("${SHELL:-sh}" -lc 'printf %s "$PATH"' </dev/null 2>/dev/null | tail -n 1)"; "#

    private func slurm(_ command: String, timeout: TimeInterval) async -> CommandResult {
        await Shell.remote(host, Self.slurmPathSetup + command, timeout: timeout)
    }

    func clearDetail() {
        detailTitle = ""
        detailOutput = ""
    }

    private func runDetail(title: String, command: String) async {
        detailTitle = title
        detailOutput = ""
        isRunningDetail = true
        let result = await slurm(command, timeout: 60)
        isRunningDetail = false
        let text = (result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        detailOutput = result.status == 255 ? "Not connected — authenticate in the SSH pane first." : text
    }
}

// MARK: - Remote files

@MainActor
final class FileBrowser: ObservableObject {
    struct Entry: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date
    }

    /// Absolute remote path being shown (resolved via `pwd`).
    @Published private(set) var path = ""
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var transferStatus: String?

    let host: String
    let localDir: String
    private let startDir: String
    private var hasLoaded = false

    init(host: String, startDir: String, localDir: String) {
        self.host = host
        self.startDir = startDir.isEmpty ? "~" : startDir
        self.localDir = localDir
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load(startDir)
    }

    func load(_ target: String? = nil) async {
        let target = target ?? path
        isLoading = true
        defer { isLoading = false }
        let command = "cd \(remoteShellPath(target)) && pwd && find . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%T@\\t%f\\n'"
        let result = await Shell.remote(host, command, timeout: 20)
        guard result.ok else {
            error = result.status == 255
                ? "Not connected — authenticate in the SSH pane first."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        hasLoaded = true
        error = nil
        var lines = result.stdout.split(separator: "\n").map(String.init)
        path = lines.isEmpty ? target : lines.removeFirst()
        entries = lines.compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard f.count == 4 else { return nil }
            return Entry(name: f[3], isDirectory: f[0] == "d",
                         size: Int64(f[1]) ?? 0,
                         modified: Date(timeIntervalSince1970: Double(f[2]) ?? 0))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    func open(_ entry: Entry) async {
        guard entry.isDirectory else { return }
        await load(fullPath(entry))
    }

    func goUp() async {
        let parent = (path as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    func fullPath(_ entry: Entry) -> String {
        (path as NSString).appendingPathComponent(entry.name)
    }

    /// Copies remote entries into the context's local directory.
    func download(_ selection: [Entry]) async {
        guard !selection.isEmpty else { return }
        let sources = selection.map { "\(host):\(remoteShellPath(fullPath($0)))" }
        await transfer(running: "Downloading \(selection.count) item(s) to \(localDir)",
                       done: "Downloaded \(selection.count) item(s) to \(localDir)",
                       args: ["-az", "-e", SSHOptions.rsyncShell] + sources + [expandTilde(localDir) + "/"])
    }

    /// Copies local files/folders into the current remote directory.
    func upload(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await transfer(running: "Uploading \(urls.count) item(s) to \(path)",
                       done: "Uploaded \(urls.count) item(s) to \(path)",
                       args: ["-az", "-e", SSHOptions.rsyncShell] + urls.map(\.path) + ["\(host):\(remoteShellPath(path))/"])
        await load()
    }

    private func transfer(running: String, done: String, args: [String]) async {
        guard await Shell.hasSharedConnection(host) else {
            transferStatus = "Transfer failed: not connected — authenticate in the SSH pane first."
            return
        }
        transferStatus = running + "…"
        let result = await Shell.run("/usr/bin/rsync", args, timeout: 3600)
        transferStatus = result.ok
            ? done + " ✓"
            : "Transfer failed: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
