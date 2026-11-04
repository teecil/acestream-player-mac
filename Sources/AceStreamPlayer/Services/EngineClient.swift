import AceCore
import Foundation

/// HTTP client for the Ace Stream engine running in our container.
/// API: https://docs.acestream.net/developers/
@MainActor
struct EngineClient {
    let port: Int

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:] // never send localhost traffic through a system proxy
        return URLSession(configuration: config)
    }()

    private func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineAPIError.malformed }
        return (data, http)
    }

    /// True once the engine's HTTP server answers anything at all.
    /// (Docker's port proxy accepts TCP before the engine listens, so only a real HTTP reply counts.)
    func isResponding() async -> Bool {
        guard let url = URL(string: "\(base.absoluteString)/webui/api/service?method=get_version") else { return false }
        do {
            let (data, _) = try await get(url, timeout: 4)
            if let version = try? EngineJSON.parseVersion(data) { Log.info("Engine version \(version)") }
            return true
        } catch {
            return false
        }
    }

    func waitUntilReady(timeout: TimeInterval, containerAlive: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            try Task.checkCancellation()
            if await isResponding() { return }
            attempt += 1
            if attempt % 5 == 0, !(await containerAlive()) { throw AppError.engineCrashed }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw AppError.engineNotResponding
    }

    /// Asks the engine to open the content; returns the playback session.
    func start(_ source: StreamSource) async throws -> EngineSession {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/ace/getstream"
        components.percentEncodedQuery = QueryEncoding.encode([("format", "json")] + source.queryPairs)
        guard let url = components.url else { throw EngineAPIError.malformed }
        let (data, http) = try await get(url, timeout: 60)
        guard (200..<300).contains(http.statusCode) else {
            throw EngineAPIError.engine("HTTP \(http.statusCode)")
        }
        return try EngineJSON.parseSession(data, rebasingTo: base)
    }

    func stats(_ session: EngineSession) async throws -> EngineStats {
        let (data, _) = try await get(session.statURL, timeout: 5)
        return try EngineJSON.parseStats(data)
    }

    func stop(_ session: EngineSession) async {
        guard var components = URLComponents(url: session.commandURL, resolvingAgainstBaseURL: false) else { return }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "method", value: "stop"))
        components.queryItems = items
        if let url = components.url { _ = try? await get(url, timeout: 3) }
    }
}
