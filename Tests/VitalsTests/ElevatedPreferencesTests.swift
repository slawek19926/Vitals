import XCTest
import Darwin
@testable import Vitals

final class ElevatedPreferencesTests: XCTestCase {
    private func withPreferences(_ body: (URL, String, UserDefaults) throws -> Void) throws {
        let domain = "org.vitals.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Vitals ' & $ preferences " + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: home)
        }
        try body(home, domain, defaults)
    }

    private func write(_ values: Any, home: URL, domain: String) throws -> URL {
        let url = home.appendingPathComponent("Library/Preferences/" + domain + ".plist")
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: url)
        return url
    }

    func testElevatedRelaunchRestoresLanguageThemeAndModulesBeforeTheyAreRead() throws {
        try withPreferences { home, domain, defaults in
            let values: [String: Any] = ["language": 2, "appTheme": 2, "menuBarModules": ["network", "cpu"], "menuBarStyle": 2]
            _ = try write(values, home: home, domain: domain)
            defaults.setPersistentDomain(["language": 1, "appTheme": 1, "rootOnly": true], forName: domain)
            let arguments = ElevatedPreferences.arguments(home: home.path, domain: domain)
            XCTAssertTrue(ElevatedPreferences.restore(arguments: arguments, effectiveUID: 0,
                defaults: defaults, domain: domain, homeForUID: { uid in
                    XCTAssertEqual(uid, getuid())
                    return home.path
                }))
            XCTAssertEqual(defaults.integer(forKey: "language"), 2)
            XCTAssertEqual(defaults.integer(forKey: "appTheme"), 2)
            XCTAssertEqual(defaults.stringArray(forKey: "menuBarModules"), ["network", "cpu"])
            XCTAssertEqual(defaults.integer(forKey: "menuBarStyle"), 2)
            XCTAssertNil(defaults.object(forKey: "rootOnly"))
        }
    }

    func testOrdinaryLaunchDoesNotImportPreferences() throws {
        try withPreferences { home, domain, defaults in
            _ = try write(["language": 2], home: home, domain: domain)
            defaults.set(1, forKey: "language")
            XCTAssertFalse(ElevatedPreferences.restore(arguments: ElevatedPreferences.arguments(home: home.path, domain: domain),
                effectiveUID: getuid(), defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
            XCTAssertFalse(ElevatedPreferences.restore(arguments: ["Vitals"], effectiveUID: 0,
                defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
            XCTAssertEqual(defaults.integer(forKey: "language"), 1)
        }
    }

    func testRejectsInvalidDuplicateAndIncompleteArguments() throws {
        try withPreferences { home, domain, defaults in
            let url = try write(["language": 2], home: home, domain: domain)
            let valid = ElevatedPreferences.arguments(home: home.path, domain: domain)
            for arguments in [
                ["-userPrefs", url.path, "-userUID"],
                ["-userPrefs", url.path, "-userUID", "invalid"],
                ["-userPrefs", url.path, "-userUID", "0"],
                valid + ["-userUID", String(getuid())],
                valid + ["-userPrefs", url.path],
            ] {
                XCTAssertFalse(ElevatedPreferences.restore(arguments: arguments, effectiveUID: 0,
                    defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
            }
            XCTAssertNil(defaults.object(forKey: "language"))
        }
    }

    func testRejectsOtherPathsUnknownUsersAndWrongOwnership() throws {
        try withPreferences { home, domain, defaults in
            let url = try write(["language": 2], home: home, domain: domain)
            let valid = ElevatedPreferences.arguments(home: home.path, domain: domain)
            XCTAssertFalse(ElevatedPreferences.restore(arguments: ["-userPrefs", url.path, "-userUID", String(getuid() + 1)],
                effectiveUID: 0, defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
            XCTAssertFalse(ElevatedPreferences.restore(arguments: valid, effectiveUID: 0,
                defaults: defaults, domain: domain, homeForUID: { _ in nil }))
            XCTAssertFalse(ElevatedPreferences.restore(arguments: valid, effectiveUID: 0,
                defaults: defaults, domain: domain, homeForUID: { _ in home.appendingPathComponent("Other user").path }))
            XCTAssertNil(defaults.object(forKey: "language"))
        }
    }

    func testRejectsSymlinksAndNonRegularFiles() throws {
        try withPreferences { home, domain, defaults in
            let url = try write(["language": 2], home: home, domain: domain)
            let target = home.appendingPathComponent("other.plist")
            try FileManager.default.moveItem(at: url, to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            let arguments = ElevatedPreferences.arguments(home: home.path, domain: domain)
            XCTAssertFalse(ElevatedPreferences.restore(arguments: arguments, effectiveUID: 0,
                defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            XCTAssertFalse(ElevatedPreferences.restore(arguments: arguments, effectiveUID: 0,
                defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
            XCTAssertNil(defaults.object(forKey: "language"))
        }
    }

    func testMissingInvalidAndOversizedFilesLeaveExistingSettingsIntact() throws {
        try withPreferences { home, domain, defaults in
            let url = home.appendingPathComponent("Library/Preferences/" + domain + ".plist")
            defaults.set(1, forKey: "language")
            let arguments = ElevatedPreferences.arguments(home: home.path, domain: domain)
            func attempt() {
                XCTAssertFalse(ElevatedPreferences.restore(arguments: arguments, effectiveUID: 0,
                    defaults: defaults, domain: domain, homeForUID: { _ in home.path }))
                XCTAssertEqual(defaults.integer(forKey: "language"), 1)
            }
            attempt()
            try Data("not a plist".utf8).write(to: url)
            attempt()
            _ = try write(["not", "a", "dictionary"], home: home, domain: domain)
            attempt()
            try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: url)
            attempt()
        }
    }
}
