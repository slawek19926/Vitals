// HelperClient.swift - rejestracja pomocnika (SMAppService) i połączenie XPC
import Foundation
import ServiceManagement
import HelperKit

final class HelperClient {
    static let shared = HelperClient()
    private var connection: NSXPCConnection?
    private(set) var connected = false
    /// Wersja zainstalowanego pomocnika (odczytana przez XPC)
    private(set) var installedVersion: String?
    private var lastAttempt = Date.distantPast

    var service: SMAppService { SMAppService.daemon(plistName: helperPlistName) }

    /// true = pomocnik pochodzi z innej kompilacji niż aplikacja
    var outdated: Bool {
        guard let v = installedVersion else { return false }
        return v != AppVersion.full
    }

    var statusText: String {
        if blessed {
            if let v = installedVersion, outdated { return L("zainstalowany, wersja") + " \(v) — " + L("aplikacja ma") + " \(AppVersion.full); " + L("kliknij „Zaktualizuj pomocnika”") }
            return connected ? L("zainstalowany i połączony") + " (" + L("wersja") + " \(installedVersion ?? AppVersion.full))" : L("zainstalowany, łączenie…")
        }
        switch service.status {
        case .enabled: return connected ? L("włączony i połączony") : L("włączony (łączenie…)")
        case .requiresApproval: return L("wymaga zatwierdzenia w Ustawieniach systemowych → Ogólne → Elementy logowania i rozszerzenia")
        case .notRegistered: return "niezarejestrowany"
        case .notFound: return "nie znaleziono pliku pomocnika w pakiecie"
        @unknown default: return L("nieznany")
        }
    }
    /// Zainstalowany przez SMJobBless (klasyczny pomocnik w /Library/PrivilegedHelperTools)
    var blessed: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(helperMachService).plist") }
    var isEnabled: Bool { service.status == .enabled || blessed }

    func register() throws {
        do {
            try service.register()
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            return
        } catch {
            // SMAppService odrzuca demony bez podpisu z nazwą organizacji – próbujemy SMJobBless (jednorazowa autoryzacja)
            try bless()
        }
    }

    func bless() throws {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let auth = authRef else {
            throw NSError(domain: "Helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nie można utworzyć autoryzacji."])
        }
        defer { AuthorizationFree(auth, []) }
        var item = kSMRightBlessPrivilegedHelper.withCString { AuthorizationItem(name: $0, valueLength: 0, value: nil, flags: 0) }
        var rights = AuthorizationRights(count: 1, items: &item)
        let st = AuthorizationCopyRights(auth, &rights, nil, [.interactionAllowed, .preAuthorize, .extendRights], nil)
        guard st == errAuthorizationSuccess else {
            throw NSError(domain: "Helper", code: Int(st), userInfo: [NSLocalizedDescriptionKey: st == errAuthorizationCanceled ? L("Anulowano.") : L("Brak autoryzacji") + " (\(st))."])
        }
        var cfError: Unmanaged<CFError>?
        typealias BlessFn = @convention(c) (CFString, CFString, AuthorizationRef?, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        guard let h = dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_LAZY), let sym = dlsym(h, "SMJobBless") else {
            throw NSError(domain: "Helper", code: 2, userInfo: [NSLocalizedDescriptionKey: "SMJobBless niedostępne."])
        }
        let fn = unsafeBitCast(sym, to: BlessFn.self)
        let ok = fn("system" as CFString, helperMachService as CFString, auth, &cfError)
        if !ok {
            let msg = cfError?.takeRetainedValue().localizedDescription ?? "nieznany błąd"
            throw NSError(domain: "Helper", code: 3, userInfo: [NSLocalizedDescriptionKey: "SMJobBless: \(msg)"])
        }
        connection = nil
    }

    func unregister() throws {
        if service.status == .enabled { try service.unregister() }
        if blessed {
            // usunięcie wymaga uprawnień administratora
            let script = "do shell script \"launchctl bootout system/\(helperMachService); rm -f /Library/LaunchDaemons/\(helperMachService).plist /Library/PrivilegedHelperTools/\(helperMachService)\" with administrator privileges"
            _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        }
        disconnect()
    }

    private func connect() -> NSXPCConnection? {
        if let c = connection { return c }
        guard isEnabled, Date().timeIntervalSince(lastAttempt) > 2 else { return nil }
        lastAttempt = Date()
        let c = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.invalidationHandler = { [weak self] in self?.connection = nil; self?.connected = false }
        c.interruptionHandler = { [weak self] in self?.connection = nil; self?.connected = false }
        c.resume()
        connection = c
        return c
    }

    private func proxy() -> HelperProtocol? {
        guard let c = connect() else { return nil }
        return c.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.connection = nil; self?.connected = false } as? HelperProtocol
    }

    /// Synchronicznie (z limitem czasu) pobiera listę procesów z pomocnika; nil = brak pomocnika
    func fetchProcesses(timeout: TimeInterval = 1.5) -> HelperProcessList? {
        guard let p = proxy() else { return nil }
        var result: HelperProcessList?
        let sem = DispatchSemaphore(value: 0)
        p.processes { data in result = try? JSONDecoder().decode(HelperProcessList.self, from: data); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
        connected = result != nil
        if connected, installedVersion == nil { fetchVersion() }
        return result
    }

    /// Pobiera wersję pomocnika (raz po połączeniu)
    func fetchVersion() {
        guard let p = proxy() else { return }
        p.version { [weak self] v in DispatchQueue.main.async { self?.installedVersion = v } }
    }

    func fetchPower(timeout: TimeInterval = 1.0) -> HelperPower? {
        guard let p = proxy() else { return nil }
        var result: HelperPower?
        let sem = DispatchSemaphore(value: 0)
        p.power { data in result = try? JSONDecoder().decode(HelperPower.self, from: data); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return result
    }

    /// Wykonuje operację na usłudze launchd; zwraca nil przy powodzeniu albo komunikat błędu
    func serviceAction(_ action: ServiceAction, domain: String, label: String, timeout: TimeInterval = 8) -> String? {
        guard let p = proxy() else { return "Pomocnik nieaktywny" }
        var result: String? = L("Brak odpowiedzi pomocnika")
        let sem = DispatchSemaphore(value: 0)
        p.service(action: action.rawValue, domain: domain, label: label) { msg in
            result = msg.isEmpty ? nil : msg
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return L("Przekroczono czas oczekiwania") }
        return result
    }

    func disconnect() { connection?.invalidate(); connection = nil; connected = false }
}
