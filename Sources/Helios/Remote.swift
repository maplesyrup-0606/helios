import Foundation

enum SSHOptions {
    /// Shared by every ssh/rsync call so they reuse one authenticated connection (one 2FA prompt).
    static let connectionSharing = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/helios-cm-%C",
        "-o", "ControlPersist=4h",
    ]

    /// For background commands: never prompt, so polling can't trigger 2FA pushes.
    /// These only succeed once a terminal has authenticated (or with key-only hosts).
    static let background = connectionSharing + [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
    ]

    /// The `-e` value for rsync so transfers ride the same shared connection.
    static var rsyncShell: String {
        (["ssh"] + background).joined(separator: " ")
    }
}

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// Runs a process off the main thread and collects its output; kills it after `timeout`.
    static func run(_ executable: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: expandTilde(cwd)) }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            // Drain pipes concurrently so large output can't block the child.
            let group = DispatchGroup()
            let buffers = OutputBuffers()
            group.enter()
            DispatchQueue.global().async { buffers.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { buffers.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

            process.terminationHandler = { p in
                group.notify(queue: .global()) {
                    continuation.resume(returning: CommandResult(
                        status: p.terminationStatus,
                        stdout: String(decoding: buffers.out, as: UTF8.self),
                        stderr: String(decoding: buffers.err, as: UTF8.self)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// True when an authenticated master connection to `host` exists. Purely local check.
    static func hasSharedConnection(_ host: String) async -> Bool {
        await run("/usr/bin/ssh", SSHOptions.connectionSharing + ["-O", "check", host], timeout: 5).ok
    }

    /// Runs a shell command on `host` over the shared connection. Never opens a new login,
    /// so background polling can't trigger 2FA pushes or failed-login lockouts.
    static func remote(_ host: String, _ command: String, timeout: TimeInterval = 30) async -> CommandResult {
        guard await hasSharedConnection(host) else {
            return CommandResult(status: 255, stdout: "", stderr: "No shared SSH connection yet")
        }
        return await run("/usr/bin/ssh", SSHOptions.background + [host, command], timeout: timeout)
    }
}

/// Each field is written by exactly one reader thread and read only after both finish.
private final class OutputBuffers: @unchecked Sendable {
    var out = Data()
    var err = Data()
}
