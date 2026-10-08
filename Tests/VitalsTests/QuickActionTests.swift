import XCTest
@testable import Vitals

final class QuickActionTests: XCTestCase {
    private let legacyNames = ["Pokaż Vitals", "Show Vitals", "显示 Vitals"]

    private func withServices(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let services = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: services) }
        try body(services)
    }

    private func createLegacyVariants(in services: URL) throws -> [URL] {
        try legacyNames.map { name in
            let url = services.appendingPathComponent(name + ".workflow", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
    }

    func testNoWorkflowsInstalled() throws {
        try withServices { services in
            XCTAssertEqual(QuickAction.installedURLs(in: services), [])
            XCTAssertFalse(QuickAction.isInstalled(in: services))
            XCTAssertNoThrow(try QuickAction.remove(in: services))
        }
    }

    func testEachLegacyLocalizedWorkflowIsDetected() throws {
        try withServices { services in
            for name in legacyNames {
                let url = services.appendingPathComponent(name + ".workflow", isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                XCTAssertEqual(QuickAction.installedURLs(in: services), [url], name)
                XCTAssertTrue(QuickAction.isInstalled(in: services), name)
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func testMultipleLegacyVariantsAreDetectedInStableOrder() throws {
        try withServices { services in
            // Creation order must not determine discovery order.
            for name in legacyNames.reversed() {
                try FileManager.default.createDirectory(
                    at: services.appendingPathComponent(name + ".workflow", isDirectory: true),
                    withIntermediateDirectories: false)
            }
            let expected = legacyNames.map { services.appendingPathComponent($0 + ".workflow", isDirectory: true) }
            XCTAssertEqual(QuickAction.installedURLs(in: services), expected)
            XCTAssertTrue(QuickAction.isInstalled(in: services))
        }
    }

    func testInstallationRemovesLegacyVariantsAndUsesCurrentLanguage() throws {
        for language in [AppLanguage.polish, .english, .simplifiedChinese] {
            try withServices { services in
                _ = try createLegacyVariants(in: services)
                try QuickAction.install(in: services, language: language)
                let title = L10n.t("Pokaż Vitals", language: language)
                let destination = services.appendingPathComponent(title + ".workflow", isDirectory: true)
                XCTAssertEqual(QuickAction.installedURLs(in: services), [destination])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: services.path), [title + ".workflow"])
                let contents = destination.appendingPathComponent("Contents", isDirectory: true)
                let plist = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: contents.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
                let service = (plist?["NSServices"] as? [[String: Any]])?.first
                XCTAssertEqual((service?["NSMenuItem"] as? [String: String])?["default"], title)
                let workflow = try Data(contentsOf: contents.appendingPathComponent("document.wflow"))
                XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: workflow, format: nil))
            }
        }
    }

    func testReinstallingAfterLanguageChangesNeverAccumulatesWorkflows() throws {
        try withServices { services in
            for language in [AppLanguage.polish, .english, .simplifiedChinese, .polish] {
                try QuickAction.install(in: services, language: language)
                let name = L10n.t("Pokaż Vitals", language: language) + ".workflow"
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: services.path), [name])
                XCTAssertEqual(QuickAction.installedURLs(in: services).count, 1)
            }
        }
    }

    func testWorkflowIdentitySurvivesTranslationRenames() throws {
        try withServices { services in
            try QuickAction.install(in: services, language: .english)
            let installed = try XCTUnwrap(QuickAction.installedURLs(in: services).first)
            let renamed = services.appendingPathComponent("Previous translation.workflow", isDirectory: true)
            try FileManager.default.moveItem(at: installed, to: renamed)
            XCTAssertEqual(QuickAction.installedURLs(in: services), [renamed])
            XCTAssertTrue(QuickAction.isInstalled(in: services))
            try QuickAction.install(in: services, language: .simplifiedChinese)
            let current = services.appendingPathComponent(L10n.t("action.show_vitals", language: .simplifiedChinese) + ".workflow", isDirectory: true)
            XCTAssertEqual(QuickAction.installedURLs(in: services), [current])
            XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        }
    }

    func testRemovalDeletesAllKnownVariantsAndPreservesUnrelatedWorkflows() throws {
        try withServices { services in
            _ = try createLegacyVariants(in: services)
            let unrelated = services.appendingPathComponent("Another App.workflow", isDirectory: true)
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
            try QuickAction.remove(in: services)
            XCTAssertEqual(QuickAction.installedURLs(in: services), [])
            XCTAssertFalse(QuickAction.isInstalled(in: services))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: services.path), ["Another App.workflow"])
        }
    }
}
