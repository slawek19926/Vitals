import XCTest
import LocalizationKit

final class LocalizationCatalogTests: XCTestCase {
    private let english = LanguageDefinition(id: 2, code: "en", nativeName: "English")

    private func catalog(languages: [LanguageDefinition], rows: [[String]]) throws -> LocalizationCatalog {
        let configuration = LanguageConfiguration(languages: languages)
        let header = ["id"] + languages.map(\.code) + ["legacy_key"]
        return try LocalizationCatalog(configurationData: JSONEncoder().encode(configuration),
                                       csvText: CSV.encode([header] + rows))
    }

    func testCSVHandlesBOMUnicodeQuotesCRLFAndMultilineCells() throws {
        let input = "\u{FEFF}id,en,zh-Hans\r\nitem,\"A, \"\"quoted\"\" value\nnext line\",中文\r\n"
        let rows = try CSV.parse(input)
        XCTAssertEqual(rows, [["id", "en", "zh-Hans"], ["item", "A, \"quoted\" value\nnext line", "中文"]])
        XCTAssertEqual(try CSV.parse(CSV.encode(rows)), rows)
        let spaces = [["id", "text"], ["status", "Status: "], ["indented", " leading"]]
        XCTAssertEqual(try CSV.parse(CSV.encode(spaces)), spaces)
        XCTAssertEqual(try CSV.parse("a,b,\r\n"), [["a", "b", ""]])
    }

    func testMalformedCSVIsRejectedInsteadOfShiftingColumns() {
        for csv in ["a,\"unclosed", "a,\"closed\"extra", "un\"quoted,b"] {
            XCTAssertThrowsError(try CSV.parse(csv), csv)
        }
    }

    func testStableIDsAndLegacyAliasesSurvivePolishTextEdits() throws {
        let pl = LanguageDefinition(id: 1, code: "pl", nativeName: "Polski")
        let value = try catalog(languages: [english, pl],
                                rows: [["page.summary", "Summary", "Nowe podsumowanie", "Podsumowanie"]])
        XCTAssertEqual(value.text("page.summary", languageCode: "pl"), "Nowe podsumowanie")
        XCTAssertEqual(value.text("Podsumowanie", languageCode: "pl"), "Nowe podsumowanie")
        XCTAssertEqual(value.text("Podsumowanie", languageCode: "en"), "Summary")
        XCTAssertEqual(value.text("unknown source", languageCode: "de"), "unknown source")
    }

    func testDuplicateIDsAndAliasesAreRejected() {
        XCTAssertThrowsError(try catalog(languages: [english], rows: [
            ["page.summary", "Summary", "Podsumowanie"], ["page.summary", "Other", "Inne"]
        ]))
        XCTAssertThrowsError(try catalog(languages: [english], rows: [
            ["page.summary", "Summary", "Podsumowanie"], ["page.other", "Other", "Podsumowanie"]
        ]))
    }

    func testEnabledLanguagesRequireCompleteTranslationsAndSafeFormats() {
        let de = LanguageDefinition(id: 4, code: "de", nativeName: "Deutsch")
        XCTAssertThrowsError(try catalog(languages: [english, de], rows: [["message.count", "%d files", "", ""]]))
        XCTAssertThrowsError(try catalog(languages: [english, de], rows: [["message.count", "%d files", "%@ Dateien", ""]]))
        XCTAssertThrowsError(try catalog(languages: [english, de], rows: [["message.count", "A\nB", "AB", ""]]))
    }

    func testPercentSignsInOrdinaryLabelsAreNotFormatArguments() throws {
        let pl = LanguageDefinition(id: 1, code: "pl", nativeName: "Polski")
        XCTAssertNoThrow(try catalog(languages: [english, pl],
            rows: [["label.utilization", "% utilization", "% wykorzystania", ""]]))
    }

    func testPositionalParametersCanBeReorderedWithoutChangingArgumentTypes() throws {
        let de = LanguageDefinition(id: 4, code: "de", nativeName: "Deutsch")
        let value = try catalog(languages: [english, de],
                                rows: [["message.count", "%@ has %d files", "%2$d Dateien: %1$@", ""]])
        XCTAssertEqual(String(format: value.text("message.count", languageCode: "de"), "Vitals", 3), "3 Dateien: Vitals")
        XCTAssertThrowsError(try catalog(languages: [english, de],
                                         rows: [["message.count", "%@ has %d files", "%1$d Dateien: %2$@", ""]]))
    }

    func testDraftLanguageFallsBackToEnglishAndIsNotSelectedBySystem() throws {
        let de = LanguageDefinition(id: 7, code: "de", nativeName: "Deutsch", enabled: false)
        let value = try catalog(languages: [english, de], rows: [["page.summary", "Summary", "", "Podsumowanie"]])
        XCTAssertEqual(value.languages.map(\.code), ["en"])
        XCTAssertEqual(value.text("page.summary", languageCode: "de"), "Summary")
        XCTAssertEqual(value.resolve(preferredLanguages: ["de-DE"]).code, "en")
        XCTAssertEqual(value.missingTranslations(for: "de"), ["page.summary"])
    }

    func testLanguageRegistryResolvesNewLanguagesWithoutAnEnumCase() throws {
        let de = LanguageDefinition(id: 7, code: "de", nativeName: "Deutsch")
        let hans = LanguageDefinition(id: 3, code: "zh-Hans", nativeName: "简体中文")
        let hant = LanguageDefinition(id: 8, code: "zh-Hant", nativeName: "繁體中文")
        let value = try catalog(languages: [english, de, hans, hant],
                                rows: [["page.summary", "Summary", "Übersicht", "概览", "概覽", "Podsumowanie"]])
        for (preferences, code) in [
            (["de-DE"], "de"), (["fr-FR", "de-DE"], "de"),
            (["zh-TW"], "zh-Hant"), (["zh-Hant-CN"], "zh-Hant"), (["zh-Hans-TW"], "zh-Hans")
        ] {
            XCTAssertEqual(value.resolve(preferredLanguages: preferences).code, code)
        }
        XCTAssertEqual(value.languages.first { $0.code == "de" }?.id, 7)
    }

    func testSpecificRegionMatchesTakePrecedenceOverGenericLanguage() throws {
        let pt = LanguageDefinition(id: 4, code: "pt", nativeName: "Português")
        let br = LanguageDefinition(id: 5, code: "pt-BR", nativeName: "Português (Brasil)")
        let value = try catalog(languages: [english, pt, br],
                                rows: [["page.summary", "Summary", "Resumo", "Resumo", ""]])
        XCTAssertEqual(value.resolve(preferredLanguages: ["pt-BR"]).code, "pt-BR")
        XCTAssertEqual(value.resolve(preferredLanguages: ["pt-PT"]).code, "pt")
    }

    func testLanguagePreferenceIDsCannotBeReused() {
        let de = LanguageDefinition(id: 3, code: "de", nativeName: "Deutsch")
        XCTAssertThrowsError(try catalog(languages: [english, de], rows: [["page.summary", "Summary", "Übersicht", ""]]))
    }

    private func withWorkspace(_ body: (LocalizationWorkspace) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let configuration = LanguageConfiguration(languages: [english])
        try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("languages.json"))
        try CSV.encode([
            ["id", "en", "legacy_key"],
            ["page.summary", "Summary", "Podsumowanie"],
            ["action.show_vitals", "Show Vitals", "Pokaż Vitals"],
            ["privacy.location_usage", "Location access", ""],
            ["privacy.bluetooth_usage", "Bluetooth scanning", ""]
        ]).write(to: root.appendingPathComponent("translations.csv"), atomically: true, encoding: .utf8)
        try body(LocalizationWorkspace(directory: root))
    }

    private func fillGerman(_ workspace: LocalizationWorkspace) throws {
        let url = workspace.directory.appendingPathComponent("translations.csv")
        var rows = try CSV.parse(String(contentsOf: url, encoding: .utf8))
        let column = try XCTUnwrap(rows[0].firstIndex(of: "de"))
        let texts = ["page.summary": "Übersicht", "action.show_vitals": "Vitals anzeigen",
                     "privacy.location_usage": "Standortzugriff", "privacy.bluetooth_usage": "Bluetooth-Suche"]
        for index in rows.indices.dropFirst() { rows[index][column] = texts[rows[index][0]]! }
        try CSV.encode(rows).write(to: url, atomically: true, encoding: .utf8)
    }

    func testLanguageTemplateStaysHiddenUntilCompleteAndValidated() throws {
        try withWorkspace { workspace in
            let added = try workspace.addLanguage(code: "de", nativeName: "Deutsch")
            XCTAssertEqual(added.id, 4)
            XCTAssertFalse(added.enabled)
            XCTAssertEqual(try workspace.load().missingTranslations(for: "de").count, 4)
            XCTAssertThrowsError(try workspace.enableLanguage(code: "de"))
            XCTAssertFalse(try workspace.load().configuration.languages.first { $0.code == "de" }!.enabled)
            try fillGerman(workspace)
            try workspace.enableLanguage(code: "de")
            let complete = try workspace.load()
            XCTAssertEqual(complete.resolve(preferredLanguages: ["de-DE"]).code, "de")
            XCTAssertEqual(complete.text("page.summary", languageCode: "de"), "Übersicht")
            XCTAssertThrowsError(try workspace.addLanguage(code: "de", nativeName: "Deutsch"))
        }
    }

    func testPackagingIncludesAllEnabledLanguagesAndPrivacyDescriptions() throws {
        try withWorkspace { workspace in
            try workspace.addLanguage(code: "de", nativeName: "Deutsch")
            try fillGerman(workspace)
            try workspace.enableLanguage(code: "de")
            let app = workspace.directory.appendingPathComponent("Test.app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL"], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try workspace.package(into: app)
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: contents.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
            XCTAssertEqual(info?["CFBundleDevelopmentRegion"] as? String, "en")
            XCTAssertEqual(info?["CFBundleLocalizations"] as? [String], ["en", "de"])
            XCTAssertEqual(info?["NSBluetoothAlwaysUsageDescription"] as? String, "Bluetooth scanning")
            let german = try String(contentsOf: contents.appendingPathComponent("Resources/de.lproj/InfoPlist.strings"), encoding: .utf8)
            XCTAssertTrue(german.contains("Standortzugriff"))
            XCTAssertTrue(german.contains("Bluetooth-Suche"))
        }
    }
}
