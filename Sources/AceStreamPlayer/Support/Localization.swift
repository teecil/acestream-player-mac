import Foundation

/// The app speaks English or Russian. The choice is made on first launch and can be
/// changed later from the app menu.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    /// Name shown in the language picker (always in its own language).
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    /// Two-letter label for the compact switch in the window header.
    var shortCode: String {
        switch self {
        case .english: return "EN"
        case .russian: return "RU"
        }
    }

    /// The language to highlight in the picker, guessed from the Mac's settings.
    static var systemGuess: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let slavic = ["ru", "uk", "be", "kk"]
        return slavic.contains(where: { preferred.hasPrefix($0) }) ? .russian : .english
    }
}

enum L10n {
    /// Current UI language. English until the user picks one.
    static var current: AppLanguage = Prefs.language ?? .english
}

/// Returns the string for the current UI language.
func tr(_ english: String, _ russian: String) -> String {
    L10n.current == .russian ? russian : english
}
