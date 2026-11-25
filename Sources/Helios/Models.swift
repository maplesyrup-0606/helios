import Foundation

/// One sub-tab in a pane; each maps to its own tmux session.
struct PaneTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}

/// The two terminal panes of a context, by position.
enum PaneSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? "Left" : "Right" }
    var other: PaneSide { self == .left ? .right : .left }
}

/// Where a pane's terminals run.
enum PaneKind: String, Codable, CaseIterable {
    /// This Mac, in local tmux.
    case local
    /// A host over ssh, in remote tmux with auto-reconnect.
    case ssh
    /// No terminal.
    case none
}

/// What one pane connects to and what it runs. Either pane can be any machine.
struct PaneConfig: Codable, Equatable {
    var kind: PaneKind = .local
    /// Host alias from ~/.ssh/config (or user@host); only used by ssh panes.
    var host: String = ""
    /// Working directory. Empty means home.
    var dir: String = ""
    /// Run by the primary tab when its session is first created (e.g. `claude`). Empty for none.
    var startupCommand: String = ""
    /// Point a plain `claude` startup command at this pane's own conversation.
    var resumeConversation = true
    /// Sub-tabs; the first is the primary and runs the startup command, the rest are plain shells.
    var tabs: [PaneTab] = [PaneTab(name: "main")]

    init(kind: PaneKind = .local, host: String = "", dir: String = "", startupCommand: String = "",
         resumeConversation: Bool = true, tabs: [PaneTab] = [PaneTab(name: "main")]) {
        self.kind = kind
        self.host = host
        self.dir = dir
        self.startupCommand = startupCommand
        self.resumeConversation = resumeConversation
        self.tabs = tabs.isEmpty ? [PaneTab(name: "main")] : tabs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(PaneKind.self, forKey: .kind) ?? .local
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        resumeConversation = try c.decodeIfPresent(Bool.self, forKey: .resumeConversation) ?? true
        tabs = try c.decodeIfPresent([PaneTab].self, forKey: .tabs) ?? []
        if tabs.isEmpty { tabs = [PaneTab(name: "main")] }
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    var trimmedDir: String { dir.trimmingCharacters(in: .whitespaces) }
    var isLocal: Bool { kind == .local }
    /// An ssh pane with a host to connect to.
    var isSSH: Bool { kind == .ssh && !trimmedHost.isEmpty }
    /// Whether the pane has terminals at all.
    var hasTerminal: Bool { isLocal || isSSH }

    /// e.g. `~/proj` or `fir:~/scratch/proj`, for tooltips and subtitles.
    var location: String {
        switch kind {
        case .local: return trimmedDir.isEmpty ? "~" : trimmedDir
        case .ssh: return trimmedHost + (trimmedDir.isEmpty ? "" : ":" + trimmedDir)
        case .none: return "none"
        }
    }

    /// The parts a running terminal was launched with; changing any needs fresh sessions.
    var launchTarget: [String] { [kind.rawValue, trimmedHost, trimmedDir] }
}

/// A research context: two terminal panes, each on whichever machine the project lives on.
struct WorkContext: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var left: PaneConfig
    var right: PaneConfig
    /// Free-form markdown scratchpad.
    var notes: String = ""
    /// Fraction of the width given to the left pane.
    var splitRatio: Double = 0.5

    /// A new context: Claude on this Mac on the left, an ssh pane (host to fill in) on the right.
    init(name: String, localDir: String) {
        self.name = name
        left = PaneConfig(kind: .local, dir: localDir, startupCommand: "claude", tabs: [PaneTab(name: "claude")])
        right = PaneConfig(kind: .ssh)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, left, right, notes, splitRatio
        // Before panes were configurable: left was always local, right always ssh.
        case localDir, startupCommand, resumeConversation, host, remoteDir, remoteTabs, localTabs
    }

    /// Tolerates contexts saved by older versions, including the fixed local/ssh layout.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
        if let left = try c.decodeIfPresent(PaneConfig.self, forKey: .left),
           let right = try c.decodeIfPresent(PaneConfig.self, forKey: .right) {
            self.left = left
            self.right = right
            return
        }
        let startup = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? "claude"
        var localTabs = try c.decodeIfPresent([PaneTab].self, forKey: .localTabs) ?? []
        if localTabs.isEmpty {
            let first = startup.split(separator: " ").first.map(String.init) ?? ""
            localTabs = [PaneTab(name: first.isEmpty ? "main" : first)]
        }
        left = PaneConfig(kind: .local,
                          dir: try c.decode(String.self, forKey: .localDir),
                          startupCommand: startup,
                          resumeConversation: try c.decodeIfPresent(Bool.self, forKey: .resumeConversation) ?? true,
                          tabs: localTabs)
        right = PaneConfig(kind: .ssh,
                           host: try c.decodeIfPresent(String.self, forKey: .host) ?? "",
                           dir: try c.decodeIfPresent(String.self, forKey: .remoteDir) ?? "",
                           tabs: try c.decodeIfPresent([PaneTab].self, forKey: .remoteTabs) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(left, forKey: .left)
        try c.encode(right, forKey: .right)
        try c.encode(notes, forKey: .notes)
        try c.encode(splitRatio, forKey: .splitRatio)
    }

    subscript(side: PaneSide) -> PaneConfig {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }

    func tabs(_ side: PaneSide) -> [PaneTab] { self[side].tabs }

    mutating func setTabs(_ side: PaneSide, _ tabs: [PaneTab]) { self[side].tabs = tabs }

    /// Which pane a sub-tab belongs to.
    func side(of tab: UUID) -> PaneSide? {
        PaneSide.allCases.first { side in self[side].tabs.contains { $0.id == tab } }
    }

    /// tmux session for a sub-tab, tied to ids so renames don't orphan it. Names don't depend on
    /// the machine, so they match sessions from before panes were configurable: the left pane's
    /// primary is `helios-local-<id>` and the right's is `helios-<id>`.
    func tmuxSession(_ side: PaneSide, for tab: PaneTab) -> String {
        let base = (side == .left ? "helios-local-" : "helios-") + id.uuidString.prefix(8).lowercased()
        return tab.id == self[side].tabs.first?.id ? base : base + "-" + tab.id.uuidString.prefix(4).lowercased()
    }

    /// Panes on ssh hosts, right first (where SSH lived before panes were configurable).
    var sshSides: [PaneSide] { [.right, .left].filter { self[$0].isSSH } }

    /// The ssh pane that SLURM jobs, remote files and remote git status follow.
    var primarySSHSide: PaneSide? { sshSides.first }

    var hasHost: Bool { primarySSHSide != nil }

    /// Host for jobs, files and remote git; empty when no pane is on ssh.
    var host: String { primarySSHSide.map { self[$0].trimmedHost } ?? "" }

    /// Directory on that host; empty means home.
    var remoteDir: String { primarySSHSide.map { self[$0].trimmedDir } ?? "" }

    /// The first local pane's directory (local git status, downloads); nil when neither pane is local.
    var localDir: String? {
        PaneSide.allCases.first { self[$0].isLocal }.map { self[$0].dir }
    }

    /// One line for the sidebar and palette, e.g. `~/proj · fir`.
    var summary: String {
        var parts: [String] = []
        for side in PaneSide.allCases where self[side].hasTerminal {
            let p = self[side]
            let part = p.isLocal ? p.location : p.trimmedHost
            if !parts.contains(part) { parts.append(part) }
        }
        return parts.isEmpty ? "no terminals" : parts.joined(separator: " · ")
    }
}

/// Loads and saves contexts as JSON in ~/Library/Application Support/Helios.
@MainActor
final class ContextStore: ObservableObject {
    @Published var contexts: [WorkContext] = [] { didSet { save() } }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Helios", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contexts.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([WorkContext].self, from: data) {
            contexts = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(contexts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum SSHConfig {
    /// Concrete `Host` aliases from ~/.ssh/config (wildcard patterns skipped).
    static func hosts() -> [String] {
        let path = NSString(string: "~/.ssh/config").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var result: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count > 1, parts[0].lowercased() == "host" else { continue }
            for alias in parts.dropFirst() where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                result.append(String(alias))
            }
        }
        return result
    }
}
