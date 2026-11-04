import AceCore
import AppKit
import Foundation

/// A Docker image that contains an Ace Stream engine listening on port 6878.
struct EngineImage: Equatable {
    let id: String
    let reference: String
    let platform: String

    /// Native ARM64 engine (multi-arch image; arm64 variant runs the Android engine natively).
    /// https://hub.docker.com/r/jopsis/acestream
    static let nativeARM64 = EngineImage(id: "jopsis-3.2.17-fix-arm64",
                                         reference: "jopsis/acestream:v3.2.17-fix",
                                         platform: "linux/arm64")
    /// Same image for Intel Macs.
    static let nativeAMD64 = EngineImage(id: "jopsis-3.2.17-fix-amd64",
                                         reference: "jopsis/acestream:v3.2.17-fix",
                                         platform: "linux/amd64")
    /// Ace Link's engine image (x86_64 only). On Apple Silicon it runs under emulation, so it is
    /// used only if the native image cannot start.
    static let aceLinkAMD64 = EngineImage(id: "acelink-amd64",
                                          reference: "blaiseio/acelink:latest",
                                          platform: "linux/amd64")

    static var candidates: [EngineImage] {
        SystemInfo.isAppleSilicon ? [nativeARM64, aceLinkAMD64] : [nativeAMD64, aceLinkAMD64]
    }
}

/// Drives Docker Desktop through its bundled `docker` CLI. Touches only containers
/// carrying our label; never other containers, images or Docker settings.
@MainActor
final class DockerService {
    static let bundleID = "com.docker.docker"
    static let containerName = "acestream-player-engine"
    static let label = "app.acestreamplayer.managed"

    /// Set when this app started Docker Desktop; then we also quit it when the app quits.
    private(set) var launchedByUs = false

    // MARK: - Discovery

    var appURL: URL? {
        let fm = FileManager.default
        for path in ["/Applications/Docker.app", NSHomeDirectory() + "/Applications/Docker.app"]
        where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
    }

    var cliPath: String? {
        var candidates: [String] = []
        if let app = appURL { candidates.append(app.appendingPathComponent("Contents/Resources/bin/docker").path) }
        candidates += ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isInstalled: Bool { appURL != nil && cliPath != nil }

    var isDesktopProcessRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Environment that pins the CLI to Docker Desktop's socket, independent of user contexts.
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let bundled = appURL?.appendingPathComponent("Contents/Resources/bin").path
            ?? "/Applications/Docker.app/Contents/Resources/bin"
        env["PATH"] = [bundled, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        let desktopSocket = NSHomeDirectory() + "/.docker/run/docker.sock"
        if FileManager.default.fileExists(atPath: desktopSocket) {
            env["DOCKER_HOST"] = "unix://" + desktopSocket
        } else {
            env.removeValue(forKey: "DOCKER_HOST")
        }
        env.removeValue(forKey: "DOCKER_CONTEXT")
        env["DOCKER_CLI_HINTS"] = "false"
        return env
    }

    func run(_ args: [String], timeout: TimeInterval = 30,
             onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        guard let cli = cliPath else { throw AppError.dockerMissing }
        return try await ProcessRunner.run(cli, args, environment: environment(), timeout: timeout, onLine: onLine)
    }

    // MARK: - Docker Desktop lifecycle

    func isDaemonReady() async -> Bool {
        guard let r = try? await run(["info", "--format", "{{.ServerVersion}}"], timeout: 10) else { return false }
        return r.ok && !r.stdout.trimmed.isEmpty
    }

    /// Makes sure the Docker engine answers, starting Docker Desktop in the background if needed.
    func ensureRunning(report: (String) -> Void) async throws {
        if await isDaemonReady() { return }
        guard let app = appURL, cliPath != nil else { throw AppError.dockerMissing }

        if !isDesktopProcessRunning {
            DockerSettings.applyQuietDefaultsIfManaged()
            Log.info("Starting Docker Desktop")
            report(tr("Starting Docker Desktop…", "Запускаем Docker Desktop…"))
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            config.addsToRecentItems = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
                launchedByUs = true
            } catch {
                Log.error("Docker Desktop failed to open: \(error)")
                throw AppError.dockerStartFailed
            }
        } else {
            report(tr("Waiting for Docker Desktop to be ready…", "Ждём, пока Docker Desktop будет готов…"))
        }

        let started = Date()
        var processGoneSince: Date?
        var told = false
        while Date().timeIntervalSince(started) < 240 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await isDaemonReady() {
                Log.info("Docker engine ready after \(Int(Date().timeIntervalSince(started)))s")
                return
            }
            if isDesktopProcessRunning {
                processGoneSince = nil
            } else if let since = processGoneSince {
                if Date().timeIntervalSince(since) > 20 {
                    Log.error("Docker Desktop quit while starting")
                    throw AppError.dockerStartFailed
                }
            } else {
                processGoneSince = Date()
            }
            if !told && Date().timeIntervalSince(started) > 45 {
                told = true
                report(tr("Docker Desktop is taking longer than usual. If its window appeared, you can close it.", "Docker Desktop запускается дольше обычного. Если появилось его окно — его можно закрыть."))
            }
        }
        Log.error("Docker engine did not become ready in time")
        throw AppError.dockerTimeout
    }

    /// Docker Desktop is "ours" when this app installed it or started it in this session.
    /// A Docker Desktop the user installed and started themselves is never stopped.
    var managesDesktop: Bool { launchedByUs || Prefs.dockerInstalledByApp }

    /// Fully shuts Docker Desktop down (VM included) so it uses no memory or CPU while
    /// nothing is being watched. Skipped if other containers are running in it.
    func stopDesktopIfManaged() async {
        guard managesDesktop else { return }
        guard isDesktopProcessRunning else {
            launchedByUs = false
            DockerSettings.applyQuietDefaultsIfManaged()
            return
        }
        if let r = try? await run(["ps", "-q"], timeout: 15), r.ok, !r.stdout.trimmed.isEmpty {
            Log.info("Other containers are running; leaving Docker Desktop on")
            return
        }
        Log.info("Stopping Docker Desktop to free resources")
        let r = try? await run(["desktop", "stop", "--timeout", "60"], timeout: 90)
        if r?.ok != true { Log.warn("`docker desktop stop` unavailable or failed; asking the app to quit") }
        if isDesktopProcessRunning {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) {
                app.terminate()
            }
        }
        for _ in 0..<60 where isDesktopProcessRunning {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if isDesktopProcessRunning {
            Log.warn("Docker Desktop is still running after 30 s")
        } else {
            Log.info("Docker Desktop stopped")
            launchedByUs = false
            DockerSettings.applyQuietDefaultsIfManaged()
        }
    }

    // MARK: - Engine image

    func hasImage(_ image: EngineImage) async -> Bool {
        guard let r = try? await run(["image", "inspect", "--format", "{{.Id}}", image.reference], timeout: 30) else {
            return false
        }
        return r.ok
    }

    func pull(_ image: EngineImage, progress: @escaping @Sendable (Double?) -> Void) async throws {
        Log.info("Pulling \(image.reference) [\(image.platform)]")
        let tracker = PullTracker()
        let result: ProcessResult
        do {
            result = try await run(["pull", "--platform", image.platform, image.reference], timeout: 1800) { line in
                if let fraction = tracker.feed(line) { progress(fraction) }
            }
        } catch let error as ProcessRunnerError {
            Log.error("docker pull failed: \(error)")
            throw AppError.imagePullFailed(.network)
        }
        guard result.ok else {
            Log.error("docker pull failed: \(result.combinedOutput)")
            throw AppError.imagePullFailed(DockerPullFailure.classify(result.combinedOutput))
        }
        Log.info("Pulled \(image.reference)")
    }

    // MARK: - Engine container

    /// Removes containers left by a previous run of this app (e.g. after a crash).
    func removeOwnContainers() async {
        guard let r = try? await run(["ps", "-aq", "--filter", "label=\(Self.label)"], timeout: 20), r.ok else { return }
        let ids = r.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty else { return }
        Log.info("Removing leftover engine containers: \(ids.joined(separator: ", "))")
        _ = try? await run(["rm", "-f"] + ids, timeout: 60)
    }

    /// Starts the engine container and returns the host port it is published on (127.0.0.1 only).
    func startEngine(_ image: EngineImage) async throws -> Int {
        await removeOwnContainers()
        var port = 16878
        for _ in 0..<3 {
            port = PortFinder.freePort(from: port) ?? port
            let args = [
                "run", "-d",
                "--name", Self.containerName,
                "--label", "\(Self.label)=1",
                "--platform", image.platform,
                "-p", "127.0.0.1:\(port):6878",
                image.reference,
            ]
            let r = try await run(args, timeout: 120)
            if r.ok {
                Log.info("Engine container started (\(image.reference), port \(port))")
                return port
            }
            let output = r.combinedOutput.lowercased()
            Log.error("docker run failed: \(output)")
            _ = try? await run(["rm", "-f", Self.containerName], timeout: 30)
            if output.contains("port is already allocated") || output.contains("address already in use") {
                port += 1
                continue
            }
            throw AppError.engineStartFailed
        }
        throw AppError.engineStartFailed
    }

    func isEngineRunning() async -> Bool {
        guard let r = try? await run(["inspect", "-f", "{{.State.Running}}", Self.containerName], timeout: 15) else {
            return false
        }
        return r.ok && r.stdout.trimmed == "true"
    }

    func engineLogTail() async -> String {
        guard let r = try? await run(["logs", "--tail", "40", Self.containerName], timeout: 15) else { return "" }
        return r.combinedOutput.trimmed
    }

    func stopEngine() async {
        _ = try? await run(["stop", "-t", "2", Self.containerName], timeout: 30)
        _ = try? await run(["rm", "-f", Self.containerName], timeout: 30)
    }
}

/// For the Docker Desktop this app installed: don't start at login and don't pop up the
/// dashboard — Docker should only ever run while a stream is on.
/// Written only while Docker Desktop is not running (it rewrites the file on exit), and only
/// into a settings file Docker itself has already created.
enum DockerSettings {
    private static let wanted: [(key: String, value: Bool)] = [
        ("AutoStart", false),               // "Start Docker Desktop when you sign in"
        ("OpenUIOnStartupDisabled", true),  // "Open Docker Dashboard when Docker Desktop starts" → off
        ("DisplayedOnboarding", true),      // skip the onboarding survey
    ]

    @MainActor
    static func applyQuietDefaultsIfManaged() {
        guard Prefs.dockerInstalledByApp,
              NSRunningApplication.runningApplications(withBundleIdentifier: DockerService.bundleID).isEmpty else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.docker", isDirectory: true)
        for name in ["settings-store.json", "settings.json"] {
            update(directory.appendingPathComponent(name))
        }
    }

    private static func update(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var settings = parsed as? [String: Any] else { return }
        // settings-store.json uses PascalCase keys, the legacy settings.json camelCase.
        let camelCaseFile = settings.keys.contains { $0.first?.isLowercase == true }
        var changed = false
        for (pascal, value) in wanted {
            let camel = pascal.prefix(1).lowercased() + pascal.dropFirst()
            let key = settings.keys.first { $0 == pascal || $0 == camel } ?? (camelCaseFile ? camel : pascal)
            if (settings[key] as? Bool) != value {
                settings[key] = value
                changed = true
            }
        }
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try out.write(to: url, options: .atomic)
            Log.info("Docker Desktop: disabled start at login and dashboard pop-up (\(url.lastPathComponent))")
        } catch {
            Log.warn("Could not update Docker Desktop settings: \(error)")
        }
    }
}

/// Thread-safe wrapper around `PullProgress`, fed from the pull process's output thread.
private final class PullTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = PullProgress()
    private var lastReported: Double = -1

    /// Returns a new fraction when it changed noticeably.
    func feed(_ line: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        progress.feed(line)
        guard let f = progress.fraction, abs(f - lastReported) >= 0.01 else { return nil }
        lastReported = f
        return f
    }
}
