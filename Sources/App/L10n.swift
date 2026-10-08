// L10n.swift - CSV catalog, dynamic language registry and legacy source-key compatibility.
import Foundation
import LocalizationKit

struct AppLanguage: RawRepresentable, CaseIterable, Hashable {
    let rawValue: Int
    private init(knownID: Int) { rawValue = knownID }
    init?(rawValue: Int) {
        guard rawValue == 0 || L10n.catalog.languages.contains(where: { $0.id == rawValue }) else { return nil }
        self.rawValue = rawValue
    }

    // These persisted IDs are kept compatible with all previous Vitals versions.
    static let system = AppLanguage(knownID: 0)
    static let polish = AppLanguage(knownID: 1)
    static let english = AppLanguage(knownID: 2)
    static let simplifiedChinese = AppLanguage(knownID: 3)
    static var allCases: [AppLanguage] { [.system] + L10n.catalog.languages.map { AppLanguage(knownID: $0.id) } }

    private var definition: LanguageDefinition? {
        L10n.catalog.configuration.languages.first { $0.id == rawValue }
    }
    var code: String { definition?.code ?? L10n.catalog.configuration.developmentLanguage }
    var title: String { self == .system ? L("language.system") : (definition?.nativeName ?? "English") }
    var prefersSystemFont: Bool { definition?.prefersSystemFont ?? false }
    var pluralRule: LocalizationPluralRule { definition?.pluralRule ?? .oneOther }
    var csvSeparator: String { definition?.csvSeparator ?? "," }
    var decimalComma: Bool { definition?.decimalComma ?? false }
}

enum L10n {
    static let catalogDirectory: URL = {
        // Packaged apps use their embedded resource bundle; SwiftPM tests/CLI use Bundle.module.
        let packaged = Bundle.main.url(forResource: "Vitals_Vitals", withExtension: "bundle").flatMap(Bundle.init(url:))
        let bundle = packaged ?? Bundle.module
        return bundle.resourceURL!.appendingPathComponent("Localization", isDirectory: true)
    }()

    static let catalog: LocalizationCatalog = {
        do { return try LocalizationCatalog.load(from: catalogDirectory) }
        catch {
            NSLog("Vitals localization catalog: %@", error.localizedDescription)
            return .empty
        }
    }()

    static var language: AppLanguage { AppLanguage(rawValue: Prefs.shared.language) ?? .system }
    static var resolvedLanguage: AppLanguage { resolve(language, preferredLanguages: Locale.preferredLanguages) }

    static func resolve(_ language: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        guard language == .system else { return language }
        return AppLanguage(rawValue: catalog.resolve(preferredLanguages: preferredLanguages).id) ?? .english
    }

    static func t(_ key: String, language: AppLanguage = resolvedLanguage) -> String {
        let resolved = language == .system ? resolvedLanguage : language
        return catalog.text(key, languageCode: resolved.code)
    }
}

/// Accepts stable catalog IDs and the historical Polish source strings.
func L(_ key: String) -> String { L10n.t(key) }
