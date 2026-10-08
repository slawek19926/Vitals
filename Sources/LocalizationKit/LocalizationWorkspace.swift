import Foundation

public struct LocalizationWorkspace {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> LocalizationCatalog { try .load(from: directory) }

    private func encoded(_ configuration: LanguageConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(contentsOf: "\n".utf8)
        return data
    }

    /// New languages stay hidden until their translations pass validation.
    @discardableResult
    public func addLanguage(code: String, nativeName: String, matches: [String]? = nil,
                            prefersSystemFont: Bool = false) throws -> LanguageDefinition {
        var configuration = try load().configuration
        guard !configuration.languages.contains(where: { $0.code == code }) else {
            throw CatalogError("Language already exists: \(code)")
        }
        let definition = LanguageDefinition(id: max(3, configuration.languages.map(\.id).max() ?? 0) + 1,
                                            code: code, nativeName: nativeName, matches: matches,
                                            enabled: false, prefersSystemFont: prefersSystemFont)
        configuration.languages.append(definition)
        let csvURL = directory.appendingPathComponent("translations.csv")
        let originalCSV = try String(contentsOf: csvURL, encoding: .utf8)
        var rows = try CSV.parse(originalCSV).filter { !$0.allSatisfy(\.isEmpty) }
        let column = rows[0].firstIndex(of: "legacy_key")!
        for index in rows.indices { rows[index].insert(index == 0 ? code : "", at: column) }
        let csv = CSV.encode(rows)
        let data = try encoded(configuration)
        _ = try LocalizationCatalog(configurationData: data, csvText: csv)
        let configurationURL = directory.appendingPathComponent("languages.json")
        let originalConfiguration = try Data(contentsOf: configurationURL)
        try data.write(to: configurationURL, options: .atomic)
        do { try csv.write(to: csvURL, atomically: true, encoding: .utf8) }
        catch {
            try? originalConfiguration.write(to: configurationURL, options: .atomic)
            throw error
        }
        return definition
    }

    public func enableLanguage(code: String) throws {
        var configuration = try load().configuration
        guard let index = configuration.languages.firstIndex(where: { $0.code == code }) else {
            throw CatalogError("Unknown language: \(code)")
        }
        configuration.languages[index].enabled = true
        let data = try encoded(configuration)
        let csv = try String(contentsOf: directory.appendingPathComponent("translations.csv"), encoding: .utf8)
        _ = try LocalizationCatalog(configurationData: data, csvText: csv)
        try data.write(to: directory.appendingPathComponent("languages.json"), options: .atomic)
    }

    public func package(into app: URL) throws {
        let catalog = try load()
        try catalog.validatePrivacyDescriptions()
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "APPL" else {
            throw CatalogError("Expected an app bundle at \(app.path)")
        }
        info["CFBundleDevelopmentRegion"] = catalog.configuration.developmentLanguage
        info["CFBundleLocalizations"] = catalog.languages.map(\.code)
        for (id, key) in LocalizationCatalog.privacyKeys {
            info[key] = catalog.text(id, languageCode: catalog.configuration.developmentLanguage)
        }
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        for language in catalog.languages {
            let localized = resources.appendingPathComponent(language.code + ".lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
            let strings = LocalizationCatalog.privacyKeys.sorted { $0.value < $1.value }.map { id, key in
                "\(Self.quoted(key)) = \(Self.quoted(catalog.text(id, languageCode: language.code)));"
            }.joined(separator: "\n") + "\n"
            try strings.write(to: localized.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
