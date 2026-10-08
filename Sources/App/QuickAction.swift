// QuickAction.swift - akcja szybka (usługa Automatora) uruchamiająca aplikację skrótem, także gdy jest zamknięta
import AppKit

enum QuickAction {
    private static let workflowIdentifier = "online.equishow.vitals.quickaction"
    /// Nazwa widoczna w Ustawieniach systemowych → Klawiatura → Skróty klawiszowe → Usługi
    static var title: String { L("action.show_vitals") }

    private static var servicesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
    }

    static var url: URL { servicesURL.appendingPathComponent("\(title).workflow", isDirectory: true) }

    static func installedURLs(in services: URL) -> [URL] {
        // Keep historical names even if a translation changes in a later release.
        var names = ["Pokaż Vitals", "Show Vitals", "显示 Vitals"]
        for language in L10n.catalog.configuration.languages {
            let name = L10n.catalog.text("action.show_vitals", languageCode: language.code)
            if !names.contains(name) { names.append(name) }
        }
        var installed: [URL] = []
        var seen = Set<String>()
        for name in names {
            let candidate = services.appendingPathComponent("\(name).workflow", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path),
               seen.insert(workflowIdentity(candidate)).inserted { installed.append(candidate) }
        }
        // New workflows carry a language-independent identity, so later wording changes
        // or disabled languages cannot leave extra installed copies behind.
        let candidates = (try? FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)) ?? []
        for entry in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension == "workflow" {
            let candidate = services.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            let identity = workflowIdentity(candidate)
            guard !seen.contains(identity) else { continue }
            guard let data = try? Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  info["VitalsQuickActionIdentifier"] as? String == workflowIdentifier else { continue }
            installed.append(candidate); seen.insert(identity)
        }
        return installed
    }

    private static func workflowIdentity(_ url: URL) -> String {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let device = attributes[.systemNumber] as? NSNumber,
           let inode = attributes[.systemFileNumber] as? NSNumber {
            return "\(device.uint64Value):\(inode.uint64Value)"
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static var isInstalled: Bool { isInstalled(in: servicesURL) }

    static func isInstalled(in services: URL) -> Bool { !installedURLs(in: services).isEmpty }

    /// Zapisuje pakiet akcji i odświeża bazę usług. Zwraca nil przy powodzeniu albo opis błędu.
    @discardableResult
    static func install() -> String? {
        do { try install(in: servicesURL, language: L10n.resolvedLanguage) }
        catch { return error.localizedDescription }
        refreshServices()
        return nil
    }

    /// Filesystem-only operations allow migration tests without touching real services.
    static func install(in services: URL, language: AppLanguage) throws {
        let fm = FileManager.default
        let title = L10n.t("action.show_vitals", language: language)
        let destination = services.appendingPathComponent("\(title).workflow", isDirectory: true)
        let contents = destination.appendingPathComponent("Contents", isDirectory: true)
        try remove(in: services)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try infoPlist(title: title).write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try workflow.write(to: contents.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func remove() -> String? {
        guard isInstalled else { return nil }
        do { try remove(in: servicesURL) }
        catch { return error.localizedDescription }
        refreshServices()
        return nil
    }

    static func remove(in services: URL) throws {
        for url in installedURLs(in: services) { try FileManager.default.removeItem(at: url) }
    }

    private static func refreshServices() {
        _ = Shell.status("/System/Library/CoreServices/pbs", ["-flush"], timeout: 15)
        NSUpdateDynamicServices()
    }

    /// Otwiera panel, w którym przypisuje się kombinację klawiszy
    static func openShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?shortcutsServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func infoPlist(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>VitalsQuickActionIdentifier</key><string>\(workflowIdentifier)</string>
        \t<key>NSServices</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>NSMenuItem</key>
        \t\t\t<dict><key>default</key><string>\(title)</string></dict>
        \t\t\t<key>NSMessage</key><string>runWorkflowAsService</string>
        \t\t</dict>
        \t</array>
        </dict>
        </plist>
        """
    }

    /// Jedna akcja „Uruchom skrypt powłoki” otwierająca pakiet aplikacji z bieżącej lokalizacji
    private static var workflow: String {
        let command = "open -a \"\(Bundle.main.bundlePath)\""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>AMApplicationBuild</key><string>523</string>
        \t<key>AMApplicationVersion</key><string>2.10</string>
        \t<key>AMDocumentVersion</key><string>2</string>
        \t<key>actions</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>action</key>
        \t\t\t<dict>
        \t\t\t\t<key>AMAccepts</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>Container</key><string>List</string>
        \t\t\t\t\t<key>Optional</key><true/>
        \t\t\t\t\t<key>Types</key><array><string>com.apple.cocoa.string</string></array>
        \t\t\t\t</dict>
        \t\t\t\t<key>AMActionVersion</key><string>2.0.3</string>
        \t\t\t\t<key>AMApplication</key><array><string>Automator</string></array>
        \t\t\t\t<key>AMParameterProperties</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>COMMAND_STRING</key><dict/>
        \t\t\t\t\t<key>CheckedForUserDefaultShell</key><dict/>
        \t\t\t\t\t<key>inputMethod</key><dict/>
        \t\t\t\t\t<key>shell</key><dict/>
        \t\t\t\t\t<key>source</key><dict/>
        \t\t\t\t</dict>
        \t\t\t\t<key>AMProvides</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>Container</key><string>List</string>
        \t\t\t\t\t<key>Types</key><array><string>com.apple.cocoa.string</string></array>
        \t\t\t\t</dict>
        \t\t\t\t<key>ActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
        \t\t\t\t<key>ActionName</key><string>Run Shell Script</string>
        \t\t\t\t<key>ActionParameters</key>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>COMMAND_STRING</key><string>\(command)</string>
        \t\t\t\t\t<key>CheckedForUserDefaultShell</key><true/>
        \t\t\t\t\t<key>inputMethod</key><integer>0</integer>
        \t\t\t\t\t<key>shell</key><string>/bin/zsh</string>
        \t\t\t\t\t<key>source</key><string></string>
        \t\t\t\t</dict>
        \t\t\t\t<key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
        \t\t\t\t<key>CFBundleVersion</key><string>2.0.3</string>
        \t\t\t\t<key>CanShowSelectedItemsWhenRun</key><false/>
        \t\t\t\t<key>CanShowWhenRun</key><true/>
        \t\t\t\t<key>Category</key><array><string>AMCategoryUtilities</string></array>
        \t\t\t\t<key>Class Name</key><string>RunShellScriptAction</string>
        \t\t\t\t<key>InputUUID</key><string>1B7A9A1B-0001-4E5F-9E11-000000000001</string>
        \t\t\t\t<key>Keywords</key><array><string>Shell</string></array>
        \t\t\t\t<key>OutputUUID</key><string>1B7A9A1B-0002-4E5F-9E11-000000000002</string>
        \t\t\t\t<key>UUID</key><string>1B7A9A1B-0003-4E5F-9E11-000000000003</string>
        \t\t\t\t<key>UnlocalizedApplications</key><array><string>Automator</string></array>
        \t\t\t\t<key>arguments</key><dict/>
        \t\t\t\t<key>isViewVisible</key><integer>1</integer>
        \t\t\t\t<key>location</key><string>309.000000:253.000000</string>
        \t\t\t\t<key>nibPath</key><string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
        \t\t\t</dict>
        \t\t\t<key>isViewVisible</key><integer>1</integer>
        \t\t</dict>
        \t</array>
        \t<key>connectors</key><dict/>
        \t<key>workflowMetaData</key>
        \t<dict>
        \t\t<key>serviceInputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        \t\t<key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        \t\t<key>serviceProcessesInput</key><integer>0</integer>
        \t\t<key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
        \t</dict>
        </dict>
        </plist>
        """
    }
}
