import AceCore
import Foundation

/// An error explained in plain language. Every failure shown in the UI is one of these.
struct AppError: Error, Identifiable, Equatable {
    enum Kind: Equatable {
        case invalidLink, noInternet, diskFull
        case dockerMissing, dockerStartFailed, dockerTimeout
        case imagePullFailed, engineStartFailed, engineNotResponding, engineCrashed
        case streamNotFound, streamNoPeers, streamInterrupted
        case playerMissing, playerLaunchFailed
        case installCancelled, installFailed, downloadFailed
        case unexpected
    }

    enum Recovery: Equatable {
        /// Show "Повторить".
        case retry
        /// Show "Установить компоненты" (go back to setup).
        case setup
        /// Nothing to retry (e.g. the link must be fixed).
        case dismissOnly
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let recovery: Recovery

    init(_ kind: Kind, _ title: String, _ message: String, recovery: Recovery = .retry) {
        self.kind = kind
        self.title = title
        self.message = message
        self.recovery = recovery
    }

    static func == (lhs: AppError, rhs: AppError) -> Bool { lhs.id == rhs.id }

    // MARK: - Catalogue

    static func invalidLink(_ failure: LinkParser.Failure) -> AppError {
        switch failure {
        case .empty:
            return AppError(.invalidLink, tr("Paste a link", "Вставьте ссылку"),
                            tr("Copy the stream link (it usually starts with acestream://) and paste it into the field.", "Скопируйте ссылку на трансляцию (обычно она начинается с acestream://) и вставьте её в поле."),
                            recovery: .dismissOnly)
        case .unsupported:
            return AppError(.invalidLink, tr("Link not recognized", "Ссылка не распознана"),
                            tr("This doesn't look like an Ace Stream link. Use a link like acestream://… or a 40-character stream ID.", "Это не похоже на ссылку Ace Stream. Подходят ссылки вида acestream://… или идентификатор трансляции из 40 символов."),
                            recovery: .dismissOnly)
        }
    }

    static var noInternet: AppError {
        AppError(.noInternet, tr("No internet connection", "Нет подключения к интернету"),
                                         tr("Check Wi‑Fi or the cable and press Retry.", "Проверьте Wi‑Fi или кабель и нажмите «Повторить»."))
    }

    static func diskFull(needGB: Double) -> AppError {
        AppError(.diskFull, tr("Not enough disk space", "Недостаточно места на диске"),
                 tr("Free up at least \(Int(needGB.rounded(.up))) GB (for example, empty Downloads or the Trash) and press Retry.",
                    "Освободите не меньше \(Int(needGB.rounded(.up))) ГБ (например, очистите «Загрузки» или Корзину) и нажмите «Повторить»."))
    }

    static var dockerMissing: AppError {
        AppError(.dockerMissing, tr("A component is missing", "Не хватает компонента"),
                                            tr("Docker Desktop wasn't found. Maybe it was deleted. The app can install it again.", "Docker Desktop не найден — возможно, его удалили. Приложение может установить его заново."),
                                            recovery: .setup)
    }

    static var dockerStartFailed: AppError {
        AppError(.dockerStartFailed, tr("Couldn't start the playback environment", "Не удалось запустить среду воспроизведения"),
                                                tr("Docker Desktop quit while starting. Press Retry. If it happens again, restart your Mac.", "Docker Desktop закрылся во время запуска. Нажмите «Повторить». Если ошибка повторится — перезагрузите Mac."))
    }

    static var dockerTimeout: AppError {
        AppError(.dockerTimeout, tr("The playback environment isn't responding", "Среда воспроизведения не отвечает"),
                                            tr("Docker Desktop is taking too long to start. If a Docker window is asking something, answer it or close it, then press Retry.", "Docker Desktop запускается слишком долго. Если на экране есть окно Docker с вопросом — ответьте на него или закройте его, затем нажмите «Повторить»."))
    }

    static func imagePullFailed(_ reason: DockerPullFailure) -> AppError {
        switch reason {
        case .network:
            return AppError(.imagePullFailed, tr("Couldn't download the stream engine", "Не удалось загрузить движок трансляций"),
                            tr("Looks like the internet dropped. Check your connection and press Retry.", "Похоже, пропал интернет. Проверьте подключение и нажмите «Повторить»."))
        case .rateLimited:
            return AppError(.imagePullFailed, tr("The download server is busy", "Сервер загрузки временно занят"),
                            tr("The server limited the number of downloads. Wait 15–30 minutes and press Retry.", "Сервер ограничил количество загрузок. Подождите 15–30 минут и нажмите «Повторить»."))
        case .diskFull:
            return diskFull(needGB: 2)
        case .platformUnsupported, .other:
            return AppError(.imagePullFailed, tr("Couldn't download the stream engine", "Не удалось загрузить движок трансляций"),
                            tr("Try again in a couple of minutes.", "Попробуйте ещё раз через пару минут."))
        }
    }

    static var engineStartFailed: AppError {
        AppError(.engineStartFailed, tr("The stream engine didn't start", "Движок трансляций не запустился"),
                                                tr("Press Retry. That usually helps.", "Нажмите «Повторить». Обычно это помогает."))
    }

    static var engineNotResponding: AppError {
        AppError(.engineNotResponding, tr("The stream engine isn't responding", "Движок трансляций не отвечает"),
                                                  tr("Press Retry. If that doesn't help, quit the app and open it again.", "Нажмите «Повторить». Если не поможет — закройте приложение и откройте его снова."))
    }

    static var engineCrashed: AppError {
        AppError(.engineCrashed, tr("The stream engine stopped unexpectedly", "Движок трансляций неожиданно остановился"),
                                            tr("Press Retry.", "Нажмите «Повторить»."))
    }

    static var streamNotFound: AppError {
        AppError(.streamNotFound, tr("Stream not found", "Трансляция не найдена"),
                                             tr("The link is outdated or the stream isn't live right now. Check the link or try another one.", "Ссылка устарела или трансляция сейчас не идёт. Проверьте ссылку или попробуйте другую."))
    }

    static var streamNoPeers: AppError {
        AppError(.streamNoPeers, tr("The stream won't start", "Трансляция не запускается"),
                                            tr("Couldn't find any sources for the video. The stream may not have started yet or may be over already. Try later or try another link.", "Не удалось найти источники видео. Возможно, трансляция ещё не началась или уже закончилась. Попробуйте позже или другую ссылку."))
    }

    static var streamInterrupted: AppError {
        AppError(.streamInterrupted, tr("The stream was interrupted", "Трансляция прервалась"),
                                                tr("The stream engine stopped while you were watching. Press Retry to continue.", "Движок трансляций остановился во время просмотра. Нажмите «Повторить», чтобы продолжить."))
    }

    static var playerMissing: AppError {
        AppError(.playerMissing, tr("Video player not found", "Видеоплеер не найден"),
                                            tr("IINA isn't installed or was deleted. The app can install it again.", "Плеер IINA не установлен или был удалён. Приложение может установить его заново."),
                                            recovery: .setup)
    }

    static func playerLaunchFailed(_ detail: String) -> AppError {
        AppError(.playerLaunchFailed, tr("Couldn't open the player", "Не удалось открыть плеер"),
                 tr("IINA didn't start. Press Retry. If that doesn't help, reinstall the components from the Help menu.", "IINA не запустилась. Нажмите «Повторить». Если не поможет — переустановите компоненты в меню «Справка»."))
    }

    static var installCancelled: AppError {
        AppError(.installCancelled, tr("Installation not finished", "Установка не завершена"),
                                               tr("Installing needs this Mac's password. Press Retry and enter it in the macOS window.", "Для установки нужен пароль от этого Mac. Нажмите «Повторить» и введите его в окне macOS."))
    }

    static func installFailed(component: String, detail: String) -> AppError {
        AppError(.installFailed, tr("Couldn't install \(component)", "Не удалось установить \(component)"),
                 tr("Reason: \(detail). Press Retry.", "Причина: \(detail). Нажмите «Повторить»."))
    }

    static func downloadFailed(component: String) -> AppError {
        AppError(.downloadFailed, tr("Couldn't download \(component)", "Не удалось скачать \(component)"),
                 tr("Check your internet connection and press Retry.", "Проверьте подключение к интернету и нажмите «Повторить»."))
    }

    static func unexpected(_ detail: String) -> AppError {
        AppError(.unexpected, tr("Something went wrong", "Что-то пошло не так"), tr("Press Retry. Details: \(detail)", "Нажмите «Повторить». Подробности: \(detail)"))
    }

    /// Converts any error to a user-facing one.
    static func wrap(_ error: Error) -> AppError {
        if let e = error as? AppError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost,
                 .dnsLookupFailed, .cannotConnectToHost, .timedOut, .internationalRoamingOff,
                 .secureConnectionFailed:
                return .noInternet
            default:
                return .unexpected(u.localizedDescription)
            }
        }
        if error is EngineAPIError { return .engineNotResponding }
        return .unexpected(error.localizedDescription)
    }
}
