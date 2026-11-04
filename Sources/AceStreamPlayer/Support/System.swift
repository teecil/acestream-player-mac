import Foundation
import Network

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum SystemInfo {
    /// True on Apple Silicon (also when this process itself runs under Rosetta).
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    static var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// Free space on the system volume, in gigabytes.
    static var freeDiskGB: Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return .greatestFiniteMagnitude
        }
        return Double(capacity) / 1_000_000_000
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AceStreamPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var downloads: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AceStreamPlayer/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// PID of the IINA process we launched; read by the crash watchdog.
    static var playerPIDFile: URL { support.appendingPathComponent("player.pid") }
}

/// Persistent app state (UserDefaults).
enum Prefs {
    private static var d: UserDefaults { .standard }

    static var setupCompleted: Bool {
        get { d.bool(forKey: "setupCompleted") }
        set { d.set(newValue, forKey: "setupCompleted") }
    }

    /// ID of the engine image that last started successfully (see `EngineImage`).
    static var engineImageID: String? {
        get { d.string(forKey: "engineImageID") }
        set { d.set(newValue, forKey: "engineImageID") }
    }

    /// UI language; nil until the user picks one on first launch.
    static var language: AppLanguage? {
        get { d.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) }
        set { d.set(newValue?.rawValue, forKey: "language") }
    }

    /// True when Docker Desktop on this Mac was installed by this app (so it is ours to stop).
    static var dockerInstalledByApp: Bool {
        get { d.bool(forKey: "dockerInstalledByApp") }
        set { d.set(newValue, forKey: "dockerInstalledByApp") }
    }

    static var lastLink: String? {
        get { d.string(forKey: "lastLink") }
        set { d.set(newValue, forKey: "lastLink") }
    }

    static var playerPID: Int32 {
        get { Int32(d.integer(forKey: "playerPID")) }
        set { d.set(Int(newValue), forKey: "playerPID") }
    }

    static var playerLaunchDate: Date? {
        get { d.object(forKey: "playerLaunchDate") as? Date }
        set { d.set(newValue, forKey: "playerLaunchDate") }
    }
}

/// Reports whether the Mac has a usable internet path.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var started = false

    var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "app.acestreamplayer.network"))
    }
}

enum PortFinder {
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// We deliberately avoid the engine's default 6878 so we never clash with Ace Link
    /// or a separately installed engine.
    static func freePort(from start: Int = 16878, span: Int = 50) -> Int? {
        (start..<(start + span)).first(where: isFree)
    }
}
