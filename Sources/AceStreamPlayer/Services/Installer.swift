import AceCore
import Foundation

/// Downloads and installs IINA and Docker Desktop from their official sources.
/// Every package is checked by Gatekeeper (Developer ID + notarization) and for an
/// Apple Silicon (arm64) binary before it is installed.
enum Installer {
    struct Progress: Sendable {
        let text: String
        let fraction: Double?
    }

    typealias Report = @Sendable (Progress) -> Void

    /// Official Docker Desktop builds (docs.docker.com/desktop/setup/install/mac-install/).
    static let dockerDMGAppleSilicon = URL(string: "https://desktop.docker.com/mac/main/arm64/Docker.dmg")!
    static let dockerDMGIntel = URL(string: "https://desktop.docker.com/mac/main/amd64/Docker.dmg")!
    /// Official IINA releases.
    static let iinaLatestRelease = URL(string: "https://api.github.com/repos/iina/iina/releases/latest")!

    // MARK: - IINA

    static func installIINA(report: @escaping Report) async throws {
        report(Progress(text: tr("Looking for the latest version…", "Ищем последнюю версию…"), fraction: nil))
        let asset = try await latestIINAAsset()
        let dmg = AppPaths.downloads.appendingPathComponent(asset.name)
        try await download(asset.url, to: dmg, label: tr("Downloading IINA", "Загрузка IINA"), component: "IINA", report: report)

        report(Progress(text: tr("Verifying…", "Проверяем подлинность…"), fraction: nil))
        let mount = try await DiskImage.attach(dmg)
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
                throw AppError.installFailed(component: "IINA", detail: tr("the downloaded file has no app inside", "в загруженном файле нет приложения"))
            }
            try verifyArchitecture(app, component: "IINA")
            try await verifyGatekeeper(app, component: "IINA")
            report(Progress(text: tr("Installing into Applications…", "Устанавливаем в «Программы»…"), fraction: nil))
            try await copyApp(app, to: URL(fileURLWithPath: "/Applications/IINA.app"))
        } catch {
            await DiskImage.detach(mount)
            throw error
        }
        await DiskImage.detach(mount)
        try? FileManager.default.removeItem(at: dmg)
        Log.info("IINA installed")
    }

    private static func latestIINAAsset() async throws -> (name: String, url: URL) {
        var request = URLRequest(url: iinaLatestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AceStreamPlayer-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let fetched: (Data, URLResponse)
        do {
            fetched = try await URLSession.shared.data(for: request)
        } catch {
            Log.error("IINA release lookup failed: \(error)")
            throw AppError.wrap(error)
        }
        let (data, response) = fetched
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [[String: Any]] else {
            throw AppError.downloadFailed(component: "IINA")
        }
        for asset in assets {
            if let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
               let link = asset["browser_download_url"] as? String, let url = URL(string: link),
               url.host == "github.com" {
                Log.info("Latest IINA asset: \(name)")
                return (name, url)
            }
        }
        throw AppError.downloadFailed(component: "IINA")
    }

    // MARK: - Docker Desktop

    static func installDocker(report: @escaping Report) async throws {
        let source = SystemInfo.isAppleSilicon ? dockerDMGAppleSilicon : dockerDMGIntel
        let dmg = AppPaths.downloads.appendingPathComponent("Docker.dmg")

        // A finished download from an earlier attempt is reused (files land here only when complete).
        if !FileManager.default.fileExists(atPath: dmg.path) {
            try await download(source, to: dmg, label: tr("Downloading Docker Desktop", "Загрузка Docker Desktop"), component: "Docker Desktop", report: report)
        }
        report(Progress(text: tr("Verifying…", "Проверяем подлинность…"), fraction: nil))
        let mount: URL
        do {
            mount = try await DiskImage.attach(dmg)
        } catch {
            Log.warn("Cached Docker.dmg unusable, downloading again")
            try? FileManager.default.removeItem(at: dmg)
            try await download(source, to: dmg, label: tr("Downloading Docker Desktop", "Загрузка Docker Desktop"), component: "Docker Desktop", report: report)
            mount = try await DiskImage.attach(dmg)
        }

        do {
            let app = mount.appendingPathComponent("Docker.app")
            guard FileManager.default.fileExists(atPath: app.path) else {
                throw AppError.installFailed(component: "Docker Desktop", detail: tr("the downloaded file has no app inside", "в загруженном файле нет приложения"))
            }
            try verifyArchitecture(app, component: "Docker Desktop")
            try await verifyGatekeeper(app, component: "Docker Desktop")

            report(Progress(text: tr("Installing… macOS will ask for your Mac password", "Устанавливаем… macOS попросит пароль от Mac"), fraction: nil))
            // Official unattended install: accepts the license and performs the privileged
            // configuration now, so Docker Desktop never asks for it on first launch.
            let installer = app.appendingPathComponent("Contents/MacOS/install").path
            let command = "\(ShellQuote.sh(installer)) --accept-license --user=\(ShellQuote.sh(NSUserName()))"
            try await Privileged.run(
                command,
                prompt: tr("AceStream Player is installing Docker Desktop, the environment the stream engine runs in.", "AceStream Player устанавливает Docker Desktop — среду, в которой безопасно работает движок трансляций.")
            )
        } catch {
            await DiskImage.detach(mount)
            throw error
        }
        await DiskImage.detach(mount)
        try? FileManager.default.removeItem(at: dmg)

        guard FileManager.default.fileExists(atPath: "/Applications/Docker.app") else {
            throw AppError.installFailed(component: "Docker Desktop", detail: tr("the app did not appear in Applications", "приложение не появилось в папке «Программы»"))
        }
        Log.info("Docker Desktop installed")
    }

    // MARK: - Steps

    private static func download(_ url: URL, to destination: URL, label: String, component: String,
                                 report: @escaping Report) async throws {
        try checkFreeSpace(component: component)
        report(Progress(text: "\(label)…", fraction: 0))
        Log.info("Downloading \(url.absoluteString)")
        do {
            try await Downloader.download(url, to: destination) { fraction, bytes in
                let mb = Int(Double(bytes) / 1_048_576)
                report(Progress(text: tr("\(label): \(mb) MB", "\(label) — \(mb) МБ"), fraction: fraction))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AppError {
            throw error
        } catch {
            Log.error("Download failed: \(error)")
            let wrapped = AppError.wrap(error)
            throw wrapped.kind == .noInternet ? wrapped : AppError.downloadFailed(component: component)
        }
    }

    private static func checkFreeSpace(component: String) throws {
        let need: Double = component == "Docker Desktop" ? 6 : 1
        if SystemInfo.freeDiskGB < need { throw AppError.diskFull(needGB: need) }
    }

    /// Makes sure the app's main executable runs natively on this Mac (arm64 on Apple Silicon).
    static func verifyArchitecture(_ app: URL, component: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let executableName = info["CFBundleExecutable"] as? String else {
            throw AppError.installFailed(component: component, detail: tr("the installer file is damaged", "повреждённый файл установки"))
        }
        let executable = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        let types = MachOArch.cpuTypes(ofFileAt: executable)
        let needed = SystemInfo.isAppleSilicon ? MachOArch.cpuARM64 : MachOArch.cpuX86_64
        guard types.contains(needed) else {
            Log.error("\(component): CPU types \(types) do not include \(needed)")
            throw AppError.installFailed(component: component, detail: tr("this version doesn't fit your Mac", "эта версия не подходит для вашего Mac"))
        }
        Log.info("\(component): native architecture confirmed")
    }

    /// Gatekeeper assessment: valid Developer ID signature and notarization.
    static func verifyGatekeeper(_ app: URL, component: String) async throws {
        let result = try await ProcessRunner.run(
            "/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose", app.path], timeout: 900
        )
        Log.info("spctl \(component): status \(result.status) \(result.stderr.trimmed)")
        guard result.ok else {
            throw AppError.installFailed(component: component, detail: tr("the file failed Apple's authenticity check", "файл не прошёл проверку подлинности Apple"))
        }
    }

    private static func copyApp(_ source: URL, to destination: URL) async throws {
        let direct = try await ProcessRunner.run("/usr/bin/ditto", [source.path, destination.path], timeout: 900)
        if direct.ok { return }
        Log.warn("ditto as user failed (\(direct.stderr.trimmed)); retrying with administrator rights")
        try await Privileged.run(
            "/usr/bin/ditto \(ShellQuote.sh(source.path)) \(ShellQuote.sh(destination.path))",
            prompt: tr("AceStream Player is installing the IINA video player into Applications.", "AceStream Player устанавливает видеоплеер IINA в папку «Программы».")
        )
    }
}

// MARK: - Helpers

/// Runs a shell command as root via the standard macOS administrator password dialog.
enum Privileged {
    static func run(_ command: String, prompt: String) async throws {
        let script = "do shell script \(ShellQuote.appleScript(command)) with prompt \(ShellQuote.appleScript(prompt)) with administrator privileges"
        let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 1800)
        if result.ok { return }
        Log.error("Privileged command failed (\(result.status)): \(result.stderr.trimmed)")
        if result.stderr.contains("-128") { throw AppError.installCancelled }
        throw AppError.installFailed(component: tr("component", "компонент"), detail: tr("the installer failed", "установщик завершился с ошибкой"))
    }
}

enum DiskImage {
    static func attach(_ dmg: URL) async throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("acestreamplayer-mount-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(
            "/usr/bin/hdiutil",
            ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path],
            timeout: 600
        )
        guard result.ok else {
            Log.error("hdiutil attach failed: \(result.stderr.trimmed)")
            try? FileManager.default.removeItem(at: mount)
            throw AppError.installFailed(component: tr("component", "компонент"), detail: tr("the downloaded file is damaged", "загруженный файл повреждён"))
        }
        return mount
    }

    static func detach(_ mount: URL) async {
        _ = try? await ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 120)
        try? FileManager.default.removeItem(at: mount)
    }
}

/// URLSession download with progress; the file is moved into place only when complete.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finishError: Error?
    private var lastReport = Date.distantPast

    private init(destination: URL, progress: @escaping @Sendable (Double?, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(_ url: URL, to destination: URL,
                         progress: @escaping @Sendable (Double?, Int64) -> Void) async throws {
        let delegate = Downloader(destination: destination, progress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3 * 3600
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.lock.lock()
                delegate.continuation = continuation
                delegate.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastReport) > 0.25
        if due { lastReport = now }
        lock.unlock()
        guard due else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        progress(fraction, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        var error: Error?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Log.error("Download HTTP status \(http.statusCode)")
            error = URLError(.badServerResponse)
        } else {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
            } catch let moveError {
                error = moveError
            }
        }
        lock.lock()
        finishError = error
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let finishError = self.finishError
        lock.unlock()
        if let error = error ?? finishError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
