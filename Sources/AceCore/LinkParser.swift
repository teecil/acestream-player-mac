import Foundation

/// Turns whatever the user pasted into a `StreamSource`.
///
/// Accepted:
/// - `acestream://<40 hex>` (also when surrounded by other text, e.g. a pasted message)
/// - a bare 40-character hex content ID
/// - `magnet:?xt=urn:btih:…`
/// - `http(s)://…/ace/getstream?id=<40 hex>` (or `content_id=` / `infohash=`)
/// - `http(s)://…/file.acelive` / `.torrent`
public enum LinkParser {
    public enum Failure: Error, Equatable {
        case empty
        case unsupported
    }

    public static func parse(_ raw: String) -> Result<StreamSource, Failure> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>«»“”`"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        if let id = firstCapture(#"acestream://([0-9a-f]{40})(?![0-9a-f])"#, in: text) {
            return .success(.contentID(id.lowercased()))
        }
        if isHex40(text) {
            return .success(.contentID(text.lowercased()))
        }

        let lower = text.lowercased()
        if lower.hasPrefix("magnet:?") {
            if let hash = firstCapture(#"xt=urn:btih:([0-9a-f]{40})(?![0-9a-f])"#, in: text) {
                return .success(.infohash(hash.lowercased()))
            }
            return .success(.magnet(text))
        }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first(where: { $0.name.lowercased() == name })?.value
            }
            for key in ["id", "content_id"] {
                if let v = value(key), isHex40(v) { return .success(.contentID(v.lowercased())) }
            }
            if let v = value("infohash"), isHex40(v) { return .success(.infohash(v.lowercased())) }
            if ["acelive", "torrent", "acestream", "tslive"].contains(url.pathExtension.lowercased()) {
                return .success(.torrentURL(url))
            }
        }
        return .failure(.unsupported)
    }

    public static func isHex40(_ s: String) -> Bool {
        s.utf8.count == 40 && s.utf8.allSatisfy(isASCIIHex)
    }

    static func isASCIIHex(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b)
    }

    private static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
