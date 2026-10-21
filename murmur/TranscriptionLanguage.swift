import Foundation
import Speech

nonisolated enum TranscriptionLanguage {
    private static let localeKey = "transcriptionLocale"
    static let defaultLocale = Locale(identifier: "en_US")

    static var selected: Locale {
        get {
            guard let identifier = UserDefaults.standard.string(forKey: localeKey) else {
                return defaultLocale
            }
            return Locale(identifier: identifier)
        }
        set {
            UserDefaults.standard.set(newValue.identifier, forKey: localeKey)
        }
    }

    /// Languages the on-device speech model can transcribe, sorted by name.
    static func supported() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
            .sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending }
    }

    static func title(for locale: Locale) -> String {
        // Swiss German speech uses de-CH, which transcribes into Standard German (no dialect model exists).
        return Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func matches(_ lhs: Locale, _ rhs: Locale) -> Bool {
        lhs.identifier(.bcp47) == rhs.identifier(.bcp47)
    }
}
