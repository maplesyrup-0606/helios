import Foundation

/// One sub-tab in a context's local (left) or SSH (right) pane; each maps to its own tmux session.
struct PaneTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}

enum PaneSide {
    case local, remote
}

/// A research context: one tab pairing a local terminal with a remote SSH session.
struct WorkContext: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Local working directory for the left terminal.
    var localDir: String
    /// Command run when the local session is first created (e.g. `claude`). Empty for none.
    var startupCommand: String = "claude"
    /// Add `--continue` to a `claude` startup command when the project has past conversations.
    var resumeConversation = true
    /// Host alias from ~/.ssh/config (or user@host). Empty disables the SSH panel.
    var host: String = ""
    /// Directory the remote tmux session starts in. Empty means the remote home.
    var remoteDir: String = ""
    /// Free-form markdown scratchpad.
    var notes: String = ""
    /// Fraction of the width given to the local (left) pane.
    var splitRatio: Double = 0.5
    /// SSH sub-tabs; the first one is the primary session.
    var remoteTabs: [PaneTab] = [PaneTab(name: "main")]
    /// Local sub-tabs; the first runs the startup command (Claude), the rest are plain shells.
    var localTabs: [PaneTab] = [PaneTab(name: "claude")]

    init(name: String, localDir: String) {
        self.name = name
        self.localDir = localDir
    }

    /// Tolerates contexts saved by older versions that lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        localDir = try c.decode(String.self, forKey: .localDir)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? "claude"
        resumeConversation = try c.decodeIfPresent(Bool.self, forKey: .resumeConversation) ?? true
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        remoteDir = try c.decodeIfPresent(String.self, forKey: .remoteDir) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
        remoteTabs = try c.decodeIfPresent([PaneTab].self, forKey: .remoteTabs) ?? [PaneTab(name: "main")]
        if remoteTabs.isEmpty { remoteTabs = [PaneTab(name: "main")] }
        localTabs = try c.decodeIfPresent([PaneTab].self, forKey: .localTabs) ?? []
        if localTabs.isEmpty {
            let first = startupCommand.split(separator: " ").first.map(String.init) ?? ""
            localTabs = [PaneTab(name: first.isEmpty ? "main" : first)]
        }
    }

    func tabs(_ side: PaneSide) -> [PaneTab] {
        side == .local ? localTabs : remoteTabs
    }

    mutating func setTabs(_ side: PaneSide, _ tabs: [PaneTab]) {
        if side == .local { localTabs = tabs } else { remoteTabs = tabs }
    }

    /// Local tmux session for a sub-tab. The primary keeps the original `helios-local-<id>` name
    /// so sessions from before sub-tabs existed are reattached.
    func localTmuxSession(for tab: PaneTab) -> String {
        let base = "helios-local-" + id.uuidString.prefix(8).lowercased()
        return tab.id == localTabs.first?.id ? base : base + "-" + tab.id.uuidString.prefix(4).lowercased()
    }

    /// Name of the remote tmux session for a sub-tab; tied to ids so renames don't orphan it.
    /// The primary tab keeps the original `helios-<id>` name.
    func tmuxSession(for tab: PaneTab) -> String {
        let base = "helios-" + id.uuidString.prefix(8).lowercased()
        return tab.id == remoteTabs.first?.id ? base : base + "-" + tab.id.uuidString.prefix(4).lowercased()
    }

    var hasHost: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
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
