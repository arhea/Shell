import Foundation

/// Splits a stream-json pipe into JSON objects off the main thread and hands
/// them to the main actor in batches, at most ~30 times a second.
///
/// Claude Code writes one line per token while streaming; parsing each on the
/// main thread, and re-rendering after each, was the native view's biggest cost.
final class StreamJSONDecoder: @unchecked Sendable {
    /// A batch of decoded lines. Plain JSON values, only read on the main actor.
    struct Batch: @unchecked Sendable { var objects: [[String: Any]] }

    private let deliver: @MainActor (Batch) -> Void
    private let interval: TimeInterval
    private var buffer = Data()          // only touched from the pipe's handler queue
    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private var scheduled = false

    init(interval: TimeInterval = 1.0 / 30, deliver: @escaping @MainActor (Batch) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    /// Called from a pipe's readability handler (one serial queue per handle).
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let newBytes = data.count
        buffer.append(data)
        var objects: [[String: Any]] = []
        var lineStart = buffer.startIndex
        // Only the new bytes can hold a newline: earlier ones were scanned already.
        var scan = buffer.index(buffer.endIndex, offsetBy: -newBytes)
        while let nl = buffer[scan...].firstIndex(of: 0x0A) {
            let line = buffer[lineStart..<nl]
            if !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                objects.append(obj)
            }
            lineStart = buffer.index(after: nl)
            scan = lineStart
        }
        if lineStart > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<lineStart) }
        guard !objects.isEmpty else { return }
        let schedule: Bool = lock.withLock {
            pending += objects
            defer { scheduled = true }
            return !scheduled
        }
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
                let batch: [[String: Any]] = lock.withLock {
                    scheduled = false
                    defer { pending = [] }
                    return pending
                }
                MainActor.assumeIsolated { deliver(Batch(objects: batch)) }
            }
        }
    }
}
