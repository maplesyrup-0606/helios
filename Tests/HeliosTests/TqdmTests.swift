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
    func testAddsContinueOnlyForPlainClaudeWithHistory() {
        var ctx = WorkContext(name: "t", localDir: "/nonexistent/helios-test-dir")
        // No history for a nonexistent dir: unchanged.
        XCTAssertEqual(ClaudeHistory.startupCommand(for: ctx), "claude")
        ctx.startupCommand = "claude --resume abc"
        XCTAssertEqual(ClaudeHistory.startupCommand(for: ctx), "claude --resume abc")
        ctx.startupCommand = "htop"
        XCTAssertEqual(ClaudeHistory.startupCommand(for: ctx), "htop")
    }

    func testRealProjectWithHistoryGetsContinue() throws {
        let dir = "~/Documents/Projects/ELVIS"
        try XCTSkipUnless(ClaudeHistory.hasConversations(in: dir), "no local Claude history for ELVIS")
        var ctx = WorkContext(name: "elvis", localDir: dir)
        XCTAssertEqual(ClaudeHistory.startupCommand(for: ctx), "claude --continue")
        ctx.resumeConversation = false
        XCTAssertEqual(ClaudeHistory.startupCommand(for: ctx), "claude")
    }
}
