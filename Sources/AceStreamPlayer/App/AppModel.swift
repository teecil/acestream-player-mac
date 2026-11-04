import AceCore
import AppKit
import Foundation

struct SetupItem: Identifiable, Equatable {
    enum Kind: CaseIterable {
        case player, docker, engine

        var title: String {
            switch self {
            case .player: return tr("IINA video player", "Видеоплеер IINA")
            case .docker: return "Docker Desktop"
            case .engine: return tr("Stream engine", "Движок трансляций")
            }
        }

        var subtitle: String {
            switch self {
            case .player: return tr("Plays the video", "Показывает видео")
            case .docker: return tr("Isolated environment for the engine", "Изолированная среда для движка")
            case .engine: return tr("Connects to Ace Stream broadcasts", "Подключается к трансляциям Ace Stream")
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
        case launching, chooseLanguage, setup, idle, starting, playing, stopping
    }

    enum StartStep: Int, CaseIterable, Identifiable {
        case system, engine, stream, player

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .system: return tr("Preparing the system", "Подготовка системы")
            case .engine: return tr("Starting the stream engine", "Запуск движка трансляций")
            case .stream: return tr("Connecting to the stream", "Подключение к трансляции")
            case .player: return tr("Opening the player", "Открытие плеера")
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
    /// UI language. The window is rebuilt when it changes, so every string is re-translated.
    @Published private(set) var language: AppLanguage = L10n.current
    /// The link that is currently playing or starting.
    @Published private(set) var activeLink: String?
    /// Non-nil while a new stream is being prepared in the background (the old one keeps playing).
    @Published private(set) var switchDetail: String?

    /// True when the field holds a different link than the one on screen — offer "Открыть".
    var canOpenOtherLink: Bool {
        let text = link.trimmed
        return (phase == .playing || phase == .starting) && !text.isEmpty && text != activeLink
    }

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
    private var currentSource: StreamSource?
    private var switchTask: Task<Void, Never>?
    private var switchGeneration = 0

    var isFullySetUp: Bool { player.isInstalled && docker.isInstalled && Prefs.setupCompleted }

    var needsAdminForSetup: Bool { !docker.isInstalled }

    var statusIndicator: StatusIndicator {
        switch phase {
        case .launching, .chooseLanguage: return .checking
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

        phase = Prefs.language == nil ? .chooseLanguage : (isFullySetUp ? .idle : .setup)
    }

    private func phaseDidChange() {
        if phase == .idle && autostartPending {
            autostartPending = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startStream()
                // The new link could not start: don't leave the warm engine and Docker running.
                if self.phase == .idle && self.client != nil {
                    await self.teardown()
                    await self.stopDockerDetached()
                }
            }
        }
    }

    // MARK: - Setup

    func refreshSetupItems() {
        setStatus(.player, player.isInstalled ? .installed : .pending)
        setStatus(.docker, docker.isInstalled ? .installed : .pending)
        setStatus(.engine, (Prefs.setupCompleted && docker.isInstalled) ? .installed : .pending)
    }

    /// Screenshot mode: show the main screen without touching Docker, IINA or settings.
    func prepareForScreenshot() {
        link = "acestream://"
        phase = .idle
    }

    // MARK: - Language

    /// First launch: picks the language and moves on to setup. Later (from the menu): switches
    /// the interface language in place.
    func setLanguage(_ language: AppLanguage, persist: Bool = true) {
        L10n.current = language
        self.language = language // rebuilds the whole window (see ContentView)
        guard persist else { return }
        Log.info("Language: \(language.rawValue)")
        Prefs.language = language
        AppDelegate.shared?.rebuildMenu()
        if phase == .chooseLanguage {
            phase = isFullySetUp ? .idle : .setup
        } else if !setupRunning {
            refreshSetupItems()
        }
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
                setStatus(.player, .working(tr("Preparing…", "Подготовка…"), nil))
                try await Installer.installIINA(report: progressReporter(for: .player))
                guard player.isInstalled else {
                    throw AppError.installFailed(component: "IINA", detail: tr("the app did not appear in Applications", "приложение не появилось в папке «Программы»"))
                }
            }
            setStatus(.player, .installed)

            if !docker.isInstalled {
                try requireInternet()
                setStatus(.docker, .working(tr("Preparing…", "Подготовка…"), nil))
                try await Installer.installDocker(report: progressReporter(for: .docker))
                guard docker.isInstalled else {
                    throw AppError.installFailed(component: "Docker Desktop", detail: tr("the app did not appear in Applications", "приложение не появилось в папке «Программы»"))
                }
                Prefs.dockerInstalledByApp = true
            }
            setStatus(.docker, .installed)

            // Start Docker, fetch the engine and prove it actually starts — then stop it again.
            setStatus(.engine, .working(tr("Starting Docker Desktop…", "Запускаем Docker Desktop…"), nil))
            try await docker.ensureRunning { [weak self] text in
                self?.setStatus(.engine, .working(text, nil))
            }
            await launchCleanupTask?.value
            _ = try await launchEngine { [weak self] text, fraction in
                self?.setStatus(.engine, .working(text, fraction))
            }
            await teardown()
            setStatus(.engine, .working(tr("Shutting Docker down until the first stream…", "Выключаем Docker до первой трансляции…"), nil))
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
        case .playing: switchStream()
        default: break
        }
    }

    /// Enter in the link field / the "Открыть" button.
    func submitLink() {
        switch phase {
        case .idle:
            startStream()
        case .playing:
            switchStream()
        case .starting:
            // The current link is still starting (maybe it's dead): drop it and try the new one.
            // The engine and Docker stay up, so this is quick.
            guard canOpenOtherLink else { return }
            if case .failure(let failure) = LinkParser.parse(link) {
                error = .invalidLink(failure)
                return
            }
            Log.info("New link while starting: restarting with it")
            autostartPending = true
            cancelStart()
        default:
            break
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
        activeLink = link.trimmed
        currentSource = source
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

            setStep(.system, tr("Checking that everything is ready…", "Проверяем готовность…"))
            try await docker.ensureRunning { [weak self] text in self?.stepDetail = text }
            try Task.checkCancellation()

            setStep(.engine, tr("Starting the engine…", "Запускаем движок…"))
            let client = try await launchEngine { [weak self] text, _ in self?.stepDetail = text }
            try Task.checkCancellation()

            setStep(.stream, tr("Connecting to the stream…", "Подключаемся к трансляции…"))
            try requireInternet()
            let session: EngineSession
            do {
                session = try await client.start(source)
            } catch {
                throw mapStreamStartError(error)
            }
            self.session = session
            Log.info("Session opened: \(session.playbackURL.path)")
            try await waitForStreamData(client, session,
                                        progress: { [weak self] text in self?.stepDetail = text },
                                        onStats: { [weak self] value in self?.stats = value })
            try Task.checkCancellation()

            setStep(.player, tr("Opening IINA…", "Открываем IINA…"))
            try player.launch(session.playbackURL, title: "AceStream Player")
            phase = .playing
            startMonitoring()
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if cancelled { Log.info("Start cancelled") } else { Log.error("Start failed: \(error)") }
            // Restarting with another link keeps the engine (and Docker) warm.
            let restarting = autostartPending && !isQuitting
            await teardown(keepEngine: restarting)
            if !isQuitting && !restarting { await stopDockerDetached() }
            stats = nil
            activeLink = nil
            currentSource = nil
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
        // An engine kept warm from the previous link is reused as is.
        if let existing = self.client {
            let docker = self.docker
            do {
                guard await docker.isEngineRunning() else { throw AppError.engineCrashed }
                report(tr("Waiting for the engine…", "Ждём готовности движка…"), nil)
                try await existing.waitUntilReady(timeout: 60) { await docker.isEngineRunning() }
                Log.info("Reusing running engine on port \(existing.port)")
                return existing
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                Log.warn("Warm engine unusable (\(error)); starting a fresh one")
                await docker.stopEngine()
                self.client = nil
            }
        }

        var candidates = EngineImage.candidates
        if let saved = Prefs.engineImageID, let index = candidates.firstIndex(where: { $0.id == saved }), index > 0 {
            candidates.insert(candidates.remove(at: index), at: 0)
        }

        var lastError: Error = AppError.engineNotResponding
        for (index, image) in candidates.enumerated() {
            try Task.checkCancellation()
            if index > 0 {
                Log.warn("Trying fallback engine image \(image.reference) [\(image.platform)]")
                report(tr("Trying a compatible engine version…", "Подбираем совместимую версию движка…"), nil)
            }
            do {
                if !(await docker.hasImage(image)) {
                    try requireInternet()
                    if SystemInfo.freeDiskGB < 2 { throw AppError.diskFull(needGB: 2) }
                    report(tr("Downloading the stream engine (one time only)…", "Загружаем движок трансляций (только один раз)…"), nil)
                    try await docker.pull(image) { fraction in
                        Task { @MainActor in
                            let percent = fraction.map { " — \(Int($0 * 100))%" } ?? ""
                            report(tr("Downloading the stream engine\(percent)", "Загружаем движок трансляций\(percent)"), fraction)
                        }
                    }
                }
                try Task.checkCancellation()

                report(tr("Starting the engine…", "Запускаем движок…"), nil)
                let port = try await docker.startEngine(image)
                if let cli = docker.cliPath {
                    watchdog.arm(dockerCLI: cli, environment: docker.environment(), stopDocker: docker.managesDesktop)
                }
                let client = EngineClient(port: port)
                self.client = client

                report(tr("Waiting for the engine…", "Ждём готовности движка…"), nil)
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
    private func waitForStreamData(_ client: EngineClient, _ session: EngineSession,
                                   progress: (String) -> Void,
                                   onStats: (EngineStats) -> Void) async throws {
        let started = Date()
        var bufferingWithPeersSince: Date?
        var failures = 0
        while Date().timeIntervalSince(started) < 90 {
            try Task.checkCancellation()
            do {
                let current = try await client.stats(session)
                failures = 0
                onStats(current)
                switch current.status {
                case "dl":
                    return
                case "prebuf", "buf":
                    if current.peers > 0 {
                        progress(tr("Buffering… sources: \(current.peers)", "Буферизация… источников: \(current.peers)"))
                        let since = bufferingWithPeersSince ?? Date()
                        bufferingWithPeersSince = since
                        // Some engine builds only switch to "dl" once a player reads the stream.
                        if Date().timeIntervalSince(since) > 15 { return }
                    } else {
                        progress(tr("Looking for stream sources…", "Ищем источники трансляции…"))
                    }
                case "check", "checking":
                    progress(tr("Checking data…", "Проверяем данные…"))
                case "err", "error":
                    throw AppError.streamNotFound
                default:
                    progress(tr("Connecting…", "Подключаемся…"))
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

    // MARK: - Switching to another link while playing

    /// Prepares the link from the field alongside the current stream. The current stream keeps
    /// playing; the player switches only once the new one actually delivers video. If the new
    /// one doesn't start, nothing changes on screen except a message.
    func switchStream() {
        guard phase == .playing, client != nil, session != nil else { return }
        error = nil
        notice = nil
        let source: StreamSource
        switch LinkParser.parse(link) {
        case .success(let parsed): source = parsed
        case .failure(let failure):
            error = .invalidLink(failure)
            return
        }
        if source == currentSource {
            // Back to the link that is already on screen: just drop any pending switch.
            if switchTask != nil { cancelSwitch() } else { notice = tr("This stream is already open.", "Эта трансляция уже открыта.") }
            return
        }

        Log.info("Switch requested: \(source.logDescription)")
        let newLink = link.trimmed
        let previous = switchTask
        previous?.cancel()
        switchGeneration += 1
        let generation = switchGeneration
        switchDetail = tr("Connecting to the new stream…", "Подключаемся к новой трансляции…")
        switchTask = Task { [weak self] in
            await previous?.value
            await self?.runSwitch(to: source, link: newLink, generation: generation)
        }
    }

    func cancelSwitch() {
        guard switchTask != nil else { return }
        Log.info("Switch cancelled by user")
        switchTask?.cancel()
    }

    private func runSwitch(to source: StreamSource, link newLink: String, generation: Int) async {
        var newSession: EngineSession?
        do {
            try Task.checkCancellation()
            guard phase == .playing, let client = self.client, let oldSession = self.session else {
                throw CancellationError()
            }
            try requireInternet()
            let opened: EngineSession
            do {
                opened = try await client.start(source)
            } catch {
                throw mapStreamStartError(error)
            }
            newSession = opened
            try await waitForStreamData(client, opened,
                                        progress: { [weak self] text in
                                            guard let self, self.switchGeneration == generation else { return }
                                            self.switchDetail = text
                                        },
                                        onStats: { _ in })
            try Task.checkCancellation()
            guard phase == .playing else { throw CancellationError() }

            // The new stream delivers video: swap players.
            switchDetail = tr("Opening the new stream…", "Открываем новую трансляцию…")
            monitorTask?.cancel()
            await player.stop()
            await client.stop(oldSession)
            session = opened
            currentSource = source
            activeLink = newLink
            Prefs.lastLink = newLink
            stats = nil
            try player.launch(opened.playbackURL, title: "AceStream Player")
            Log.info("Switched to new stream")
            finishSwitch(generation)
            startMonitoring()
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            // Close the half-opened new session unless it already became the current one.
            if let opened = newSession, opened != self.session, let client = self.client {
                await Task { @MainActor in await client.stop(opened) }.value
            }
            finishSwitch(generation)
            if cancelled { return }
            Log.error("Switch failed: \(error)")
            let reason = AppError.wrap(error)
            if phase == .playing && player.isRunning {
                self.error = AppError(reason.kind, tr("The new stream didn't start", "Новая трансляция не запустилась"),
                                      tr("The current one keeps playing. \(reason.message)", "Продолжаем показывать текущую. \(reason.message)"))
                if monitorTask == nil || monitorTask?.isCancelled == true { startMonitoring() }
            } else if phase == .playing {
                // The old player was already closed — nothing left to fall back to.
                self.error = reason
                stopStream()
            }
        }
    }

    private func finishSwitch(_ generation: Int) {
        guard generation == switchGeneration else { return }
        switchTask = nil
        switchDetail = nil
    }

    // MARK: - Playback

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var statFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .playing else { return }
                // While a new link is being prepared, the old window may be closed on purpose.
                if self.switchTask == nil, await self.player.hasGoneIdleAfterPlayback() {
                    Log.info("Player window closed or stream ended")
                    self.stopStream(notice: tr("The player was closed, so the stream was stopped.", "Плеер закрыт — трансляция выключена."))
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
        guard phase == .playing, switchTask == nil else { return }
        stopStream(notice: tr("The player was closed, so the stream was stopped.", "Плеер закрыт — трансляция выключена."))
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
        let pendingSwitch = switchTask
        pendingSwitch?.cancel()
        Task { [weak self] in
            await pendingSwitch?.value
            guard let self else { return }
            await self.teardown()
            if !self.isQuitting { await self.stopDockerDetached() }
            self.stats = nil
            self.activeLink = nil
            self.currentSource = nil
            self.notice = notice
            self.phase = .idle
        }
    }

    /// Closes our player and ends the engine session. Unless `keepEngine`, also removes our
    /// container. Runs in its own task so that a cancelled caller cannot interrupt the cleanup.
    private func teardown(keepEngine: Bool = false) async {
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            self.monitorTask?.cancel()
            self.monitorTask = nil
            await self.player.stop()
            if let client = self.client, let session = self.session { await client.stop(session) }
            self.session = nil
            if keepEngine && self.client != nil { return }
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
            switchStream()
        case .starting:
            submitLink()
        case .stopping, .launching, .chooseLanguage, .setup:
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
            self.switchTask?.cancel()
            await self.startTask?.value
            await self.setupTask?.value
            await self.switchTask?.value
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
