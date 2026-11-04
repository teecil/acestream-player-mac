import Foundation

/// What the user wants to watch, in a form the Ace Stream engine understands.
public enum StreamSource: Equatable, Sendable {
    /// Ace Stream content ID (what `acestream://<id>` links carry).
    case contentID(String)
    /// BitTorrent infohash.
    case infohash(String)
    /// Full magnet link (used when it has no plain hex infohash).
    case magnet(String)
    /// HTTP(S) link to a .torrent / .acelive file.
    case torrentURL(URL)

    /// Query parameters for `/ace/getstream` (docs.acestream.net → Start playback).
    public var queryPairs: [(String, String)] {
        switch self {
        case .contentID(let id): return [("id", id)]
        case .infohash(let hash): return [("infohash", hash)]
        case .magnet(let magnet): return [("magnet", magnet)]
        case .torrentURL(let url): return [("url", url.absoluteString)]
        }
    }

    /// Short, non-sensitive description for logs.
    public var logDescription: String {
        switch self {
        case .contentID(let id): return "content_id \(id.prefix(8))…"
        case .infohash(let hash): return "infohash \(hash.prefix(8))…"
        case .magnet: return "magnet link"
        case .torrentURL(let url): return "url \(url.host ?? "?")/…\(url.pathExtension)"
        }
    }
}

/// Strict percent-encoding for query values (URLComponents leaves `&`, `=`, `+` alone).
public enum QueryEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { name, value in
            let n = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(n)=\(v)"
        }
        .joined(separator: "&")
    }
}
