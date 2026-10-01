import CryptoKit
import Darwin
import Foundation
import Security

/// The updater's off-main work: asking GitHub for the latest release,
/// downloading and verifying its DMG, and handing the verified app to a
/// helper that replaces this bundle once Shell has quit.
enum UpdateInstaller {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// `owner/repo` whose releases Shell follows. `SHELL_APP_UPDATE_REPOSITORY`
    /// points a build at a fork for testing.
    static let repository = ProcessInfo.processInfo.environment["SHELL_APP_UPDATE_REPOSITORY"] ?? "arhea/Shell"

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    /// The Developer ID team that signed this copy. Nil for ad-hoc signed
    /// development builds, which never replace themselves.
    static let teamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Staged downloads. Cleared at launch, so a half-finished download never lingers.
    static let stagingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.bethesdalabs.Shell/Updates", isDirectory: true)

    /// No cookies or cache; the only header beyond the defaults is the User-Agent GitHub requires.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30 * 60
        config.httpAdditionalHeaders = ["User-Agent": "Shell/\(currentVersion)"]
        return URLSession(configuration: config)
    }()

    // MARK: Checking

    enum LatestResult: Sendable {
        /// The latest release, or nil when there's none with a DMG yet.
        case release(UpdateRelease?, etag: String?)
        /// Nothing changed since the ETag; conditional requests don't count against GitHub's rate limit.
        case notModified
    }

    static func fetchLatest(etag: String?) async throws -> LatestResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return .release(try UpdateRelease.parse(data), etag: http?.value(forHTTPHeaderField: "ETag"))
        case 304:
            return .notModified
        case 404:
            return .release(nil, etag: nil) // no published release yet
        case 403, 429:
            throw Failure("GitHub's rate limit was reached. Shell will try again later.")
        case let code:
            throw Failure("GitHub returned HTTP \(code).")
        }
    }

    // MARK: Staging

    /// Captures the DMG's download task so the updater can show progress.
    /// Lock-protected: URLSession sets the task on its delegate queue, the main actor reads it.
    final class DownloadMonitor: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.withLock { self.task = task }
        }

        var bytesReceived: Int64 { lock.withLock { task?.countOfBytesReceived ?? 0 } }
    }

    /// Downloads the release's DMG, checks it against the published SHA-256,
    /// copies the app out and verifies it. Returns the staged `Shell.app`.
    static func stage(_ release: UpdateRelease, teamID: String, bundleID: String,
                      monitor: DownloadMonitor? = nil) async throws -> URL {
        let fm = FileManager.default
        let dir = stagingRoot.appendingPathComponent(release.version, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let (sumData, sumResponse) = try await session.data(from: release.checksumURL)
        guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = UpdateChecksum.parse(String(decoding: sumData, as: UTF8.self)) else {
            throw Failure("The release's checksum file is missing or malformed.")
        }

        let (downloaded, response) = try await session.download(from: release.dmgURL, delegate: monitor)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fm.removeItem(at: downloaded)
            throw Failure("Downloading \(release.dmgName) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let dmg = dir.appendingPathComponent(release.dmgName)
        try fm.moveItem(at: downloaded, to: dmg)
        guard try sha256(of: dmg) == expected else {
            throw Failure("\(release.dmgName) doesn't match its published checksum.")
        }

        let mount = dir.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = await ProcessRunner.run("/usr/bin/hdiutil",
                                             ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path, dmg.path])
        guard attach.succeeded else { throw Failure("Couldn't open \(release.dmgName): \(attach.stderr)") }
        let app = dir.appendingPathComponent("Shell.app", isDirectory: true)
        let copied: ProcessRunner.Result
        if let source = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) {
            copied = await ProcessRunner.run("/usr/bin/ditto", [mount.appendingPathComponent(source).path, app.path], timeout: 300)
        } else {
            copied = ProcessRunner.Result(status: 1, stdout: Data(), stderr: "no app in the disk image")
        }
        let detach = await ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        if !detach.succeeded { Log.update.error("hdiutil detach failed: \(detach.stderr, privacy: .public)") }
        try? fm.removeItem(at: dmg)
        guard copied.succeeded else { throw Failure("Couldn't copy Shell from the disk image: \(copied.stderr)") }

        try await verify(app: app, version: release.version, teamID: teamID, bundleID: bundleID)
        return app
    }

    /// The staged app must be this app (bundle ID), the advertised version,
    /// signed by the same Developer ID team, and accepted by Gatekeeper
    /// (notarized). Anything else is discarded.
    static func verify(app: URL, version: String, teamID: String, bundleID: String) async throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure("The downloaded app isn't Shell.")
        }
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw Failure("The downloaded app's version doesn't match release \(version).")
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("Couldn't read the downloaded app's signature.")
        }
        var requirement: SecRequirement?
        let text = "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("Couldn't build the signature requirement.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("The downloaded app isn't signed by Shell's developer (\(status)).")
        }

        let gatekeeper = await ProcessRunner.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.succeeded else {
            throw Failure("Gatekeeper rejected the downloaded app: \(gatekeeper.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Installing

    /// Waits for Shell (`$1`) to exit, copies the staged app (`$2`) next to the
    /// installed one (`$3`), swaps them with two renames (putting the old one
    /// back if the second fails) and relaunches when `$4` is 1. Output goes to `$5`.
    private static let installScript = #"""
    exec >>"$5" 2>&1
    echo "$(date): updating $3"
    i=0
    while kill -0 "$1" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 300 ]; then echo "Shell didn't quit within a minute; not updating"; exit 1; fi
        sleep 0.2
    done
    dir=$(dirname "$3")
    new="$dir/.Shell-update-$$.app"
    old="$dir/.Shell-previous-$$.app"
    ok=0
    if /usr/bin/ditto "$2" "$new" && /bin/mv "$3" "$old"; then
        if /bin/mv "$new" "$3"; then ok=1; else /bin/mv "$old" "$3"; fi
    fi
    /bin/rm -rf "$new" "$old"
    if [ "$ok" = 1 ]; then
        echo "updated"
        /bin/rm -rf "$(dirname "$2")"
    else
        echo "update failed; kept the current version"
    fi
    if [ "$4" = 1 ]; then /usr/bin/open "$3"; fi
    """#

    /// Starts the install helper in its own session so it outlives Shell and
    /// isn't among the descendants stopped at quit. Call it last while quitting.
    @discardableResult
    static func spawnInstaller(staged: URL, target: URL, relaunch: Bool, log: URL) -> Bool {
        let args = ["/bin/sh", "-c", installScript, "shell-update",
                    String(getpid()), staged.path, target.path, relaunch ? "1" : "0", log.path]
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, environ)
        if rc != 0 {
            Log.update.error("couldn't start the update helper: \(String(cString: strerror(rc)), privacy: .public)")
            return false
        }
        Log.update.info("update helper \(pid, privacy: .public) will install into \(target.path, privacy: .public)")
        return true
    }
}
