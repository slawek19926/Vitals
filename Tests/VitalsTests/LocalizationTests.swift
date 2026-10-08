import XCTest
@testable import Vitals

final class LocalizationTests: XCTestCase {
    func testLanguagePreferencesRemainCompatible() {
        XCTAssertEqual(AppLanguage.system.rawValue, 0)
        XCTAssertEqual(AppLanguage.polish.rawValue, 1)
        XCTAssertEqual(AppLanguage.english.rawValue, 2)
        XCTAssertEqual(AppLanguage.simplifiedChinese.rawValue, 3)
        XCTAssertEqual(AppLanguage.simplifiedChinese.title, "简体中文")
    }

    func testSystemLanguageResolution() {
        for identifier in ["zh", "zh-CN", "zh-SG", "zh-Hans", "zh-Hans-CN", "zh-Hans-TW"] {
            XCTAssertEqual(L10n.resolve(.system, preferredLanguages: [identifier]), .simplifiedChinese, identifier)
        }
        for identifier in ["zh-Hant", "zh-Hant-CN", "zh-TW", "zh-HK", "zh-MO", "en-US", "de-DE"] {
            XCTAssertEqual(L10n.resolve(.system, preferredLanguages: [identifier]), .english, identifier)
        }
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["pl-PL"]), .polish)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: []), .english)
        XCTAssertEqual(L10n.resolve(.english, preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(L10n.resolve(.polish, preferredLanguages: ["zh-Hans"]), .polish)
        XCTAssertEqual(L10n.resolve(.simplifiedChinese, preferredLanguages: ["en"]), .simplifiedChinese)
    }

    func testChineseCatalogCoversEveryExistingKeyAndPreservesFormats() throws {
        XCTAssertEqual(Set(L10n.simplifiedChineseTable.keys), Set(L10n.table.keys))
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcsp%]"#)
        func placeholders(_ text: String) -> [String] {
            format.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for (key, english) in L10n.table {
            let chinese = try XCTUnwrap(L10n.simplifiedChineseTable[key], key)
            XCTAssertFalse(chinese.isEmpty, key)
            XCTAssertEqual(placeholders(chinese), placeholders(english), key)
            XCTAssertEqual(chinese.filter { $0 == "\n" }.count, english.filter { $0 == "\n" }.count, key)
        }
        let text = String(format: L10n.t("Aplikacja oraz %d plików powiązanych (%@) zostaną przeniesione do Kosza. Możesz je przywrócić z Kosza.", language: .simplifiedChinese), 3, "12 MB")
        XCTAssertTrue(text.contains("3 个关联文件（12 MB）"))
    }

    func testTranslationsAndUnknownKeyFallback() {
        XCTAssertEqual(L10n.t("Podsumowanie", language: .simplifiedChinese), "概览")
        XCTAssertEqual(L10n.t("Podsumowanie", language: .english), "Summary")
        XCTAssertEqual(L10n.t("Podsumowanie", language: .polish), "Podsumowanie")
        for language in [AppLanguage.polish, .english, .simplifiedChinese] {
            XCTAssertEqual(L10n.t("unknown-key", language: language), "unknown-key")
        }
    }

    func testSwitchingLanguageRefreshesSidebarCSVAndQuantities() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "language")
        defer {
            if let previous { defaults.set(previous, forKey: "language") }
            else { defaults.removeObject(forKey: "language") }
        }
        for (language, summary, separator) in [(AppLanguage.english, "Summary", ","), (.polish, "Podsumowanie", ";"), (.simplifiedChinese, "概览", ",")] {
            defaults.set(language.rawValue, forKey: "language")
            XCTAssertEqual(L("Podsumowanie"), summary)
            guard case let .item(first) = SidebarViewController.staticRows[0] else { return XCTFail("Missing summary row") }
            XCTAssertEqual(first.title, summary)
            XCTAssertEqual(HistoryExport.Format.current.separator, separator)
            XCTAssertEqual(HistoryExport.Format.current.decimalComma, language == .polish)
        }
        for count in [1, 2, 5, 12, 22] {
            XCTAssertEqual(ConnectionPresentation.quantity(count, one: "proces", few: "procesy", many: "procesów"), "\(count) " + (count == 1 ? "进程" : "个进程"))
        }
    }

    func testQuickActionIsFoundAcrossLanguages() throws {
        let fm = FileManager.default
        let services = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: services) }
        XCTAssertNil(QuickAction.installedURL(in: services))
        for language in [AppLanguage.polish, .english, .simplifiedChinese] {
            let url = services.appendingPathComponent(L10n.t("Pokaż Vitals", language: language) + ".workflow", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertEqual(QuickAction.installedURL(in: services), url)
            try fm.removeItem(at: url)
        }
    }
}
