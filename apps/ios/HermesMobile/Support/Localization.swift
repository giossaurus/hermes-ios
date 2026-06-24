import Foundation
import SwiftUI
import ObjectiveC

// MARK: - In-app UI language

/// Controls the UI language at runtime. Persists the user's choice and swaps the
/// strings table `Bundle.main` resolves against, so every `Text("…")` /
/// `String(localized:)` re-renders in the chosen language WITHOUT an app restart
/// (the standard reclass-`Bundle.main` technique). SwiftUI re-resolves the tree
/// because the app root also publishes ``locale`` into `\.locale`.
@Observable
@MainActor
final class LocalizationManager {
    enum Language: String, CaseIterable, Identifiable {
        /// Follow the device's preferred language.
        case system
        case english = "en"
        case portuguese = "pt-BR"

        var id: String { rawValue }

        /// The `.lproj` resource code to load, or `nil` to follow the system.
        var bundleCode: String? {
            switch self {
            case .system: return nil
            case .english: return "en"
            case .portuguese: return "pt-BR"
            }
        }

        /// Label shown in the picker. The English/Portuguese names are written in
        /// their own language (endonyms) so each is recognizable regardless of the
        /// current UI language; "System" is itself localized.
        var displayName: String {
            switch self {
            case .system: return String(localized: "language.system", defaultValue: "System")
            case .english: return "English"
            case .portuguese: return "Português"
            }
        }
    }

    private static let storageKey = "hermes.uiLanguage"

    private(set) var language: Language {
        didSet { apply() }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        language = raw.flatMap(Language.init(rawValue:)) ?? .system
        apply()
    }

    /// The resolved locale for SwiftUI's `\.locale` (drives formatters AND forces
    /// `Text` to re-resolve when the choice changes).
    var locale: Locale {
        switch language {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .portuguese: return Locale(identifier: "pt-BR")
        }
    }

    func setLanguage(_ newValue: Language) {
        guard newValue != language else { return }
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.storageKey)
        language = newValue
    }

    private func apply() {
        Bundle.setAppLanguage(language.bundleCode)
    }
}

// MARK: - Bundle reclass (runtime language swap)

// Opaque identity used only as the associated-object key address; never read or
// mutated as a value, so `nonisolated(unsafe)` is correct under strict concurrency.
nonisolated(unsafe) private var languageBundleKey: UInt8 = 0

/// A `Bundle` whose localized-string lookups are redirected to a chosen
/// `<code>.lproj` sub-bundle. Installed onto `Bundle.main` so every
/// `Text`/`String(localized:)` resolves in the user-selected UI language.
private final class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let sub = objc_getAssociatedObject(self, &languageBundleKey) as? Bundle {
            return sub.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Point `Bundle.main`'s string lookups at `<code>.lproj`; pass `nil` to
    /// restore the system default. Reclasses `Bundle.main` once, idempotently.
    static func setAppLanguage(_ code: String?) {
        if !(Bundle.main is LanguageBundle) {
            object_setClass(Bundle.main, LanguageBundle.self)
        }
        let sub = code
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap { Bundle(path: $0) }
        objc_setAssociatedObject(
            Bundle.main, &languageBundleKey, sub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
