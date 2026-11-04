import Foundation

/// Compares release versions like "1.2.0" or "v1.10.1".
public enum Version {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "v1.2.0" → "1.2.0"
    public static func clean(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ").union(.whitespacesAndNewlines))
    }

    private static func parts(_ s: String) -> [Int] {
        clean(s).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
