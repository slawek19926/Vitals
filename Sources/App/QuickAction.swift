// QuickAction.swift - akcja szybka (usługa Automatora) uruchamiająca aplikację skrótem, także gdy jest zamknięta
import AppKit

enum QuickAction {
    /// Nazwa widoczna w Ustawieniach systemowych → Klawiatura → Skróty klawiszowe → Usługi
    static var title: String { L("Pokaż Vitals") }

    static var url: URL {
        let services = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
        return services.appendingPathComponent("\(title).workflow", isDirectory: true)
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Zapisuje pakiet akcji i odświeża bazę usług. Zwraca nil przy powodzeniu albo opis błędu.
    @discardableResult
    static func install() -> String? {
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        do {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try infoPlist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try workflow.write(to: contents.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        _ = Shell.status("/System/Library/CoreServices/pbs", ["-flush"], timeout: 15)
        NSUpdateDynamicServices()
        return nil
    }

    @discardableResult
    static func remove() -> String? {
        guard isInstalled else { return nil }
        do { try FileManager.default.removeItem(at: url) } catch { return error.localizedDescription }
        _ = Shell.status("/System/Library/CoreServices/pbs", ["-flush"], timeout: 15)
        NSUpdateDynamicServices()
        return nil
    }

    /// Otwiera panel, w którym przypisuje się kombinację klawiszy
    static func openShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?shortcutsServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private static var infoPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
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
