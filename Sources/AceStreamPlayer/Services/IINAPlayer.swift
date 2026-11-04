import AppKit
import Foundation

/// Launches IINA as a *separate* process we own (exactly what IINA's own `iina-cli` does),
/// so we can close our player window without touching IINA windows the user opened.
@MainActor
final class IINAPlayer {
    static let bundleID = "com.colliderli.iina"

    private var process: Process?
    private var socketPath: String?
    private var sawPlayback = false

    /// Called when the IINA process we launched exits on its own (user quit it).
    var onExit: (() -> Void)?

    var appURL: URL? {
        let fm = FileManager.default
        for path in ["/Applications/IINA.app", NSHomeDirectory() + "/Applications/IINA.app"]
        where fm.isExecutableFile(atPath: path + "/Contents/MacOS/IINA") {
            return URL(fileURLWithPath: path)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
           fm.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/IINA").path) {
            return url
        }
        return nil
    }

    var isInstalled: Bool { appURL != nil }
    var isRunning: Bool { process?.isRunning ?? false }

    func launch(_ streamURL: URL, title: String) throws {
        guard let app = appURL else { throw AppError.playerMissing }
        let executable = app.appendingPathComponent("Contents/MacOS/IINA")
        let socket = "/tmp/acestreamplayer-\(getuid())-\(getpid()).sock"
        unlink(socket)

        let p = Process()
        p.executableURL = executable
        p.arguments = [
            // mpv JSON IPC lets us notice when the user closes the player window.
            "--mpv-input-ipc-server=\(socket)",
            "--mpv-force-media-title=\(title)",
            streamURL.absoluteString,
        ]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.processDidExit(finished) }
        }
        do {
            try p.run()
        } catch {
            Log.error("IINA failed to launch: \(error)")
            throw AppError.playerLaunchFailed(error.localizedDescription)
        }
        process = p
        socketPath = socket
        sawPlayback = false
        let pid = p.processIdentifier
        Prefs.playerPID = pid
        Prefs.playerLaunchDate = Date()
        try? "\(pid)".write(to: AppPaths.playerPIDFile, atomically: true, encoding: .utf8)
        Log.info("IINA launched, pid \(pid)")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }

    /// True when the player was playing and has since gone idle (window closed or stream ended).
    func hasGoneIdleAfterPlayback() async -> Bool {
        guard let socket = socketPath, isRunning else { return false }
        let idle = await Task.detached(priority: .utility) { MPVIPC.idleActive(socket: socket) }.value
        guard let idle else { return false }
        if !idle {
            sawPlayback = true
            return false
        }
        return sawPlayback
    }

    /// Closes only the IINA process we started.
    func stop() async {
        guard let p = process else { return }
        process = nil
        let pid = p.processIdentifier
        if p.isRunning {
            Log.info("Closing IINA, pid \(pid)")
            p.terminate()
        }
        for _ in 0..<25 where p.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning {
            Log.warn("IINA did not exit, killing pid \(pid)")
            kill(pid, SIGKILL)
        }
        cleanup()
    }

    private func processDidExit(_ finished: Process) {
        guard finished === process else { return }
        Log.info("IINA exited by itself (status \(finished.terminationStatus))")
        process = nil
        cleanup()
        onExit?()
    }

    private func cleanup() {
        if let socketPath { unlink(socketPath) }
        socketPath = nil
        Prefs.playerPID = 0
        Prefs.playerLaunchDate = nil
        try? FileManager.default.removeItem(at: AppPaths.playerPIDFile)
    }

    /// If the app crashed while playing, its IINA window may still be open: close it.
    static func terminateOrphanFromPreviousRun() {
        let pid = Prefs.playerPID
        defer {
            Prefs.playerPID = 0
            Prefs.playerLaunchDate = nil
            try? FileManager.default.removeItem(at: AppPaths.playerPIDFile)
        }
        guard pid > 0, let saved = Prefs.playerLaunchDate,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == bundleID,
              let launched = app.launchDate,
              abs(launched.timeIntervalSince(saved)) < 15 else { return }
        Log.info("Closing IINA left over from a previous run, pid \(pid)")
        app.forceTerminate()
    }
}

/// Minimal client for mpv's JSON IPC (https://mpv.io/manual/stable/#json-ipc).
enum MPVIPC {
    static func idleActive(socket path: String) -> Bool? {
        guard let reply = request(["get_property", "idle-active"], socket: path),
              (reply["error"] as? String) == "success" else { return nil }
        return (reply["data"] as? NSNumber)?.boolValue
    }

    static func request(_ command: [Any], socket path: String, timeout: TimeInterval = 1) -> [String: Any]? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let requestID = Int.random(in: 1...1_000_000)
        guard var payload = try? JSONSerialization.data(withJSONObject: ["command": command, "request_id": requestID]) else {
            return nil
        }
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == payload.count else { return nil }

        var buffer = Data()
        let capacity = 4096
        var chunk = [UInt8](repeating: 0, count: capacity)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &chunk, capacity, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   (object["request_id"] as? NSNumber)?.intValue == requestID {
                    return object
                }
            }
        }
        return nil
    }
}
