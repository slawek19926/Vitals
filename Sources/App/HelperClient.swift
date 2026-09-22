// HelperClient.swift - rejestracja pomocnika (SMAppService) i połączenie XPC
import Foundation
import ServiceManagement
import HelperKit

extension Notification.Name {
    static let helperStatusChanged = Notification.Name("helperStatusChanged")
    static let helperUpdateFailed = Notification.Name("helperUpdateFailed")
    static let helperApprovalRequired = Notification.Name("helperApprovalRequired")
}

final class HelperClient {
    static let shared = HelperClient()
    private struct State {
        var connection: NSXPCConnection?
        var connected = false
        var installedVersion: String?
        var lastAttempt = Date.distantPast
    }
    private let state = Locked(State())
    private let signingRequirement = PeerTrust.requirement(identifier: helperMachService)
    private let installerQueue = DispatchQueue(label: "Vitals.helperInstaller", qos: .userInitiated)
    // Accessed only on the main queue; XPC state above remains independently locked.
    private lazy var updater: HelperUpdater = {
        let updater = HelperUpdater(target: AppVersion.full, install: { [weak self] done in
            self?.installOrUpdate(completion: done)
        }, readVersion: { [weak self] done in self?.readVersion(completion: done) })
        updater.onChange = { [weak updater] in
            NotificationCenter.default.post(name: .helperStatusChanged, object: nil)
            if updater?.phase == .requiresApproval {
                NotificationCenter.default.post(name: .helperApprovalRequired, object: nil)
            }
        }
        updater.onFailure = { error in
            guard (error as NSError).code != Int(errAuthorizationCanceled) else { return }
            NotificationCenter.default.post(name: .helperUpdateFailed, object: error)
        }
        return updater
    }()
    var updating: Bool { updater.isBusy }
    var updateNeedsRetry: Bool {
        if case .failed = updater.phase { return true }
        return false
    }
    var connected: Bool { state.withValue { $0.connected } }
    var installedVersion: String? { state.withValue { $0.installedVersion } }

    var service: SMAppService { SMAppService.daemon(plistName: helperPlistName) }

    /// Only older helpers need replacement; an older app must not downgrade one.
    var outdated: Bool {
        guard let v = installedVersion else { return false }
        return HelperUpdater.needsUpdate(installed: v, target: AppVersion.full)
    }

    var statusText: String {
        guard signingRequirement != nil else { return L("Pomocnik wymaga aplikacji podpisanej certyfikatem Apple tego samego zespołu.") }
        switch updater.phase {
        case .installing: return L("Aktualizowanie pomocnika… macOS może poprosić o autoryzację.")
        case .verifying: return L("Sprawdzanie wersji uruchomionego pomocnika…")
        case .failed(let message): return message
        default: break
        }
        if requiresApproval { return L("wymaga zatwierdzenia w Ustawieniach systemowych → Ogólne → Elementy logowania i rozszerzenia") }
        if let v = installedVersion, outdated {
            return L("zainstalowany, wersja") + " \(v) — " + L("aplikacja ma") + " \(AppVersion.full); " + L("kliknij „Zaktualizuj pomocnika”")
        }
        if blessed {
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
    var requiresApproval: Bool {
        // Legacy SMJobBless authorization is separate: statusForLegacyPlist can
        // report requiresApproval even for an authorized, running legacy job.
        // Its automatic upgrade is gated by a successful signed XPC reply.
        return !blessed && service.status == .requiresApproval
    }
    var isEnabled: Bool { !requiresApproval && (service.status == .enabled || blessed) }

    func updateHelper() {
        dispatchPrecondition(condition: .onQueue(.main))
        if requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        updater.update()
    }

    /// Keep the installed backend: a legacy job must be replaced by SMJobBless,
    /// whereas a bundled daemon must finish unregistering before registration.
    private func installOrUpdate(completion: @escaping (Result<Bool, Error>) -> Void) {
        installerQueue.async { [self] in
            let finish: (Result<Bool, Error>) -> Void = { result in
                self.disconnect()
                DispatchQueue.main.async { completion(result) }
            }
            do {
                try requireSignature()
                if requiresApproval { finish(.success(true)); return }
                let daemon = service
                let backend: HelperInstallation.Backend = blessed ? .legacy
                    : (daemon.status == .enabled ? .bundled : .unregistered)
                HelperInstallation.run(backend: backend,
                    bless: { try self.bless() },
                    unregister: { daemon.unregister(completionHandler: $0) },
                    register: { try daemon.register() },
                    installNew: { try self.registerNew() }) { error in
                        if let error { finish(.failure(error)) }
                        else { finish(.success(self.requiresApproval)) }
                    }
            } catch { finish(.failure(error)) }
        }
    }

    private func requireSignature() throws {
        guard signingRequirement != nil else {
            throw NSError(domain: "Helper", code: 5, userInfo: [NSLocalizedDescriptionKey: L("Pomocnik wymaga aplikacji podpisanej certyfikatem Apple tego samego zespołu.")])
        }
    }

    private func registerNew() throws {
        do {
            try service.register()
        } catch {
            // Approval is a user decision, not a reason to install a legacy job.
            if service.status == .requiresApproval { return }
            // SMAppService odrzuca demony bez podpisu z nazwą organizacji – próbujemy SMJobBless (jednorazowa autoryzacja)
            try bless()
        }
    }

    private func bless() throws {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let auth = authRef else {
            throw NSError(domain: "Helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nie można utworzyć autoryzacji."])
        }
        defer { AuthorizationFree(auth, []) }
        let st = AuthorizationRequest.copyRight(kSMRightBlessPrivilegedHelper, auth: auth,
                                                flags: [.interactionAllowed, .preAuthorize, .extendRights])
        guard st == errAuthorizationSuccess else {
            throw NSError(domain: "Helper", code: Int(st), userInfo: [NSLocalizedDescriptionKey: st == errAuthorizationCanceled ? L("Anulowano.") : L("Brak autoryzacji") + " (\(st))."])
        }
        var cfError: Unmanaged<CFError>?
        typealias BlessFn = @convention(c) (CFString, CFString, AuthorizationRef?, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        guard let h = dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_LAZY), let sym = dlsym(h, "SMJobBless") else {
            throw NSError(domain: "Helper", code: 2, userInfo: [NSLocalizedDescriptionKey: "SMJobBless niedostępne."])
        }
        defer { dlclose(h) }
        let fn = unsafeBitCast(sym, to: BlessFn.self)
        let ok = fn("system" as CFString, helperMachService as CFString, auth, &cfError)
        if !ok {
            let msg = cfError?.takeRetainedValue().localizedDescription ?? "nieznany błąd"
            throw NSError(domain: "Helper", code: 3, userInfo: [NSLocalizedDescriptionKey: "SMJobBless: \(msg)"])
        }
        disconnect()
    }

    func unregister() throws {
        if service.status == .enabled { try service.unregister() }
        if blessed {
            // usunięcie wymaga uprawnień administratora
            let script = "do shell script \"if /bin/launchctl print system/\(helperMachService) >/dev/null 2>&1; then /bin/launchctl bootout system/\(helperMachService) || exit 1; fi; /bin/rm -f /Library/LaunchDaemons/\(helperMachService).plist /Library/PrivilegedHelperTools/\(helperMachService)\" with administrator privileges"
            let result = Shell.execute("/usr/bin/osascript", ["-e", script], timeout: 120)
            if let error = result.failureDescription {
                throw NSError(domain: "Helper", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: error])
            }
            guard !blessed else {
                throw NSError(domain: "Helper", code: 4, userInfo: [NSLocalizedDescriptionKey: "Nie udało się usunąć pomocnika."])
            }
        }
        disconnect()
    }

    private func connect() -> NSXPCConnection? {
        state.withValue { value in
            if let connection = value.connection { return connection }
            guard isEnabled, Date().timeIntervalSince(value.lastAttempt) > 2,
                  let requirement = signingRequirement else { return nil }
            value.lastAttempt = Date()
            let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.setCodeSigningRequirement(requirement)
            connection.invalidationHandler = { [weak self, weak connection] in self?.forget(connection) }
            connection.interruptionHandler = { [weak self, weak connection] in self?.forget(connection) }
            value.connection = connection
            connection.resume()
            return connection
        }
    }

    /// An old connection's delayed callback must not clear a newer connection.
    private func forget(_ connection: NSXPCConnection?) {
        guard let connection else { return }
        state.withValue {
            guard $0.connection === connection else { return }
            $0.connection = nil; $0.connected = false; $0.installedVersion = nil
        }
    }

    private func request<T>(timeout: TimeInterval, _ invoke: (HelperProtocol, @escaping (T?) -> Void) -> Void) -> T? {
        guard let connection = connect() else { return nil }
        let result = Locked<T?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.forget(connection)
            semaphore.signal()
        }) as? HelperProtocol else { return nil }
        invoke(proxy) { response in result.withValue { $0 = response }; semaphore.signal() }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            forget(connection); connection.invalidate(); return nil
        }
        return result.withValue { $0 }
    }

    func fetchProcesses(timeout: TimeInterval = 1.5) -> HelperProcessList? {
        let result: HelperProcessList? = request(timeout: timeout) { proxy, done in
            proxy.processes { done(try? JSONDecoder().decode(HelperProcessList.self, from: $0)) }
        }
        state.withValue { $0.connected = result != nil && $0.connection != nil }
        if result != nil, installedVersion == nil { fetchVersion() }
        return result
    }

    func fetchVersion() {
        readVersion { [weak self] version in
            guard let self, let version else { return }
            self.updater.consider(installed: version, enabled: self.isEnabled)
        }
    }

    /// Bounded query independent of process decoding (also used at startup).
    private func readVersion(completion: @escaping (String?) -> Void) {
        guard let connection = connect() else {
            DispatchQueue.main.async { completion(nil) }; return
        }
        let completed = Locked(false)
        let finish: (String?) -> Void = { [weak self] version in
            guard completed.withValue({ value in
                if value { return false }; value = true; return true
            }) else { return }
            DispatchQueue.main.async {
                guard let self else { completion(nil); return }
                let accepted = self.state.withValue { state -> Bool in
                    guard state.connection === connection else { return false }
                    if let version { state.installedVersion = version; state.connected = true }
                    return true
                }
                if version == nil { self.forget(connection); connection.invalidate() }
                if accepted { NotificationCenter.default.post(name: .helperStatusChanged, object: nil) }
                completion(accepted ? version : nil)
            }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? HelperProtocol else {
            finish(nil); return
        }
        proxy.version { finish($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
    }

    func fetchPower(timeout: TimeInterval = 1.0) -> HelperPower? {
        request(timeout: timeout) { proxy, done in
            proxy.power { done(try? JSONDecoder().decode(HelperPower.self, from: $0)) }
        }
    }

    func serviceAction(_ action: ServiceAction, domain: String, label: String, timeout: TimeInterval = 8) -> String? {
        let result: String? = request(timeout: timeout) { proxy, done in
            proxy.service(action: action.rawValue, domain: domain, label: label) { done($0) }
        }
        guard let result else { return L("Brak odpowiedzi pomocnika") }
        return result.isEmpty ? nil : result
    }

    func setPriority(pid: Int32, startTimeMicros: Int64, value: Int32) -> String? {
        let result: String? = request(timeout: 3) { proxy, done in
            proxy.priority(pid: pid, startTimeMicros: startTimeMicros, value: value) { done($0) }
        }
        guard let result else { return L("Brak odpowiedzi pomocnika") }
        return result.isEmpty ? nil : result
    }

    func disconnect() {
        let connection = state.withValue { value -> NSXPCConnection? in
            let old = value.connection
            value = State()
            return old
        }
        connection?.invalidate()
    }
}
