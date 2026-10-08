import Foundation
import LocalizationKit

@main
enum LocalizationTool {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data(("Localization error: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
            print("""
            LocalizationTool validate|report|add-language|enable-language|package
              --catalog PATH       Defaults to Sources/App/Localization
              --code LANGUAGE      e.g. de, fr, zh-Hant
              --name NATIVE_NAME   Required for add-language, e.g. Deutsch
              --matches LOCALES    Comma-separated locale patterns; defaults to code
              --system-font        Use native system fonts for this language
              --app PATH           App bundle to package localized privacy resources
            """)
            return
        }
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--system-font" { options[flag] = "true"; index += 1; continue }
            guard ["--catalog", "--code", "--name", "--matches", "--app"].contains(flag),
                  index + 1 < arguments.count else { throw CatalogError("Unknown or incomplete option: \(flag)") }
            options[flag] = arguments[index + 1]; index += 2
        }
        func required(_ option: String) throws -> String {
            guard let value = options[option], !value.isEmpty else { throw CatalogError("Required option: \(option)") }
            return value
        }
        let directory = URL(fileURLWithPath: options["--catalog"] ?? "Sources/App/Localization", isDirectory: true)
        let workspace = LocalizationWorkspace(directory: directory)
        switch command {
        case "validate":
            let catalog = try workspace.load()
            try catalog.validatePrivacyDescriptions()
            print("Valid catalog: \(catalog.messages.count) messages; enabled languages: \(catalog.languages.map(\.code).joined(separator: ", ")).")
        case "report":
            let catalog = try workspace.load()
            let selected = catalog.configuration.languages.filter { options["--code"] == nil || $0.code == options["--code"] }
            guard !selected.isEmpty else { throw CatalogError("Unknown language: \(options["--code"] ?? "")") }
            for language in selected {
                let missing = catalog.missingTranslations(for: language.code)
                print("\(language.code) (\(language.nativeName)): \(catalog.messages.count - missing.count)/\(catalog.messages.count), \(language.enabled ? "enabled" : "draft")")
                for id in missing { print("  missing: \(id)") }
            }
        case "add-language":
            let code = try required("--code")
            let font = options["--system-font"] != nil || ["zh", "ja", "ko"].contains(code.split(separator: "-").first.map(String.init) ?? "")
            let language = try workspace.addLanguage(code: code, nativeName: required("--name"),
                matches: options["--matches"].map { $0.split(separator: ",").map(String.init) },
                prefersSystemFont: font)
            print("Added draft \(language.code), preference ID \(language.id). Fill its CSV column, then run enable-language --code \(language.code).")
        case "enable-language":
            let code = try required("--code")
            try workspace.enableLanguage(code: code)
            print("Enabled \(code). It will appear in Settings after the next build.")
        case "package":
            try workspace.package(into: URL(fileURLWithPath: required("--app"), isDirectory: true))
            print("Packaged localized privacy resources from the catalog.")
        default: throw CatalogError("Unknown command: \(command)")
        }
    }
}
