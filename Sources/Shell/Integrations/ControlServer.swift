import Darwin
import Foundation

/// A Unix-domain socket the shell integration, `shellctl`, and agent hooks
/// use to report events back to the app. Each connection carries one
/// message batch; the peer writes and closes.
///
/// Wire format: newline-separated records, tab-separated fields, with `\\`,
/// `\n` and `\t` escaped inside fields. The first field is the message type
/// and the second is the session ID.
///
/// Unchecked Sendable: all mutable state (`path`, the listening socket, the
/// accept source, `onMessage`) is only touched on `queue`.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()

    private let queue = DispatchQueue(label: "app.bethesdalabs.Shell.control")
    private var path: String = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var handler: (@Sendable ([[String]]) -> Void)?

    /// Called on the server's queue with each message batch.
    var onMessage: (@Sendable ([[String]]) -> Void)? {
        get { queue.sync { handler } }
        set { queue.sync { handler = newValue } }
    }

    func start(path: String) throws {
        try queue.sync { try startOnQueue(path: path) }
        Log.control.info("listening on \(path, privacy: .public)")
    }

    private func startOnQueue(path: String) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        self.path = path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        // Close only once the source has stopped using the descriptor.
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            if !path.isEmpty { unlink(path) }
        }
    }

    private func acceptClients(_ listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            // Only accept peers running as the same user.
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                close(client)
                continue
            }
            read(client: client)
        }
    }

    private func read(client: Int32) {
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
        let message = MessageBuffer()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(client, &chunk, chunk.count)
                if n > 0 {
                    message.data.append(chunk, count: n)
                    if message.data.count > 16 * 1024 * 1024 { source.cancel(); return }
                    continue
                }
                if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    source.cancel()
                    self?.dispatch(message.data)
                }
                return
            }
        }
        source.setCancelHandler { close(client) }
        source.resume()
    }

    private func dispatch(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let records = text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { Self.unescape(String($0)) }
        }
        guard !records.isEmpty else { return }
        handler?(records)
    }

    /// One connection's bytes, only touched on the server's queue.
    private final class MessageBuffer: @unchecked Sendable {
        var data = Data()
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: out.append(n)
            }
        }
        return out
    }
}
