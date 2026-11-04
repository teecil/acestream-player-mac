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
            return AppError(.invalidLink, "Вставьте ссылку",
                            "Скопируйте ссылку на трансляцию (обычно она начинается с acestream://) и вставьте её в поле.",
                            recovery: .dismissOnly)
        case .unsupported:
            return AppError(.invalidLink, "Ссылка не распознана",
                            "Это не похоже на ссылку Ace Stream. Подходят ссылки вида acestream://… или идентификатор трансляции из 40 символов.",
                            recovery: .dismissOnly)
        }
    }

    static let noInternet = AppError(.noInternet, "Нет подключения к интернету",
                                     "Проверьте Wi‑Fi или кабель и нажмите «Повторить».")

    static func diskFull(needGB: Double) -> AppError {
        AppError(.diskFull, "Недостаточно места на диске",
                 "Освободите не меньше \(Int(needGB.rounded(.up))) ГБ (например, очистите «Загрузки» или Корзину) и нажмите «Повторить».")
    }

    static let dockerMissing = AppError(.dockerMissing, "Не хватает компонента",
                                        "Docker Desktop не найден — возможно, его удалили. Приложение может установить его заново.",
                                        recovery: .setup)

    static let dockerStartFailed = AppError(.dockerStartFailed, "Не удалось запустить среду воспроизведения",
                                            "Docker Desktop закрылся во время запуска. Нажмите «Повторить». Если ошибка повторится — перезагрузите Mac.")

    static let dockerTimeout = AppError(.dockerTimeout, "Среда воспроизведения не отвечает",
                                        "Docker Desktop запускается слишком долго. Если на экране есть окно Docker с вопросом — ответьте на него или закройте его, затем нажмите «Повторить».")

    static func imagePullFailed(_ reason: DockerPullFailure) -> AppError {
        switch reason {
        case .network:
            return AppError(.imagePullFailed, "Не удалось загрузить движок трансляций",
                            "Похоже, пропал интернет. Проверьте подключение и нажмите «Повторить».")
        case .rateLimited:
            return AppError(.imagePullFailed, "Сервер загрузки временно занят",
                            "Сервер ограничил количество загрузок. Подождите 15–30 минут и нажмите «Повторить».")
        case .diskFull:
            return diskFull(needGB: 2)
        case .platformUnsupported, .other:
            return AppError(.imagePullFailed, "Не удалось загрузить движок трансляций",
                            "Попробуйте ещё раз через пару минут.")
        }
    }

    static let engineStartFailed = AppError(.engineStartFailed, "Движок трансляций не запустился",
                                            "Нажмите «Повторить». Обычно это помогает.")

    static let engineNotResponding = AppError(.engineNotResponding, "Движок трансляций не отвечает",
                                              "Нажмите «Повторить». Если не поможет — закройте приложение и откройте его снова.")

    static let engineCrashed = AppError(.engineCrashed, "Движок трансляций неожиданно остановился",
                                        "Нажмите «Повторить».")

    static let streamNotFound = AppError(.streamNotFound, "Трансляция не найдена",
                                         "Ссылка устарела или трансляция сейчас не идёт. Проверьте ссылку или попробуйте другую.")

    static let streamNoPeers = AppError(.streamNoPeers, "Трансляция не запускается",
                                        "Не удалось найти источники видео. Возможно, трансляция ещё не началась или уже закончилась. Попробуйте позже или другую ссылку.")

    static let streamInterrupted = AppError(.streamInterrupted, "Трансляция прервалась",
                                            "Движок трансляций остановился во время просмотра. Нажмите «Повторить», чтобы продолжить.")

    static let playerMissing = AppError(.playerMissing, "Видеоплеер не найден",
                                        "Плеер IINA не установлен или был удалён. Приложение может установить его заново.",
                                        recovery: .setup)

    static func playerLaunchFailed(_ detail: String) -> AppError {
        AppError(.playerLaunchFailed, "Не удалось открыть плеер",
                 "IINA не запустилась. Нажмите «Повторить». Если не поможет — переустановите компоненты в меню «Справка».")
    }

    static let installCancelled = AppError(.installCancelled, "Установка не завершена",
                                           "Для установки нужен пароль от этого Mac. Нажмите «Повторить» и введите его в окне macOS.")

    static func installFailed(component: String, detail: String) -> AppError {
        AppError(.installFailed, "Не удалось установить \(component)",
                 "Причина: \(detail). Нажмите «Повторить».")
    }

    static func downloadFailed(component: String) -> AppError {
        AppError(.downloadFailed, "Не удалось скачать \(component)",
                 "Проверьте подключение к интернету и нажмите «Повторить».")
    }

    static func unexpected(_ detail: String) -> AppError {
        AppError(.unexpected, "Что-то пошло не так", "Нажмите «Повторить». Подробности: \(detail)")
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
