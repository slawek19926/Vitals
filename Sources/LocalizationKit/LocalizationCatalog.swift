import Foundation

public enum LocalizationPluralRule: String, Codable {
    case oneOther, polish
}

public struct LanguageDefinition: Codable, Equatable {
    public var id: Int
    public var code: String
    public var nativeName: String
    public var matches: [String]
    public var enabled: Bool
    public var prefersSystemFont: Bool
    public var pluralRule: LocalizationPluralRule
    public var csvSeparator: String
    public var decimalComma: Bool

    public init(id: Int, code: String, nativeName: String, matches: [String]? = nil,
                enabled: Bool = true, prefersSystemFont: Bool = false,
                pluralRule: LocalizationPluralRule = .oneOther, csvSeparator: String = ",",
                decimalComma: Bool = false) {
        self.id = id; self.code = code; self.nativeName = nativeName
        self.matches = matches ?? [code]; self.enabled = enabled
        self.prefersSystemFont = prefersSystemFont; self.pluralRule = pluralRule
        self.csvSeparator = csvSeparator; self.decimalComma = decimalComma
    }
}

public struct LanguageConfiguration: Codable {
    public var schemaVersion: Int
    public var developmentLanguage: String
    public var languages: [LanguageDefinition]

    public init(developmentLanguage: String = "en", languages: [LanguageDefinition]) {
        schemaVersion = 1; self.developmentLanguage = developmentLanguage; self.languages = languages
    }
}

public struct LocalizationMessage {
    public let id: String
    public let legacyKey: String
    public let translations: [String: String]
}

public struct CatalogError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct LocalizationCatalog {
    public let configuration: LanguageConfiguration
    public let messages: [LocalizationMessage]
    private let byID: [String: LocalizationMessage]
    private let aliases: [String: String]
    public let languages: [LanguageDefinition]

    public init(configurationData: Data, csvText: String) throws {
        let configuration = try JSONDecoder().decode(LanguageConfiguration.self, from: configurationData)
        guard configuration.schemaVersion == 1 else { throw CatalogError("Unsupported localization schema version") }
        var codes = Set<String>(), ids = Set<Int>()
        let reserved = ["pl": 1, "en": 2, "zh-Hans": 3]
        for language in configuration.languages {
            guard language.id > 0, ids.insert(language.id).inserted,
                  codes.insert(language.code).inserted,
                  language.code.range(of: #"^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil,
                  !language.nativeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !language.matches.isEmpty,
                  [",", ";", "\t"].contains(language.csvSeparator) else {
                throw CatalogError("Invalid or duplicate language definition: \(language.code)")
            }
            if let id = reserved[language.code], id != language.id {
                throw CatalogError("Keep stored preference ID \(id) for \(language.code)")
            }
            if reserved.values.contains(language.id), reserved[language.code] != language.id {
                throw CatalogError("Language preference IDs 1–3 are reserved for pl, en and zh-Hans")
            }
            for pattern in language.matches {
                guard pattern.range(of: #"^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                    throw CatalogError("Invalid locale match \(pattern) for \(language.code)")
                }
            }
        }
        guard configuration.developmentLanguage == "en",
              configuration.languages.contains(where: { $0.code == "en" && $0.enabled }) else {
            throw CatalogError("English must remain the enabled development/fallback language")
        }
        let rows = try CSV.parse(csvText)
        guard let header = rows.first, Set(header).count == header.count,
              let idColumn = header.firstIndex(of: "id"),
              let legacyColumn = header.firstIndex(of: "legacy_key"),
              Set(header.filter { !["id", "legacy_key"].contains($0) }) == codes else {
            throw CatalogError("CSV must contain id, legacy_key and exactly the configured language columns")
        }
        var messages: [LocalizationMessage] = []
        var messageIDs = Set<String>(), aliases: [String: String] = [:]
        for (offset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy(\.isEmpty) { continue }
            guard row.count == header.count else { throw CatalogError("CSV row \(offset + 2): wrong number of columns") }
            let id = row[idColumn]
            guard id.range(of: #"^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil,
                  messageIDs.insert(id).inserted else {
                throw CatalogError("Invalid or duplicate message ID: \(id)")
            }
            let legacy = row[legacyColumn]
            if !legacy.isEmpty {
                guard aliases[legacy] == nil else { throw CatalogError("Duplicate legacy key: \(legacy)") }
                aliases[legacy] = id
            }
            var translations: [String: String] = [:]
            for (column, code) in header.enumerated() where codes.contains(code) {
                translations[code] = row[column]
            }
            messages.append(LocalizationMessage(id: id, legacyKey: legacy, translations: translations))
        }
        guard !messages.isEmpty else { throw CatalogError("The localization catalog is empty") }
        for (alias, id) in aliases where messageIDs.contains(alias) && alias != id {
            throw CatalogError("Legacy key conflicts with a message ID: \(alias)")
        }
        self.configuration = configuration; self.messages = messages
        self.languages = configuration.languages.filter(\.enabled).sorted { $0.id < $1.id }
        self.byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        self.aliases = aliases
        let issues = validationIssues()
        guard issues.isEmpty else { throw CatalogError(issues.joined(separator: "\n")) }
    }

    private init(configuration: LanguageConfiguration, messages: [LocalizationMessage]) {
        self.configuration = configuration; self.messages = messages
        self.languages = configuration.languages.filter(\.enabled).sorted { $0.id < $1.id }
        byID = [:]; aliases = [:]
    }

    /// Keep UI source strings readable if a damaged bundle loses its catalog.
    public static var empty: LocalizationCatalog {
        LocalizationCatalog(configuration: LanguageConfiguration(languages: [
            LanguageDefinition(id: 2, code: "en", nativeName: "English")
        ]), messages: [])
    }

    public static func load(from directory: URL) throws -> LocalizationCatalog {
        try LocalizationCatalog(
            configurationData: Data(contentsOf: directory.appendingPathComponent("languages.json")),
            csvText: String(contentsOf: directory.appendingPathComponent("translations.csv"), encoding: .utf8))
    }

    public func text(_ key: String, languageCode: String) -> String {
        guard let message = byID[key] ?? aliases[key].flatMap({ byID[$0] }) else { return key }
        if let value = message.translations[languageCode], !value.isEmpty { return value }
        if let fallback = message.translations[configuration.developmentLanguage], !fallback.isEmpty { return fallback }
        return message.legacyKey.isEmpty ? key : message.legacyKey
    }

    public func missingTranslations(for code: String) -> [String] {
        messages.filter { ($0.translations[code] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
    }

    public func validationIssues(requireCompleteLanguage: String? = nil) -> [String] {
        var issues: [String] = []
        for message in messages {
            let reference = message.translations[configuration.developmentLanguage] ?? ""
            let referenceSignature = Self.formatSignature(reference)
            for language in configuration.languages {
                let value = message.translations[language.code] ?? ""
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if language.enabled || language.code == requireCompleteLanguage {
                        issues.append("\(message.id) [\(language.code)]: missing translation")
                    }
                    continue
                }
                if Self.formatSignature(value) != referenceSignature {
                    issues.append("\(message.id) [\(language.code)]: format parameters differ from English")
                }
                if value.filter({ $0 == "\n" }).count != reference.filter({ $0 == "\n" }).count {
                    issues.append("\(message.id) [\(language.code)]: paragraph breaks differ from English")
                }
            }
        }
        return issues
    }

    /// Positional parameters allow translators to reorder arguments safely.
    private static let formatExpression = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcsp%]"#)

    private static func formatSignature(_ text: String) -> [String] {
        var next = 1
        return formatExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let token = String(text[Range(match.range, in: text)!])
            if token == "%%" { return "literal-percent" }
            if let range = Range(match.range(at: 1), in: text) {
                let position = String(text[range])
                return position + ":" + token.replacingOccurrences(of: "%\(position)$", with: "%")
            }
            defer { next += 1 }
            return "\(next):\(token)"
        }.sorted()
    }

    public func resolve(preferredLanguages: [String]) -> LanguageDefinition {
        for identifier in preferredLanguages {
            let locale = Locale(identifier: identifier)
            var best: (LanguageDefinition, Int)?
            for language in languages {
                for pattern in language.matches {
                    let parts = pattern.split(separator: "-").map(String.init)
                    guard locale.language.languageCode?.identifier == parts.first else { continue }
                    let script = parts.dropFirst().first { $0.count == 4 }
                    let region = parts.dropFirst().first { $0.count == 2 || $0.count == 3 }
                    if let script, locale.language.script?.identifier.lowercased() != script.lowercased() { continue }
                    if let region, locale.region?.identifier.lowercased() != region.lowercased() { continue }
                    let score = (script == nil ? 0 : 2) + (region == nil ? 0 : 1)
                    if best == nil || score > best!.1 { best = (language, score) }
                }
            }
            if let best { return best.0 }
        }
        return languages.first { $0.code == configuration.developmentLanguage }!
    }

    public static let privacyKeys = [
        "privacy.location_usage": "NSLocationWhenInUseUsageDescription",
        "privacy.bluetooth_usage": "NSBluetoothAlwaysUsageDescription"
    ]

    public func validatePrivacyDescriptions() throws {
        for key in Self.privacyKeys.keys {
            guard byID[key] != nil else { throw CatalogError("Missing privacy description: \(key)") }
        }
    }
}
