import Darwin
import Foundation

/// Stops every process Shell started when it quits, so nothing is left
/// orphaned: `claude` stream-json sessions and their MCP servers, `git`/`gh`
/// lookups, MCP inspectors, and background maintenance jobs.
///
/// Terminal shells aren't handled here: closing a surface makes libghostty
/// send SIGHUP to the shell's process group and wait for it, as any terminal
/// does. Programs deliberately detached from a shell (`nohup`, `disown`, tmux)
/// are no longer Shell's descendants by then, so they keep running.
enum ProcessCleanup {
    /// SIGTERMs all descendants of this process, waits up to `grace` for them
    /// to exit, then SIGKILLs any that remain. Blocks the caller for at most `grace`.
    static func terminateDescendants(grace: TimeInterval = 2) {
        let pids = descendants(of: getpid())
        guard !pids.isEmpty else { return }
        log.info("quit: stopping \(pids.count, privacy: .public) child process(es)")
        terminate(pids, grace: grace, rescan: true)
    }

    /// SIGTERM, wait up to `grace`, then SIGKILL survivors. With `rescan`,
    /// descendants spawned in the meantime are killed too.
    static func terminate(_ pids: [pid_t], grace: TimeInterval, rescan: Bool = false) {
        for pid in pids { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(grace)
        var remaining = pids.filter(isAlive)
        while !remaining.isEmpty, Date() < deadline {
            usleep(20_000)
            remaining = remaining.filter(isAlive)
        }
        // Children of the processes we just stopped may have been spawned late.
        let late = rescan ? descendants(of: getpid()).filter(isAlive) : []
        let stragglers = Set(remaining + late)
        for pid in stragglers {
            log.info("quit: force-killing pid \(pid, privacy: .public)")
            kill(pid, SIGKILL)
        }
    }

    /// Every descendant of `pid` (children, grandchildren, …).
    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        var seen: Set<pid_t> = [pid]
        while let parent = queue.popLast() {
            for child in children(of: parent) where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    static func children(of pid: pid_t) -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes that start between the two calls.
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Running (not a zombie waiting to be reaped).
    static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }
}
