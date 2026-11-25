import XCTest
@testable import Helios

final class TqdmTests: XCTestCase {
    func testPlainBar() throws {
        // Real line from a fir eval job.
        let p = try XCTUnwrap(JobsMonitor.parseTqdm("100%|██████████| 3088/3088 [00:56<00:00, 55.13it/s]"))
        XCTAssertEqual(p.fraction, 1)
        XCTAssertEqual(p.counts, "3088/3088")
        XCTAssertEqual(p.elapsed, "00:56")
        XCTAssertEqual(p.remaining, "00:00")
        XCTAssertEqual(p.rate, "55.13it/s")
        XCTAssertEqual(p.label, "")
    }

    func testLabelAndPostfix() throws {
        let p = try XCTUnwrap(JobsMonitor.parseTqdm("Epoch 2:  45%|████▌     | 450/1000 [01:23<01:40,  5.50it/s, loss=0.123, lr=1e-4]"))
        XCTAssertEqual(p.fraction, 0.45, accuracy: 1e-9)
        XCTAssertEqual(p.label, "Epoch 2")
        XCTAssertEqual(p.counts, "450/1000")
        XCTAssertEqual(p.remaining, "01:40")
        XCTAssertEqual(p.rate, "5.50it/s")
        XCTAssertEqual(p.postfix, "loss=0.123, lr=1e-4")
    }

    func testGeodesicTrainBar() throws {
        // Real line from a UBC CS loosek job's StdErr.
        let p = try XCTUnwrap(JobsMonitor.parseTqdm("train:   4%|▍         | 409/10000 [01:45<39:13,  4.07it/s, active=0.109, loss=-0.0303, succ=0.0295]"))
        XCTAssertEqual(p.fraction, 0.04, accuracy: 1e-9)
        XCTAssertEqual(p.label, "train")
        XCTAssertEqual(p.counts, "409/10000")
        XCTAssertEqual(p.remaining, "39:13")
    }

    func testStartOfRun() throws {
        let p = try XCTUnwrap(JobsMonitor.parseTqdm("  0%|          | 0/500 [00:00<?, ?it/s]"))
        XCTAssertEqual(p.fraction, 0)
        XCTAssertEqual(p.remaining, "?")
    }

    func testNonTqdm() {
        XCTAssertNil(JobsMonitor.parseTqdm("loading checkpoint shards"))
    }
}

final class ProgressCommandTests: XCTestCase {
    func testCommandPrintsForInspection() {
        let command = JobsMonitor.progressCommand(jobIDs: ["4579278"])
        print("PROGRESS_COMMAND_BEGIN\n\(command)\nPROGRESS_COMMAND_END")
        XCTAssertTrue(command.contains("'4579278'"))
    }
}

final class ClaudeHistoryTests: XCTestCase {
    private var root: String!
    private let dir = "/tmp/helios-test-project"

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "helios-claude-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func writeTranscript(_ id: String, _ lines: [String] = [], modified: Date = Date()) throws {
        let folder = ClaudeHistory.projectFolder(for: dir, root: root)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + id + ".jsonl"
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    func testCommandsWithTheirOwnResumeChoiceAreLeftAlone() {
        var pane = WorkContext(name: "t", localDir: dir).left
        for cmd in ["claude --resume abc", "claude -c", "claude --session-id=x", "htop"] {
            pane.startupCommand = cmd
            XCTAssertEqual(ClaudeHistory.launch(for: pane, pinned: nil, root: root).command, cmd)
            XCTAssertNil(ClaudeHistory.launch(for: pane, pinned: nil, root: root).sessionID)
            XCTAssertEqual(ClaudeHistory.remoteLaunch(for: pane, pinned: nil).command, cmd)
        }
        pane.startupCommand = "claude"
        pane.resumeConversation = false
        XCTAssertEqual(ClaudeHistory.launch(for: pane, pinned: "5b0c3e43-1111-4222-8333-944455556666", root: root).command, "claude")
    }

    func testPinnedConversationIsResumedEvenWhenNotNewest() throws {
        let pinned = "5b0c3e43-1111-4222-8333-944455556666"
        let newer = "9f1d2a7e-aaaa-4bbb-8ccc-dddddddddddd"
        try writeTranscript(pinned, modified: Date(timeIntervalSinceNow: -3600))
        try writeTranscript(newer)
        let ctx = WorkContext(name: "t", localDir: dir).left
        let launch = ClaudeHistory.launch(for: ctx, pinned: pinned, root: root)
        XCTAssertEqual(launch.command, "claude --resume " + pinned)
        XCTAssertEqual(launch.sessionID, pinned)
    }

    func testPinWithoutTranscriptStartsThatID() {
        let pinned = "5b0c3e43-1111-4222-8333-944455556666"
        let launch = ClaudeHistory.launch(for: WorkContext(name: "t", localDir: dir).left, pinned: pinned, root: root)
        XCTAssertEqual(launch.command, "claude --session-id " + pinned)
    }

    func testNoPinAdoptsNewestOrMintsOne() throws {
        let ctx = WorkContext(name: "t", localDir: dir).left
        let fresh = ClaudeHistory.launch(for: ctx, pinned: nil, root: root)
        XCTAssertTrue(fresh.command.hasPrefix("claude --session-id "))
        XCTAssertTrue(ClaudeHistory.isUUID(fresh.sessionID ?? ""))

        let old = "5b0c3e43-1111-4222-8333-944455556666"
        let newest = "9f1d2a7e-aaaa-4bbb-8ccc-dddddddddddd"
        try writeTranscript(old, modified: Date(timeIntervalSinceNow: -3600))
        try writeTranscript(newest)
        XCTAssertEqual(ClaudeHistory.launch(for: ctx, pinned: nil, root: root).command, "claude --resume " + newest)
    }

    func testTitlePrefersRenameThenGeneratedThenFirstPrompt() throws {
        let a = "5b0c3e43-1111-4222-8333-944455556666"
        try writeTranscript(a, [
            #"{"type":"user","message":{"role":"user","content":"fix the branch chip"}}"#,
            #"{"type":"ai-title","aiTitle":"Branch chip fix"}"#,
        ])
        XCTAssertEqual(ClaudeHistory.title(of: a, in: dir, root: root), "Branch chip fix")
        try writeTranscript(a, [
            #"{"type":"ai-title","aiTitle":"Branch chip fix"}"#,
            #"{"type":"custom-title","customTitle":"my name"}"#,
        ])
        XCTAssertEqual(ClaudeHistory.title(of: a, in: dir, root: root), "my name")
        try writeTranscript(a, [#"{"type":"user","message":{"role":"user","content":"hello there"}}"#])
        XCTAssertEqual(ClaudeHistory.title(of: a, in: dir, root: root), "hello there")
    }

    func testLiveSessionMatchesTmuxSessionOfALiveProcess() throws {
        let registry = root + "/sessions"
        try FileManager.default.createDirectory(atPath: registry, withIntermediateDirectories: true)
        let live = "5b0c3e43-1111-4222-8333-944455556666"
        try #"{"pid":\#(getpid()),"sessionId":"\#(live)","tmux":"helios-local-ab12cd34:@0.%0","updatedAt":2}"#
            .write(toFile: registry + "/1.json", atomically: true, encoding: .utf8)
        // A dead process and a different tab's session are ignored.
        try #"{"pid":999999,"sessionId":"9f1d2a7e-aaaa-4bbb-8ccc-dddddddddddd","tmux":"helios-local-ab12cd34:@0.%0","updatedAt":3}"#
            .write(toFile: registry + "/2.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHistory.liveSessionID(tmuxSession: "helios-local-ab12cd34", registryDir: registry), live)
        XCTAssertNil(ClaudeHistory.liveSessionID(tmuxSession: "helios-local-ab12cd34-1a2b", registryDir: registry))
    }
}

final class PaneConfigTests: XCTestCase {
    func testPrimaryLocalTabKeepsLegacySessionName() throws {
        // A context saved before local sub-tabs existed (no "localTabs" key).
        let json = #"{"id":"EA351623-9A5F-422E-A240-545338666EAB","name":"geodesic","localDir":"~/x","startupCommand":"claude"}"#
        let ctx = try JSONDecoder().decode(WorkContext.self, from: Data(json.utf8))
        XCTAssertEqual(ctx.left.tabs.count, 1)
        XCTAssertEqual(ctx.left.tabs[0].name, "claude")
        XCTAssertEqual(ctx.tmuxSession(.left, for: ctx.left.tabs[0]), "helios-local-ea351623")
        XCTAssertEqual(ctx.right.kind, .ssh)
        XCTAssertFalse(ctx.right.hasTerminal)
    }

    func testFixedLayoutContextMigratesToPanes() throws {
        let json = #"""
        {"id":"EA351623-9A5F-422E-A240-545338666EAB","name":"g","localDir":"~/x","startupCommand":"claude",
         "resumeConversation":false,"host":"fir","remoteDir":"~/scratch/g",
         "localTabs":[{"id":"11111111-1111-4111-8111-111111111111","name":"claude"}],
         "remoteTabs":[{"id":"22222222-2222-4222-8222-222222222222","name":"main"}]}
        """#
        let ctx = try JSONDecoder().decode(WorkContext.self, from: Data(json.utf8))
        XCTAssertEqual(ctx.left, PaneConfig(kind: .local, dir: "~/x", startupCommand: "claude", resumeConversation: false,
                                            tabs: [PaneTab(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "claude")]))
        XCTAssertEqual(ctx.right.kind, .ssh)
        XCTAssertEqual(ctx.right.host, "fir")
        XCTAssertEqual(ctx.right.dir, "~/scratch/g")
        XCTAssertEqual(ctx.right.startupCommand, "")
        XCTAssertEqual(ctx.tmuxSession(.right, for: ctx.right.tabs[0]), "helios-ea351623")
        XCTAssertEqual(ctx.host, "fir")
        XCTAssertEqual(ctx.localDir, "~/x")

        // Saved again in the new format, it reads back the same.
        let again = try JSONDecoder().decode(WorkContext.self, from: JSONEncoder().encode(ctx))
        XCTAssertEqual(again, ctx)
    }

    func testEitherPaneCanBeAnywhere() {
        var ctx = WorkContext(name: "t", localDir: "~")
        ctx.left = PaneConfig(kind: .ssh, host: "mini", dir: "~/proj", startupCommand: "claude")
        ctx.right = PaneConfig(kind: .ssh, host: "fir")
        XCTAssertEqual(ctx.sshSides, [.right, .left])
        XCTAssertEqual(ctx.host, "fir")
        XCTAssertNil(ctx.localDir)
        XCTAssertEqual(ctx.summary, "mini · fir")
        ctx.right = PaneConfig(kind: .none)
        XCTAssertEqual(ctx.host, "mini")
        XCTAssertEqual(ctx.remoteDir, "~/proj")
        XCTAssertEqual(ctx.side(of: ctx.left.tabs[0].id), .left)
    }

    func testTabsGetDistinctSessionsAcrossPanes() {
        var ctx = WorkContext(name: "t", localDir: "~")
        ctx.left.tabs.append(PaneTab(name: "shell 2"))
        ctx.right.tabs.append(PaneTab(name: "shell 2"))
        let names = Set(PaneSide.allCases.flatMap { side in ctx[side].tabs.map { ctx.tmuxSession(side, for: $0) } })
        XCTAssertEqual(names.count, 4)
    }
}

final class RemoteClaudeLaunchTests: XCTestCase {
    private var home: String!
    private var project: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "helios-home-" + UUID().uuidString
        project = home + "/proj"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    /// Runs the generated remote script in /bin/sh with `claude` stubbed to echo its arguments.
    private func run(_ script: String) async -> String {
        let result = await Shell.run("/bin/sh", ["-c", #"claude() { echo "$@"; }; "# + script, ], cwd: project)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFolder() throws -> String {
        // Foundation's symlink resolution drops /private on macOS; the shell's `pwd -P` doesn't.
        let physical = String(cString: realpath(project, nil))
        let folder = home + "/.claude/projects/" + String(physical.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    private func script(pinned: String?) -> String {
        let pane = PaneConfig(kind: .ssh, host: "h", dir: project, startupCommand: "claude")
        // HOME is the remote one; point it at the fixture.
        return "HOME=" + shellQuote(home) + "; " + ClaudeHistory.remoteLaunch(for: pane, pinned: pinned).command
    }

    func testPinnedResumesWhenTranscriptExistsOnHost() async throws {
        let id = "5b0c3e43-1111-4222-8333-944455556666"
        let out1 = await run(script(pinned: id))
        XCTAssertEqual(out1, "--session-id " + id)
        FileManager.default.createFile(atPath: try transcriptFolder() + "/" + id + ".jsonl", contents: Data())
        let out2 = await run(script(pinned: id))
        XCTAssertEqual(out2, "--resume " + id)
    }

    func testNoPinAdoptsNewestOnHost() async throws {
        let fresh = await run(script(pinned: nil))
        XCTAssertTrue(fresh.hasPrefix("--session-id "))
        let folder = try transcriptFolder()
        let old = "5b0c3e43-1111-4222-8333-944455556666", newest = "9f1d2a7e-aaaa-4bbb-8ccc-dddddddddddd"
        FileManager.default.createFile(atPath: folder + "/" + old + ".jsonl", contents: Data())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: folder + "/" + old + ".jsonl")
        FileManager.default.createFile(atPath: folder + "/" + newest + ".jsonl", contents: Data())
        FileManager.default.createFile(atPath: folder + "/notes.jsonl", contents: Data())
        let out = await run(script(pinned: nil))
        XCTAssertEqual(out, "--resume " + newest)
    }

    func testRegistryLinesMatchTmuxSession() {
        let output = """
        {"pid":1,"sessionId":"5b0c3e43-1111-4222-8333-944455556666","tmux":"helios-local-ea351623:@0.%0","updatedAt":5}
        {"pid":2,"sessionId":"9f1d2a7e-aaaa-4bbb-8ccc-dddddddddddd","tmux":"helios-ea351623:@0.%0","updatedAt":9}
        """
        let entries = ClaudeHistory.registryEntries(fromLines: output)
        XCTAssertEqual(ClaudeHistory.liveSessionID(tmuxSession: "helios-ea351623", entries: entries),
                       "9f1d2a7e-aaaa-4bbb-8ccc-dddddddddddd")
        XCTAssertNil(ClaudeHistory.liveSessionID(tmuxSession: "helios-other", entries: entries))
    }
}
