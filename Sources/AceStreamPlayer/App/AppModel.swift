import AceCore
import AppKit
import Foundation

struct SetupItem: Identifiable, Equatable {
    enum Kind: CaseIterable {
        case player, docker, engine

        var title: String {
            switch self {
            case .player: return "Видеоплеер IINA"
            case .docker: return "Docker Desktop"
            case .engine: return "Движок трансляций"
            }
        }

        var subtitle: String {
            switch self {
            case .player: return "Показывает видео"
            case .docker: return "Изолированная среда для движка"
            case .engine: return "Подключается к трансляциям Ace Stream"
            }
        }

        var symbol: String {
            switch self {
            case .player: return "play.rectangle.fill"
            case .docker: return "shippingbox.fill"
            case .engine: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    enum Status: Equatable {
        case pending
        case working(String, Double?)
        case installed
        case failed(String)
    }

    let kind: Kind
    var status: Status
    var id: Kind { kind }
}

enum StatusIndicator: Equatable {
    case checking, needsSetup, configuring, ready, preparing, live, stopping, problem
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case launching, setup, idle, starting, playing, stopping
    }

    enum StartStep: Int, CaseIterable, Identifiable {
        case system, engine, stream, player

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .system: return "Подготовка системы"
            case .engine: return "Запуск движка трансляций"
            case .stream: return "Подключение к трансляции"
            case .player: return "Открытие плеера"
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .launching {
        didSet { if phase != oldValue { phaseDidChange() } }
    }
    @Published var link = ""
    @Published private(set) var step: StartStep = .system
    @Published private(set) var stepDetail = ""
    @Published var error: AppError?
    @Published var notice: String?
    @Published private(set) var stats: EngineStats?
    @Published private(set) var setupItems: [SetupItem] = SetupItem.Kind.allCases.map { SetupItem(kind: $0, status: .pending) }
    @Published private(set) var setupRunning = false
    @Published private(set) var setupHint: String?

    // MARK: - Collaborators

    let docker = DockerService()
    let player = IINAPlayer()
    private let watchdog = CrashWatchdog()

    private var client: EngineClient?
    private var session: EngineSession?
    private var startTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var launchCleanupTask: Task<Void, Never>?
    private var autostartPending = false
    private var isQuitting = false

    var isFullySetUp: Bool { player.isInstalled && docker.isInstalled && Prefs.setupCompleted }

    var needsAdminForSetup: Bool { !docker.isInstalled }

    var statusIndicator: StatusIndicator {
        switch phase {
        case .launching: return .checking
        case .setup: return setupRunning ? .configuring : (error != nil ? .problem : .needsSetup)
        case .idle: return error != nil ? .problem : .ready
        case .starting: return .preparing
        case .playing: return .live
        case .stopping: return .stopping
        }
    }

    var needsCleanupOnQuit: Bool {
        phase == .starting || phase == .playing || phase == .stopping || setupRunning
            || client != nil || docker.launchedByUs
            || (docker.managesDesktop && docker.isDesktopProcessRunning)
    }

    // MARK: - Launch

    func onLaunch() {
        Log.info("Launch: macOS \(SystemInfo.macOSVersion), Apple Silicon: \(SystemInfo.isAppleSilicon)")
        NetworkMonitor.shared.start()
        IINAPlayer.terminateOrphanFromPreviousRun()
        player.onExit = { [weak self] in self?.playerClosedByUser() }
        if link.isEmpty, let last = Prefs.lastLink { link = last }
        refreshSetupItems()

        // Recover from a crash: remove an engine container a previous run may have left behind,
        // and shut down our idle Docker Desktop. Nothing is started here — Docker only runs
        // while a stream is on.
        launchCleanupTask = Task { [weak self] in
            guard let self, self.docker.isInstalled, await self.docker.isDaemonReady() else { return }
            await self.docker.removeOwnContainers()
            await self.docker.stopDesktopIfManaged()
        }

        phase = isFullySetUp ? .idle : .setup
    }

    private func phaseDidChange() {
        if phase == .idle && autostartPending {
            autostartPending = false
            Task { @MainActor [weak self] in self?.startStream() }
        }
    }

    // MARK: - Setup

    func refreshSetupItems() {
        setStatus(.player, player.isInstalled ? .installed : .pending)
        setStatus(.docker, docker.isInstalled ? .installed : .pending)
        setStatus(.engine, (Prefs.setupCompleted && docker.isInstalled) ? .installed : .pending)
    }

    func goToSetup() {
        guard phase == .idle || phase == .setup else { return }
        error = nil
        notice = nil
        refreshSetupItems()
        phase = .setup
    }

    func runSetup() {
        guard !setupRunning, phase == .setup else { return }
        error = nil
        setupHint = nil
        setupRunning = true
        Log.info("Setup started")
        setupTask = Task { [weak self] in
            await self?.performSetup()
            self?.setupRunning = false
        }
    }

    private func performSetup() async {
        do {
            if !player.isInstalled {
                try requireInternet()
                setStatus(.player, .working("Подготовка…", nil))
                try await Installer.installIINA(report: progressReporter(for: .player))
                guard player.isInstalled else {
                    throw AppError.installFailed(component: "IINA", detail: "приложение не появилось в папке «Программы»")
                }
            }
            setStatus(.player, .installed)

            if !docker.isInstalled {
                try requireInternet()
                setStatus(.docker, .working("Подготовка…", nil))
                try await Installer.installDocker(report: progressReporter(for: .docker))
                guard docker.isInstalled else {
                    throw AppError.installFailed(component: "Docker Desktop", detail: "приложение не появилось в папке «Программы»")
                }
                Prefs.dockerInstalledByApp = true
            }
            setStatus(.docker, .installed)

            // Start Docker, fetch the engine and prove it actually starts — then stop it again.
            setStatus(.engine, .working("Запускаем Docker Desktop…", nil))
            try await docker.ensureRunning { [weak self] text in
                self?.setStatus(.engine, .working(text, nil))
            }
            await launchCleanupTask?.value
            _ = try await launchEngine { [weak self] text, fraction in
                self?.setStatus(.engine, .working(text, fraction))
            }
            await teardown()
            setStatus(.engine, .working("Выключаем Docker до первой трансляции…", nil))
            await docker.stopDesktopIfManaged()
            setStatus(.engine, .installed)

            Prefs.setupCompleted = true
            Log.info("Setup completed")
            phase = .idle
        } catch {
            await teardown()
            if Task.isCancelled || error is CancellationError { return }
            await docker.stopDesktopIfManaged()
            Log.error("Setup failed: \(error)")
            let appError = AppError.wrap(error)
            if let index = setupItems.firstIndex(where: {
                if case .working = $0.status { return true } else { return false }
            }) {
                setupItems[index].status = .failed(appError.title)
            }
            self.error = appError
        }
    }

    private func setStatus(_ kind: SetupItem.Kind, _ status: SetupItem.Status) {
        guard let index = setupItems.firstIndex(where: { $0.kind == kind }) else { return }
        setupItems[index].status = status
    }

    /// Progress from background threads; ignored once the item is no longer "working".
    private func progressReporter(for kind: SetupItem.Kind) -> Installer.Report {
        { [weak self] progress in
            Task { @MainActor in
                guard let self, let index = self.setupItems.firstIndex(where: { $0.kind == kind }),
                      case .working = self.setupItems[index].status else { return }
                self.setupItems[index].status = .working(progress.text, progress.fraction)
            }
        }
    }

    // MARK: - Start

    func primaryAction() {
        switch phase {
        case .idle: startStream()
        case .starting: cancelStart()
        case .playing: stopStream()
        default: break
        }
    }

    func retry() {
        switch phase {
        case .setup: runSetup()
        case .idle: startStream()
        default: break
        }
    }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) { link = text.trimmed }
    }

    func startStream() {
        guard phase == .idle else { return }
        error = nil
        notice = nil

        let source: StreamSource
        switch LinkParser.parse(link) {
        case .success(let parsed): source = parsed
        case .failure(let failure):
            error = .invalidLink(failure)
            return
        }
        guard player.isInstalled else { error = .playerMissing; return }
        guard docker.isInstalled else { error = .dockerMissing; return }

        Prefs.lastLink = link.trimmed
        stats = nil
        step = .system
        stepDetail = ""
        phase = .starting
        Log.info("Start requested: \(source.logDescription)")
        startTask = Task { [weak self] in await self?.runStart(source) }
    }

    private func runStart(_ source: StreamSource) async {
        do {
            await launchCleanupTask?.value

            setStep(.system, "Проверяем готовность…")
            try await docker.ensureRunning { [weak self] text in self?.stepDetail = text }
            try Task.checkCancellation()

            setStep(.engine, "Запускаем движок…")
            let client = try await launchEngine { [weak self] text, _ in self?.stepDetail = text }
            try Task.checkCancellation()

            setStep(.stream, "Подключаемся к трансляции…")
            try requireInternet()
            let session: EngineSession
            do {
                session = try await client.start(source)
            } catch {
                throw mapStreamStartError(error)
            }
            self.session = session
            Log.info("Session opened: \(session.playbackURL.path)")
            try await waitForStreamData(client, session)
            try Task.checkCancellation()

            setStep(.player, "Открываем IINA…")
            try player.launch(session.playbackURL, title: "AceStream Player")
            phase = .playing
            startMonitoring()
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if cancelled { Log.info("Start cancelled") } else { Log.error("Start failed: \(error)") }
            await teardown()
            if !isQuitting && !autostartPending { await stopDockerDetached() }
            stats = nil
            if !cancelled && !isQuitting { self.error = AppError.wrap(error) }
            if phase != .setup { phase = .idle }
        }
    }

    private func setStep(_ newStep: StartStep, _ detail: String) {
        step = newStep
        stepDetail = detail
    }

    /// Starts the engine container, trying the native image first and a compatible fallback next.
    private func launchEngine(report: @escaping (String, Double?) -> Void) async throws -> EngineClient {
        var candidates = EngineImage.candidates
        if let saved = Prefs.engineImageID, let index = candidates.firstIndex(where: { $0.id == saved }), index > 0 {
            candidates.insert(candidates.remove(at: index), at: 0)
        }

        var lastError: Error = AppError.engineNotResponding
        for (index, image) in candidates.enumerated() {
            try Task.checkCancellation()
            if index > 0 {
                Log.warn("Trying fallback engine image \(image.reference) [\(image.platform)]")
                report("Подбираем совместимую версию движка…", nil)
            }
            do {
                if !(await docker.hasImage(image)) {
                    try requireInternet()
                    if SystemInfo.freeDiskGB < 2 { throw AppError.diskFull(needGB: 2) }
                    report("Загружаем движок трансляций (только один раз)…", nil)
                    try await docker.pull(image) { fraction in
                        Task { @MainActor in
                            let percent = fraction.map { " — \(Int($0 * 100))%" } ?? ""
                            report("Загружаем движок трансляций\(percent)", fraction)
                        }
                    }
                }
                try Task.checkCancellation()

                report("Запускаем движок…", nil)
                let port = try await docker.startEngine(image)
                if let cli = docker.cliPath {
                    watchdog.arm(dockerCLI: cli, environment: docker.environment(), stopDocker: docker.managesDesktop)
                }
                let client = EngineClient(port: port)
                self.client = client

                report("Ждём готовности движка…", nil)
                let docker = self.docker
                try await client.waitUntilReady(timeout: 90) { await docker.isEngineRunning() }
                Prefs.engineImageID = image.id
                Log.info("Engine ready: \(image.reference) [\(image.platform)] on 127.0.0.1:\(port)")
                return client
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                let fatalKinds: [AppError.Kind] = [.noInternet, .diskFull, .dockerMissing]
                if let appError = error as? AppError, fatalKinds.contains(appError.kind) {
                    throw appError
                }
                Log.error("Engine image \(image.id) failed: \(error)")
                let logs = await docker.engineLogTail()
                if !logs.isEmpty { Log.info("Engine log tail:\n\(logs)") }
                await docker.stopEngine()
                self.client = nil
                lastError = error
            }
        }
        throw lastError
    }

    private func mapStreamStartError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            if urlError.code == .timedOut { return AppError.streamNoPeers }
            return AppError.engineNotResponding
        }
        if case EngineAPIError.engine(let message)? = error as? EngineAPIError {
            Log.error("Engine refused content: \(message)")
            return AppError.streamNotFound
        }
        return AppError.wrap(error)
    }

    /// Waits until the engine is really receiving video, so the player never opens on an empty stream.
    private func waitForStreamData(_ client: EngineClient, _ session: EngineSession) async throws {
        let started = Date()
        var bufferingWithPeersSince: Date?
        var failures = 0
        while Date().timeIntervalSince(started) < 90 {
            try Task.checkCancellation()
            do {
                let current = try await client.stats(session)
                failures = 0
                stats = current
                switch current.status {
                case "dl":
                    return
                case "prebuf", "buf":
                    if current.peers > 0 {
                        stepDetail = "Буферизация… источников: \(current.peers)"
                        let since = bufferingWithPeersSince ?? Date()
                        bufferingWithPeersSince = since
                        // Some engine builds only switch to "dl" once a player reads the stream.
                        if Date().timeIntervalSince(since) > 15 { return }
                    } else {
                        stepDetail = "Ищем источники трансляции…"
                    }
                case "check", "checking":
                    stepDetail = "Проверяем данные…"
                case "err", "error":
                    throw AppError.streamNotFound
                default:
                    stepDetail = "Подключаемся…"
                }
            } catch let appError as AppError {
                throw appError
            } catch {
                if error is CancellationError { throw error }
                failures += 1
                Log.warn("stat failed (\(failures)): \(error)")
                if failures >= 6 { throw AppError.streamNotFound }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw AppError.streamNoPeers
    }

    // MARK: - Playback

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var statFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .playing else { return }

                if await self.player.hasGoneIdleAfterPlayback() {
                    Log.info("Player window closed or stream ended")
                    self.stopStream(notice: "Плеер закрыт — трансляция выключена.")
                    return
                }
                guard let client = self.client, let session = self.session else { return }
                do {
                    self.stats = try await client.stats(session)
                    statFailures = 0
                } catch {
                    statFailures += 1
                    if statFailures >= 4, !(await self.docker.isEngineRunning()) {
                        Log.error("Engine stopped during playback")
                        guard self.phase == .playing else { return }
                        self.error = .streamInterrupted
                        self.stopStream()
                        return
                    }
                }
            }
        }
    }

    private func playerClosedByUser() {
        guard phase == .playing else { return }
        stopStream(notice: "Плеер закрыт — трансляция выключена.")
    }

    // MARK: - Stop

    func cancelStart() {
        guard phase == .starting else { return }
        phase = .stopping
        startTask?.cancel()
    }

    func stopStream(notice: String? = nil) {
        guard phase == .playing else { return }
        Log.info("Stopping stream")
        phase = .stopping
        monitorTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.teardown()
            // Switching straight to another link keeps Docker up; otherwise unload everything.
            if !self.autostartPending && !self.isQuitting { await self.stopDockerDetached() }
            self.stats = nil
            self.notice = notice
            self.phase = .idle
        }
    }

    /// Closes our player, ends the engine session and removes our container.
    /// Runs in its own task so that a cancelled caller cannot interrupt the cleanup.
    private func teardown() async {
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            self.monitorTask?.cancel()
            self.monitorTask = nil
            await self.player.stop()
            if let client = self.client, let session = self.session { await client.stop(session) }
            self.session = nil
            if self.client != nil || self.docker.isInstalled {
                await self.docker.stopEngine()
            }
            self.client = nil
            self.watchdog.disarm()
        }
        await work.value
    }

    /// Shuts down our Docker Desktop; immune to the caller's cancellation.
    private func stopDockerDetached() async {
        let docker = self.docker
        await Task { @MainActor in await docker.stopDesktopIfManaged() }.value
    }

    // MARK: - URL scheme & quit

    /// `acestream://…` links opened from a browser or Finder.
    func handleOpenURL(_ url: URL) {
        Log.info("Opened via acestream:// link")
        link = url.absoluteString
        switch phase {
        case .idle:
            startStream()
        case .playing:
            autostartPending = true
            stopStream()
        case .starting:
            autostartPending = true
            cancelStart()
        case .stopping, .launching, .setup:
            autostartPending = true
        }
    }

    func prepareForQuit(timeout: TimeInterval) async {
        isQuitting = true
        autostartPending = false
        Log.info("Quitting: cleaning up")
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            self.startTask?.cancel()
            self.setupTask?.cancel()
            await self.startTask?.value
            await self.setupTask?.value
            await self.teardown()
            await self.docker.stopDesktopIfManaged()
        }
        let deadline = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work.value }
            group.addTask { await deadline.value }
            _ = await group.next()
            group.cancelAll()
        }
        deadline.cancel()
        Log.info("Cleanup finished")
    }

    // MARK: - Helpers

    private func requireInternet() throws {
        guard NetworkMonitor.shared.isOnline else { throw AppError.noInternet }
    }
}
