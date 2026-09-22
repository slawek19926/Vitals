// Updater.swift - sprawdzanie i instalacja aktualizacji z wydań GitHuba (pyta przed pobraniem)
import AppKit
import HelperKit

/// Wersja rozbita na liczby – porównujemy „1.1.0.126” z „v1.2.0” bez zgadywania formatu
struct SemVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let raw: String

    init(_ text: String) {
        raw = text
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        parts = cleaned.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func < (a: SemVersion, b: SemVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
    static func == (a: SemVersion, b: SemVersion) -> Bool { !(a < b) && !(b < a) }
    var description: String { raw }
}

/// Wydanie odczytane z API GitHuba
struct Release {
    let version: SemVersion
    let title: String
    let notes: String
    let zipURL: URL
    let size: Int64
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case noRelease, noAsset, badArchive, notSigned, wrongIdentity, cannotReplace(String)

    var errorDescription: String? {
        switch self {
        case .noRelease: return L("Repozytorium nie ma jeszcze żadnego wydania.")
        case .noAsset: return L("Wydanie nie zawiera pliku ZIP z aplikacją.")
        case .badArchive: return L("Pobrane archiwum jest uszkodzone albo nie zawiera aplikacji.")
        case .notSigned: return L("Pobrana aplikacja nie ma poprawnego podpisu.")
        case .wrongIdentity: return L("Pobrana aplikacja jest podpisana przez inny zespół niż zainstalowana.")
        case .cannotReplace(let path): return L("Nie można podmienić pakietu w") + " \(path)"
        }
    }
}

final class Updater {
    static let shared = Updater()

    /// Repozytorium z wydaniami. Wydanie musi mieć załącznik ZIP z pakietem Vitals.app.
    static let repository = "slawek19926/Vitals"

    private var checking = false
    private var installing = false
    private var progressPanel: NSWindow?

    // MARK: - sprawdzanie

    /// Sprawdzenie przy starcie i nie częściej niż raz na dobę; cicho pomija błędy sieci
    func checkOnLaunch() {
        guard Prefs.shared.autoUpdateCheck else { return }
        let last = Prefs.shared.lastUpdateCheck
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(userInitiated: false)
    }

    /// `userInitiated` – pokazujemy też komunikat „masz najnowszą wersję” i błędy
    func check(userInitiated: Bool) {
        guard !checking, !installing else { return }
        checking = true
        fetchLatest { [weak self] result in
            guard let self else { return }
            self.checking = false
            Prefs.shared.lastUpdateCheck = Date().timeIntervalSince1970
            switch result {
            case .failure(let error):
                if userInitiated { self.alert(L("Nie udało się sprawdzić aktualizacji"), error.localizedDescription, style: .warning) }
            case .success(let release):
                let current = SemVersion(AppVersion.full)
                guard current < release.version else {
                    if userInitiated {
                        self.alert(L("Masz najnowszą wersję"), L("Zainstalowana wersja") + ": \(AppVersion.full)", style: .informational)
                    }
                    return
                }
                if !userInitiated, Prefs.shared.skippedUpdate == release.version.raw { return }
                self.offer(release)
            }
        }
    }

    private func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Vitals/\(AppVersion.full)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let finish: (Result<Release, Error>) -> Void = { r in DispatchQueue.main.async { done(r) } }
            if let error { return finish(.failure(error)) }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return finish(.failure(UpdateError.noRelease)) }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return finish(.failure(UpdateError.noRelease)) }
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
            guard let zip, let link = zip["browser_download_url"] as? String, let zipURL = URL(string: link)
            else { return finish(.failure(UpdateError.noAsset)) }
            let page = (json["html_url"] as? String).flatMap { URL(string: $0) }
                ?? URL(string: "https://github.com/\(Self.repository)/releases")!
            finish(.success(Release(version: SemVersion(tag),
                                    title: (json["name"] as? String) ?? tag,
                                    notes: (json["body"] as? String) ?? "",
                                    zipURL: zipURL,
                                    size: Int64((zip["size"] as? Int) ?? 0),
                                    pageURL: page)))
        }.resume()
    }

    // MARK: - pytanie i pobranie

    private func offer(_ release: Release) {
        let a = NSAlert()
        a.messageText = L("Dostępna jest nowa wersja") + " \(release.version.raw)"
        var info = L("Zainstalowana") + ": \(AppVersion.full)"
        if release.size > 0 { info += " · " + L("do pobrania") + ": \(Fmt.bytes(UInt64(release.size)))" }
        a.informativeText = info
        a.alertStyle = .informational
        a.addButton(withTitle: L("Pobierz i zainstaluj"))
        a.addButton(withTitle: L("Później"))
        a.addButton(withTitle: L("Pomiń tę wersję"))
        if !release.notes.isEmpty {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
            text.string = release.notes
            text.isEditable = false
            text.drawsBackground = false
            text.font = Fonts.ui(11.5)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            a.accessoryView = scroll
        }
        switch a.runModal() {
        case .alertFirstButtonReturn: download(release)
        case .alertThirdButtonReturn: Prefs.shared.skippedUpdate = release.version.raw
        default: break
        }
    }

    private func download(_ release: Release) {
        guard !installing else { return }
        installing = true
        let panel = showProgress(L("Pobieranie i weryfikacja aktualizacji…"))
        let destination = Bundle.main.bundleURL
        let task = URLSession.shared.downloadTask(with: release.zipURL) { [weak self] file, response, error in
            // Preserve the temporary file before URLSession's completion handler returns.
            let preparation: Result<UpdateTransaction, Error>
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let file else {
                    throw UpdateError.badArchive
                }
                let download = try UpdateTransaction.preserveDownload(file)
                preparation = Result { try Self.prepare(work: download.work, archive: download.archive, destination: destination, release: release) }
            } catch { preparation = .failure(error) }
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let transaction) = preparation { Self.cleanup(transaction) }
                    return
                }
                self.closeProgress(panel)
                self.installing = false
                switch preparation {
                case .failure(let error): self.alert(L("Instalacja nie powiodła się"), error.localizedDescription, style: .warning)
                case .success(let transaction): self.confirmInstall(transaction, release: release)
                }
            }
        }
        task.resume()
    }

    /// Runs on URLSession's background queue; no shell work blocks AppKit.
    private static func prepare(work: URL, archive: URL, destination: URL, release: Release) throws -> UpdateTransaction {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let id = UUID().uuidString
        let staged = parent.appendingPathComponent(".Vitals-staged-\(id).app")
        let backup = parent.appendingPathComponent("Vitals-previous-\(id).app")
        var prepared = false
        defer {
            if !prepared { try? fm.removeItem(at: staged); try? fm.removeItem(at: work) }
        }
        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        guard Shell.status("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) == 0 else { throw UpdateError.badArchive }
        let apps = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let newApp = apps.first,
              try newApp.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw UpdateError.badArchive }
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.cannotReplace(parent.path) }
        // Stage on the destination volume before verifying and before closing the running app.
        guard Shell.status("/usr/bin/ditto", [newApp.path, staged.path]) == 0 else { throw UpdateError.cannotReplace(parent.path) }
        guard let ourTeam = teamIdentifier(of: destination.path),
              let requirement = PeerTrust.requirement(identifier: PeerTrust.appIdentifier, team: ourTeam) else { throw UpdateError.wrongIdentity }
        guard Shell.status("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, staged.path]) == 0 else { throw UpdateError.notSigned }
        guard let newBundle = Bundle(url: staged), let oldBundle = Bundle(url: destination),
              newBundle.bundleIdentifier == oldBundle.bundleIdentifier else { throw UpdateError.wrongIdentity }
        let short = newBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = newBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard SemVersion(short + "." + build) == release.version else { throw UpdateError.badArchive }
        prepared = true
        return UpdateTransaction(work: work, staged: staged, destination: destination, backup: backup)
    }

    private static func cleanup(_ transaction: UpdateTransaction) {
        try? FileManager.default.removeItem(at: transaction.staged)
        try? FileManager.default.removeItem(at: transaction.work)
    }

    private func confirmInstall(_ transaction: UpdateTransaction, release: Release) {
        let alert = NSAlert()
        alert.messageText = L("Zainstalować wersję") + " \(release.version.raw)?"
        alert.informativeText = L("Aplikacja zostanie uruchomiona ponownie. Poprzednia wersja pozostanie obok jako kopia zapasowa.")
        alert.addButton(withTitle: L("Zainstaluj i uruchom ponownie"))
        alert.addButton(withTitle: L("Anuluj"))
        guard alert.runModal() == .alertFirstButtonReturn else { Self.cleanup(transaction); return }
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = transaction.arguments(waitForPID: ProcessInfo.processInfo.processIdentifier)
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Self.cleanup(transaction)
            self.alert(L("Instalacja nie powiodła się"), error.localizedDescription, style: .warning)
        }
    }

    /// Identyfikator zespołu z podpisu pakietu (`codesign -dv`)
    private static func teamIdentifier(of path: String) -> String? {
        let out = Shell.runCombined("/usr/bin/codesign", ["-dv", path], timeout: 15)
        for line in out.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    // MARK: - drobne okna

    private func showProgress(_ text: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Vitals"
        let label = Label.make(text, size: 12)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = vstack([label, bar], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: w.contentLayoutRect)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        w.contentView = content
        w.center()
        w.makeKeyAndOrderFront(nil)
        progressPanel = w
        return w
    }

    private func closeProgress(_ w: NSWindow) {
        w.orderOut(nil)
        if progressPanel === w { progressPanel = nil }
    }

    private func alert(_ title: String, _ info: String, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
