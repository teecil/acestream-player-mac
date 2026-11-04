import Foundation

/// Why a `docker pull` failed, in terms we can explain to a person.
public enum DockerPullFailure: Equatable, Sendable {
    case network
    case rateLimited
    case diskFull
    case platformUnsupported
    case other

    public static func classify(_ output: String) -> DockerPullFailure {
        let t = output.lowercased()
        if t.contains("toomanyrequests") || t.contains("rate limit") { return .rateLimited }
        if t.contains("no space left") { return .diskFull }
        if t.contains("no matching manifest") || t.contains("does not match the specified platform") {
            return .platformUnsupported
        }
        let networkMarkers = [
            "dial tcp", "no such host", "i/o timeout", "tls handshake", "network is unreachable",
            "connection reset", "connection refused", "temporary failure", "context deadline exceeded",
            "unexpected eof",
        ]
        if networkMarkers.contains(where: t.contains) { return .network }
        return .other
    }
}

/// Tracks layer progress from non-TTY `docker pull` output, e.g. `a1b2c3d4e5f6: Pull complete`.
public struct PullProgress {
    public private(set) var layers = Set<String>()
    public private(set) var finished = Set<String>()

    public init() {}

    public mutating func feed(_ line: String) {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let id = parts[0].trimmingCharacters(in: .whitespaces)
        let status = parts[1].trimmingCharacters(in: .whitespaces)
        guard id.utf8.count >= 12, id.utf8.allSatisfy(LinkParser.isASCIIHex) else { return }
        layers.insert(id)
        if status.hasPrefix("Pull complete") || status.hasPrefix("Already exists") {
            finished.insert(id)
        }
    }

    public var fraction: Double? {
        layers.isEmpty ? nil : Double(finished.count) / Double(layers.count)
    }
}

/// Quoting helpers for the privileged install step.
public enum ShellQuote {
    /// POSIX single-quote quoting.
    public static func sh(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal.
    public static func appleScript(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
