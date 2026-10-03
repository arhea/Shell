import Foundation

/// A published GitHub release, reduced to what the updater needs: the version
/// from its `v<version>` tag, the notarized DMG and the DMG's SHA-256 file.
struct UpdateRelease: Codable, Equatable, Sendable {
    var version: String
    var notesURL: URL
    var dmgName: String
    var dmgURL: URL
    var dmgSize: Int
    var checksumURL: URL

    // GitHub's field names.
    // swiftlint:disable identifier_name
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int
        }
        var tag_name: String
        var html_url: URL
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]
    }
    // swiftlint:enable identifier_name

    /// Parses a `GET /repos/{owner}/{repo}/releases/latest` response. Nil for a
    /// draft or pre-release, or when the release is missing the DMG or its
    /// `<dmg>.sha256` (say, while assets are still uploading).
    static func parse(_ data: Data) throws -> UpdateRelease? {
        let r = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !r.draft, !r.prerelease, !AppVersion.components(r.tag_name).isEmpty,
              let dmg = r.assets.first(where: { $0.name.hasPrefix("Shell") && $0.name.hasSuffix(".dmg") }),
              let sum = r.assets.first(where: { $0.name == dmg.name + ".sha256" })
        else { return nil }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return UpdateRelease(version: version, notesURL: r.html_url, dmgName: dmg.name,
                             dmgURL: dmg.browser_download_url, dmgSize: dmg.size, checksumURL: sum.browser_download_url)
    }
}

/// Dotted numeric versions (`0.2.0`, `v1.10`). A pre-release or build suffix
/// (`-beta.1`, `+5`) is ignored: the updater only follows full releases.
enum AppVersion {
    static func components(_ version: String) -> [Int] {
        var v = Substring(version)
        if v.hasPrefix("v") { v = v.dropFirst() }
        let core = v.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return [] }
        return parts.compactMap { $0 }
    }

    /// True when `candidate` is a strictly later version than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum UpdateChecksum {
    /// The digest from a `shasum -a 256` line (`<hex>  <file>`), lowercased.
    static func parse(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first, token.count == 64,
              token.allSatisfy(\.isHexDigit) else { return nil }
        return token.lowercased()
    }
}
