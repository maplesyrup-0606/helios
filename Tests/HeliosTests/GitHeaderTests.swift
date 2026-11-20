import XCTest
@testable import Helios

final class GitHeaderTests: XCTestCase {
    func testTrackingBranch() {
        let h = GitMonitor.parseHeader("main...origin/main [behind 11]")
        XCTAssertEqual(h.branch, "main")
        XCTAssertEqual(h.tracking, "behind 11")
    }

    func testBranchWithSlashesInSync() {
        let h = GitMonitor.parseHeader("sim-physics-review/mercury...origin/sim-physics-review/mercury")
        XCTAssertEqual(h.branch, "sim-physics-review/mercury")
        XCTAssertEqual(h.tracking, "")
    }

    func testNoUpstream() {
        let h = GitMonitor.parseHeader("feature")
        XCTAssertEqual(h.branch, "feature")
        XCTAssertEqual(h.tracking, "")
    }

    func testNoCommitsYet() {
        XCTAssertEqual(GitMonitor.parseHeader("No commits yet on dev").branch, "dev")
        XCTAssertEqual(GitMonitor.parseHeader("Initial commit on dev").branch, "dev")
    }

    func testDetachedHead() {
        XCTAssertEqual(GitMonitor.parseHeader("HEAD (no branch)").branch, "detached HEAD")
    }

    func testRemoteStatus() throws {
        let out = "## sim-physics-review-mercury...origin/sim-physics-review-mercury [ahead 2]\n M a.py\n?? b.py\n"
        let r = try XCTUnwrap(GitMonitor.parseRemote(CommandResult(status: 0, stdout: out, stderr: "")))
        XCTAssertEqual(r.branch, "sim-physics-review-mercury")
        XCTAssertEqual(r.tracking, "ahead 2")
        XCTAssertEqual(r.changeCount, 2)
    }

    func testRemoteNotARepo() {
        XCTAssertNil(GitMonitor.parseRemote(CommandResult(status: 128, stdout: "", stderr: "fatal: not a git repository")))
    }
}
