import Foundation

/// Runs a command-line tool off the main thread and collects its output.
///
/// stdout and stderr are drained concurrently (reading one to EOF before the
/// other deadlocks once the other fills its ~64 KB pipe buffer), the process
/// is killed after `timeout`, and cancelling the calling task terminates it.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var timedOut = false
        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// `environment` is layered over the app's environment with a Homebrew-aware PATH.
    static func run(_ executable: String, _ args: [String], environment: [String: String] = [:],
                    directory: String? = nil, timeout: TimeInterval = 120) async -> Result {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in environment { env[k] = v }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = env
        if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                let state = RunState()
                let group = DispatchGroup()
                let handles = [out.fileHandleForReading, err.fileHandleForReading]
                for (i, handle) in handles.enumerated() {
                    group.enter()
                    handle.readabilityHandler = { h in
                        let data = h.availableData
                        if data.isEmpty {
                            h.readabilityHandler = nil
                            if state.closePipe(i) { group.leave() }
                        } else {
                            state.append(data, stdout: i == 0)
                        }
                    }
                }
                group.enter()
                p.terminationHandler = { _ in
                    // A background job the child started (say, from .zshrc) can
                    // inherit the pipes and hold them open forever; stop waiting
                    // for EOF shortly after the child itself exits.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + pipeGrace) {
                        for (i, handle) in handles.enumerated() where state.closePipe(i) {
                            handle.readabilityHandler = nil
                            group.leave()
                        }
                    }
                    group.leave()
                }
                do {
                    try p.run()
                } catch {
                    handles.forEach { $0.readabilityHandler = nil }
                    cont.resume(returning: Result(status: -1, stdout: Data(), stderr: error.localizedDescription))
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning {
                        state.markTimedOut()
                        stop(p)
                    }
                }
                group.notify(queue: .global(qos: .userInitiated)) {
                    let (stdout, stderr, timedOut) = state.snapshot()
                    cont.resume(returning: Result(status: p.terminationStatus, stdout: stdout,
                                                  stderr: String(decoding: stderr, as: UTF8.self), timedOut: timedOut))
                }
            }
        } onCancel: {
            stop(p)
        }
    }

    /// How long to keep reading output after the child exits.
    private static let pipeGrace: TimeInterval = 1.5

    /// SIGTERM, then SIGKILL if the process ignores it.
    private static func stop(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + AppEnvironment.wait(3)) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Output buffers shared by the pipe handlers (which run on GCD threads).
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var timedOut = false
        private var open = [true, true]

        func append(_ data: Data, stdout isOut: Bool) {
            lock.withLock { if isOut { stdout.append(data) } else { stderr.append(data) } }
        }
        /// True the first time a pipe is closed, so the group is left once per pipe.
        func closePipe(_ i: Int) -> Bool {
            lock.withLock { defer { open[i] = false }; return open[i] }
        }
        func markTimedOut() { lock.withLock { timedOut = true } }
        func snapshot() -> (Data, Data, Bool) { lock.withLock { (stdout, stderr, timedOut) } }
    }
}
