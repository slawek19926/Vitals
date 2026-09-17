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
        guard !checking else { return }
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
        let panel = showProgress(L("Pobieranie wersji") + " \(release.version.raw)…")
        let task = URLSession.shared.downloadTask(with: release.zipURL) { [weak self] file, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.closeProgress(panel)
                if let error { return self.alert(L("Pobieranie nie powiodło się"), error.localizedDescription, style: .warning) }
                guard let file else { return self.alert(L("Pobieranie nie powiodło się"), "", style: .warning) }
                do { try self.install(downloaded: file, release: release) }
                catch { self.alert(L("Instalacja nie powiodła się"), error.localizedDescription, style: .warning) }
            }
        }
        task.resume()
    }

    // MARK: - weryfikacja i podmiana

    private func install(downloaded file: URL, release: Release) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("VitalsUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: file, to: zip)

        // rozpakowanie zachowujące podpis i uprawnienia
        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard Shell.status("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw UpdateError.badArchive }

        let apps = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = apps.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.badArchive }

        // podpis musi być ważny i pochodzić od tego samego zespołu co zainstalowana aplikacja
        guard Shell.status("/usr/bin/codesign", ["--verify", "--strict", newApp.path]) == 0 else { throw UpdateError.notSigned }
        let team = Self.teamIdentifier(of: newApp.path)
        let ourTeam = Self.teamIdentifier(of: Bundle.main.bundlePath)
        guard let team, let ourTeam, team == ourTeam else { throw UpdateError.wrongIdentity }
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongIdentity }

        let dest = Bundle.main.bundleURL
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            throw UpdateError.cannotReplace(dest.deletingLastPathComponent().path)
        }

        let a = NSAlert()
        a.messageText = L("Zainstalować wersję") + " \(release.version.raw)?"
        a.informativeText = L("Aplikacja zostanie zamknięta, pakiet podmieniony i uruchomiony ponownie.")
        a.addButton(withTitle: L("Zainstaluj i uruchom ponownie"))
        a.addButton(withTitle: L("Anuluj"))
        guard a.runModal() == .alertFirstButtonReturn else { try? fm.removeItem(at: work); return }

        // Podmiana po wyjściu z aplikacji: skrypt czeka na zakończenie procesu, przenosi pakiet i uruchamia nową wersję
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /usr/bin/ditto "\(newApp.path)" "\(dest.path).new" || exit 1
        /bin/rm -rf "\(dest.path)"
        /bin/mv "\(dest.path).new" "\(dest.path)"
        /bin/rm -rf "\(work.path)"
        /usr/bin/open "\(dest.path)"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        try proc.run()
        NSApp.terminate(nil)
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
