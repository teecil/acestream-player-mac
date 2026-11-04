import Foundation

/// A playback session returned by `/ace/getstream?format=json`.
public struct EngineSession: Equatable, Sendable {
    public let playbackURL: URL
    public let statURL: URL
    public let commandURL: URL
    public let isLive: Bool

    public init(playbackURL: URL, statURL: URL, commandURL: URL, isLive: Bool) {
        self.playbackURL = playbackURL
        self.statURL = statURL
        self.commandURL = commandURL
        self.isLive = isLive
    }
}

/// Session statistics from `stat_url`.
public struct EngineStats: Equatable, Sendable {
    /// e.g. "prebuf", "dl", "check", "buf"
    public let status: String
    public let peers: Int
    /// Download speed in KB/s as reported by the engine.
    public let speedDown: Int
    /// Downloaded bytes.
    public let downloaded: Int64

    public init(status: String, peers: Int, speedDown: Int, downloaded: Int64) {
        self.status = status
        self.peers = peers
        self.speedDown = speedDown
        self.downloaded = downloaded
    }
}

public enum EngineAPIError: Error, Equatable {
    /// The engine answered with an `error` message.
    case engine(String)
    /// The answer was not the JSON we expected.
    case malformed
}

/// Parsers for the Ace Stream engine HTTP API (https://docs.acestream.net/developers/).
public enum EngineJSON {
    public static func parseVersion(_ data: Data) throws -> String {
        let o = try object(data)
        if let e = errorText(o) { throw EngineAPIError.engine(e) }
        for key in ["result", "response"] {
            if let r = o[key] as? [String: Any], let v = r["version"] as? String { return v }
        }
        throw EngineAPIError.malformed
    }

    /// Parses a session and rewrites every URL to `base` (the host port we published),
    /// because the engine inside the container reports its own internal address.
    public static func parseSession(_ data: Data, rebasingTo base: URL) throws -> EngineSession {
        let o = try object(data)
        if let e = errorText(o) { throw EngineAPIError.engine(e) }
        guard let r = o["response"] as? [String: Any],
              let playback = url(r["playback_url"]),
              let stat = url(r["stat_url"]),
              let command = url(r["command_url"]) else {
            throw EngineAPIError.malformed
        }
        let live = (r["is_live"] as? NSNumber)?.boolValue ?? true
        return EngineSession(
            playbackURL: rebase(playback, to: base),
            statURL: rebase(stat, to: base),
            commandURL: rebase(command, to: base),
            isLive: live
        )
    }

    public static func parseStats(_ data: Data) throws -> EngineStats {
        let o = try object(data)
        if let e = errorText(o) { throw EngineAPIError.engine(e) }
        guard let r = o["response"] as? [String: Any] else { throw EngineAPIError.malformed }
        func number(_ key: String) -> Int64 {
            if let n = r[key] as? NSNumber { return n.int64Value }
            if let s = r[key] as? String, let n = Int64(s) { return n }
            return 0
        }
        return EngineStats(
            status: (r["status"] as? String) ?? "",
            peers: Int(number("peers")),
            speedDown: Int(number("speed_down")),
            downloaded: number("downloaded")
        )
    }

    public static func rebase(_ url: URL, to base: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = b.scheme
        c.host = b.host
        c.port = b.port
        return c.url ?? url
    }

    // MARK: - Helpers

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let o = parsed as? [String: Any] else { throw EngineAPIError.malformed }
        return o
    }

    private static func errorText(_ o: [String: Any]) -> String? {
        if let s = o["error"] as? String, !s.isEmpty { return s }
        return nil
    }

    private static func url(_ value: Any?) -> URL? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}
