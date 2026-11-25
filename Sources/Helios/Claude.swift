import Darwin
import Foundation

/// Reads Claude Code's on-disk state: per-project transcripts and the live-session registry.
enum ClaudeHistory {
    static let defaultProjectsRoot = expandTilde("~/.claude/projects")
    static let defaultRegistryDir = expandTilde("~/.claude/sessions")

    struct Conversation: Identifiable, Equatable {
        let id: String
        let modified: Date
        var title: String
    }

    /// Claude Code stores conversations per project in ~/.claude/projects/<path with separators as '-'>.
    static func projectFolder(for directory: String, root: String = defaultProjectsRoot) -> String {
        let path = expandTilde(directory.isEmpty ? "~" : directory)
        let encoded = String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return (root as NSString).appendingPathComponent(encoded)
    }

    static func hasConversations(in directory: String, root: String = defaultProjectsRoot) -> Bool {
        !conversations(in: directory, root: root).isEmpty
    }

    static func hasTranscript(_ id: String, in directory: String, root: String = defaultProjectsRoot) -> Bool {
        FileManager.default.fileExists(
            atPath: (projectFolder(for: directory, root: root) as NSString).appendingPathComponent(id + ".jsonl"))
    }

    /// Conversations in a project, newest first. Titles are left empty; see `title(of:in:)`.
    static func conversations(in directory: String, root: String = defaultProjectsRoot) -> [Conversation] {
        let folder = URL(fileURLWithPath: projectFolder(for: directory, root: root))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Conversation(id: url.deletingPathExtension().lastPathComponent,
                                modified: modified ?? .distantPast, title: "")
        }
        .sorted { $0.modified > $1.modified }
    }

    /// A short label for a conversation: its /rename title, else Claude's generated title,
    /// else the first thing the user typed. Only reads the ends of the file, since transcripts
    /// can be many megabytes.
    static func title(of id: String, in directory: String, root: String = defaultProjectsRoot) -> String {
        let path = (projectFolder(for: directory, root: root) as NSString).appendingPathComponent(id + ".jsonl")
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let chunk = 256 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(chunk) ? size - UInt64(chunk) : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var generated = ""
        for line in tail.split(separator: "\n").reversed() {
            if line.contains(#""type":"custom-title""#), let t = field("customTitle", in: line), !t.isEmpty { return t }
            if generated.isEmpty, line.contains(#""type":"ai-title""#), let t = field("aiTitle", in: line) { generated = t }
        }
        if !generated.isEmpty { return generated }
        try? handle.seek(toOffset: 0)
        let head = String(decoding: handle.readData(ofLength: chunk), as: UTF8.self)
        for line in head.split(separator: "\n") where line.contains(#""type":"user""#) {
            guard let obj = json(line), let message = obj["message"] as? [String: Any],
                  let text = message["content"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("<") { return String(trimmed.prefix(80)) }
        }
        return ""
    }

    /// The conversation a running Claude in the given local tmux session is in, from Claude
    /// Code's registry (~/.claude/sessions/<pid>.json, which records the tmux pane). This is
    /// Claude Code's internal state, so a missing or changed format just yields nil.
    static func liveSessionID(tmuxSession: String, registryDir: String = defaultRegistryDir) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: registryDir)) ?? []
        let entries = files.filter { $0.hasSuffix(".json") }.compactMap { name -> [String: Any]? in
            guard let data = FileManager.default.contents(atPath: (registryDir as NSString).appendingPathComponent(name)),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, isAlive(pid) else { return nil }
            return obj
        }
        return liveSessionID(tmuxSession: tmuxSession, entries: entries)
    }

    /// Prints the registry entries of live Claude processes on a remote host, one JSON object
    /// per line. Registry files are named by pid, so liveness is checked there.
    static let remoteRegistryScript = #"for f in "$HOME"/.claude/sessions/*.json; do [ -f "$f" ] || continue; p=$(basename "$f" .json); kill -0 "$p" 2>/dev/null || continue; tr -d '\n' < "$f"; echo; done"#

    /// Parses `remoteRegistryScript` output.
    static func registryEntries(fromLines output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { json($0) }
    }

    /// The newest live registry entry attached to the given tmux session (entries must already be
    /// filtered to live processes).
    static func liveSessionID(tmuxSession: String, entries: [[String: Any]]) -> String? {
        var best: (id: String, updated: Double)?
        for obj in entries {
            guard let id = obj["sessionId"] as? String, isUUID(id),
                  let tmux = obj["tmux"] as? String, tmux.split(separator: ":").first.map(String.init) == tmuxSession
            else { continue }
            let updated = (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            if best == nil || updated > best!.updated { best = (id, updated) }
        }
        return best?.id
    }

    /// The startup command when it is a plain `claude` Helios should point at a conversation;
    /// nil when resume is off or the command makes its own resume choice.
    private static func managedClaude(_ pane: PaneConfig) -> String? {
        let cmd = pane.startupCommand.trimmingCharacters(in: .whitespaces)
        let words = cmd.split(separator: " ").map(String.init)
        let resumeFlags = ["--continue", "-c", "--resume", "-r", "--session-id", "--from-pr", "--teleport"]
        guard pane.resumeConversation, words.first == "claude",
              !words.contains(where: { word in resumeFlags.contains { word == $0 || word.hasPrefix($0 + "=") } })
        else { return nil }
        return cmd
    }

    /// What to launch for a local pane's primary tab, and the conversation it will be in.
    /// A plain `claude` with resume on is pointed at the pane's pinned conversation:
    /// `--resume` when its transcript exists, else `--session-id` so a new conversation gets
    /// that id. With no pin yet, the project's newest conversation is adopted (or a fresh id
    /// when there is none). Anything else is left as typed.
    static func launch(for pane: PaneConfig, pinned: String?,
                       root: String = defaultProjectsRoot) -> (command: String, sessionID: String?) {
        guard let cmd = managedClaude(pane) else { return (pane.startupCommand.trimmingCharacters(in: .whitespaces), nil) }
        let dir = pane.dir
        if let id = pinned, isUUID(id) {
            return hasTranscript(id, in: dir, root: root) ? (cmd + " --resume " + id, id) : (cmd + " --session-id " + id, id)
        }
        if let newest = conversations(in: dir, root: root).first(where: { isUUID($0.id) }) {
            return (cmd + " --resume " + newest.id, newest.id)
        }
        let fresh = UUID().uuidString.lowercased()
        return (cmd + " --session-id " + fresh, fresh)
    }

    /// Same as `launch`, for an ssh pane: the transcripts live on the host, so the choice is
    /// made there by a small shell script run in the pane's directory. With no pin, the
    /// conversation isn't known here until the registry sync sees Claude running.
    static func remoteLaunch(for pane: PaneConfig, pinned: String?) -> (command: String, sessionID: String?) {
        guard let cmd = managedClaude(pane) else { return (pane.startupCommand.trimmingCharacters(in: .whitespaces), nil) }
        let folder = #"d="$HOME/.claude/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"; "#
        if let id = pinned, isUUID(id) {
            return (folder + #"if [ -f "$d/\#(id).jsonl" ]; then \#(cmd) --resume \#(id); else \#(cmd) --session-id \#(id); fi"#, id)
        }
        let fresh = UUID().uuidString.lowercased()
        let newest = #"n=$(ls -t "$d" 2>/dev/null | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' | head -n 1); "#
        return (folder + newest + #"if [ -n "$n" ]; then \#(cmd) --resume "${n%.jsonl}"; else \#(cmd) --session-id \#(fresh); fi"#, nil)
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    private static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func field(_ key: String, in line: Substring) -> String? {
        json(line)?[key] as? String
    }
}

/// Which Claude conversation each pane's primary tab is in, so a fresh start (e.g. after a
/// reboot) resumes that conversation instead of whatever is newest in the folder.
/// Kept apart from contexts.json because it changes on its own while Claude runs.
@MainActor
final class ClaudePins {
    static let shared = ClaudePins()

    private var pins: [String: String]
    private let fileURL: URL

    init(fileURL: URL = ClaudePins.defaultURL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        pins = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Helios", isDirectory: true)
            .appendingPathComponent("claude-sessions.json")
    }

    /// The left pane keeps the bare context id, as pins were stored before panes were configurable.
    private static func key(_ context: UUID, _ side: PaneSide) -> String {
        side == .left ? context.uuidString : context.uuidString + ":right"
    }

    subscript(context: UUID, side: PaneSide) -> String? {
        get { pins[Self.key(context, side)] }
        set {
            let key = Self.key(context, side)
            guard pins[key] != newValue else { return }
            pins[key] = newValue
            save()
        }
    }

    func removeAll(for context: UUID) {
        PaneSide.allCases.forEach { self[context, $0] = nil }
    }

    /// Follows the conversation each running local Claude is actually in (it changes with
    /// /resume or /clear inside the tab).
    func sync(_ contexts: [WorkContext]) {
        for context in contexts {
            for side in PaneSide.allCases where context[side].isLocal {
                guard let tab = context[side].tabs.first,
                      let live = ClaudeHistory.liveSessionID(tmuxSession: context.tmuxSession(side, for: tab))
                else { continue }
                self[context.id, side] = live
            }
        }
    }

    /// The same for Claude running in ssh panes: one registry read per host, only over an
    /// existing shared connection (never a new login).
    func syncRemote(_ contexts: [WorkContext]) async {
        var panes: [String: [(UUID, PaneSide, String)]] = [:]
        for context in contexts {
            for side in PaneSide.allCases where context[side].isSSH && !context[side].startupCommand.isEmpty {
                guard let tab = context[side].tabs.first else { continue }
                panes[context[side].trimmedHost, default: []].append((context.id, side, context.tmuxSession(side, for: tab)))
            }
        }
        for (host, list) in panes {
            let result = await Shell.remote(host, ClaudeHistory.remoteRegistryScript, timeout: 15)
            guard result.ok else { continue }
            let entries = ClaudeHistory.registryEntries(fromLines: result.stdout)
            for (id, side, session) in list {
                if let live = ClaudeHistory.liveSessionID(tmuxSession: session, entries: entries) {
                    self[id, side] = live
                }
            }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(pins) { try? data.write(to: fileURL, options: .atomic) }
    }
}
