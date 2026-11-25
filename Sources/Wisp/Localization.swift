import Foundation

/// The interface is in Russian or English. macOS chooses between the bundle's ru.lproj and en.lproj
/// from the user's preferred languages, including a per-app choice in System Settings → General →
/// Language & Region. Any other language gets English.
enum Language {
    static let isRussian: Bool = {
        let chosen = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return chosen.hasPrefix("ru")
    }()
}

/// Returns the Russian or the English text, whichever the interface uses.
func tr(_ russian: String, _ english: String) -> String {
    Language.isRussian ? russian : english
}
