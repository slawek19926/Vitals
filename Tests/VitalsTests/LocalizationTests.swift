import XCTest
import LocalizationKit
@testable import Vitals

final class LocalizationTests: XCTestCase {
    func testLanguagePreferencesRemainCompatible() {
        XCTAssertEqual(AppLanguage.system.rawValue, 0)
        XCTAssertEqual(AppLanguage.polish.rawValue, 1)
        XCTAssertEqual(AppLanguage.english.rawValue, 2)
        XCTAssertEqual(AppLanguage.simplifiedChinese.rawValue, 3)
        XCTAssertEqual(AppLanguage.simplifiedChinese.title, "简体中文")
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertNil(AppLanguage(rawValue: 999))
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

    func testSystemLanguageResolutionSkipsUnsupportedPreferencesInOrder() {
        let cases: [([String], AppLanguage)] = [
            (["de-DE", "zh-Hans"], .simplifiedChinese),
            (["fr-FR", "pl-PL"], .polish),
            (["de-DE", "en-US"], .english),
            (["zh-Hant", "en-US"], .english),
            (["zh-TW", "zh-CN"], .simplifiedChinese),
            (["zh-HK", "zh-MO", "pl"], .polish),
            (["zh-Hant-CN", "zh-SG"], .simplifiedChinese),
            (["zh-Latn", "pl_PL"], .polish),
            (["ZH_hans_CN", "pl-PL"], .simplifiedChinese),
            (["en-GB", "pl-PL", "zh-CN"], .english),
            (["pl-PL", "en-US"], .polish),
            (["de-DE", "fr-FR", "zh-Hant"], .english),
            ([], .english)
        ]
        for (preferred, expected) in cases {
            XCTAssertEqual(L10n.resolve(.system, preferredLanguages: preferred), expected, "\(preferred)")
        }
    }

    func testExplicitLanguageChoicesIgnoreSystemPreferences() {
        for language in [AppLanguage.polish, .english, .simplifiedChinese] {
            for preferred in [[], ["de-DE", "zh-Hant"], ["en-US", "pl-PL", "zh-CN"]] {
                XCTAssertEqual(L10n.resolve(language, preferredLanguages: preferred), language)
            }
        }
    }

    func testBundledCatalogCoversEveryEnabledLanguageAndPreservesFormats() throws {
        let catalog = L10n.catalog
        XCTAssertFalse(catalog.messages.isEmpty)
        XCTAssertEqual(catalog.languages.map(\.code), ["pl", "en", "zh-Hans"])
        XCTAssertTrue(catalog.validationIssues().isEmpty)
        XCTAssertNoThrow(try catalog.validatePrivacyDescriptions())
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcsp%]"#)
        func placeholders(_ text: String) -> [String] {
            format.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for message in catalog.messages {
            let english = try XCTUnwrap(message.translations["en"], message.id)
            for language in catalog.languages {
                let translation = try XCTUnwrap(message.translations[language.code], message.id)
                XCTAssertFalse(translation.isEmpty, message.id)
                XCTAssertEqual(placeholders(translation), placeholders(english), message.id)
            }
        }
        let text = String(format: L10n.t("Aplikacja oraz %d plików powiązanych (%@) zostaną przeniesione do Kosza. Możesz je przywrócić z Kosza.", language: .simplifiedChinese), 3, "12 MB")
        XCTAssertTrue(text.contains("3 个关联文件（12 MB）"))
    }

    func testTranslationsAndUnknownKeyFallback() {
        XCTAssertEqual(L10n.t("Podsumowanie", language: .simplifiedChinese), "概览")
        XCTAssertEqual(L10n.t("Podsumowanie", language: .english), "Summary")
        XCTAssertEqual(L10n.t("Podsumowanie", language: .polish), "Podsumowanie")
        for language in [AppLanguage.polish, .english, .simplifiedChinese] {
            XCTAssertEqual(L10n.t("page.summary", language: language), L10n.t("Podsumowanie", language: language))
            XCTAssertEqual(L10n.t("unknown-key", language: language), "unknown-key")
        }
    }

    func testLanguageMetadataPreservesFormattingAndFontBehavior() {
        XCTAssertEqual(AppLanguage.polish.pluralRule, .polish)
        XCTAssertEqual(AppLanguage.english.pluralRule, .oneOther)
        XCTAssertEqual(AppLanguage.polish.csvSeparator, ";")
        XCTAssertTrue(AppLanguage.polish.decimalComma)
        XCTAssertEqual(AppLanguage.simplifiedChinese.csvSeparator, ",")
        XCTAssertTrue(AppLanguage.simplifiedChinese.prefersSystemFont)
        XCTAssertFalse(AppLanguage.english.prefersSystemFont)
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

}
