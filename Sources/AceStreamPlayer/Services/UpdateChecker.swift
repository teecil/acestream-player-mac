import AceCore
import Foundation

struct UpdateRelease: Equatable {
    let version: String
    let pageURL: URL
}

/// Asks GitHub for the latest release. Only reads; never downloads or installs anything.
enum UpdateChecker {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/teecil/acestream-player-mac/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/teecil/acestream-player-mac/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The latest release if it is newer than this app, nil if we're up to date.
    static func newerRelease() async throws -> UpdateRelease? {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AceStreamPlayer-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw URLError(.badServerResponse)
        }
        let version = Version.clean(tag)
        guard Version.isNewer(version, than: currentVersion) else { return nil }
        var page = releasesPage
        if let link = object["html_url"] as? String, let url = URL(string: link), url.host == "github.com" {
            page = url
        }
        return UpdateRelease(version: version, pageURL: page)
    }
}
