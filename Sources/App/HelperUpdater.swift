import Foundation

enum HelperInstallation {
    enum Backend { case legacy, bundled, unregistered }

    /// An existing installation never silently switches backend on failure.
    static func run(backend: Backend, bless: () throws -> Void,
                    unregister: (@escaping (Error?) -> Void) -> Void,
                    register: @escaping () throws -> Void, installNew: () throws -> Void,
                    completion: @escaping (Error?) -> Void) {
        switch backend {
        case .legacy:
            do { try bless(); completion(nil) } catch { completion(error) }
        case .unregistered:
            do { try installNew(); completion(nil) } catch { completion(error) }
        case .bundled:
            unregister { error in
                if let error { completion(error); return }
                do { try register(); completion(nil) } catch { completion(error) }
            }
        }
    }
}

/// Owned by the main queue. OS installation and XPC reads are injected so the
/// upgrade lifecycle can be tested without changing a system daemon.
final class HelperUpdater {
    enum Phase: Equatable {
        case idle, installing, verifying, requiresApproval, current
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptedAutomatically = false
    var isBusy: Bool { phase == .installing || phase == .verifying }
    var onChange: () -> Void = {}
    var onFailure: (Error) -> Void = { _ in }

    private let target: String
    private let install: (@escaping (Result<Bool, Error>) -> Void) -> Void
    private let readVersion: (@escaping (String?) -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// Installation returns true when macOS still requires approval.
    /// All callbacks must be delivered on the main queue.
    init(target: String,
         install: @escaping (@escaping (Result<Bool, Error>) -> Void) -> Void,
         readVersion: @escaping (@escaping (String?) -> Void) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.target = target
        self.install = install
        self.readVersion = readVersion
        self.schedule = schedule
    }

    static func needsUpdate(installed: String, target: String) -> Bool {
        // Reject malformed replies and never downgrade a helper used by a newer app.
        func valid(_ version: String) -> Bool {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            return (3...4).contains(parts.count) && parts.allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil
            }
        }
        return valid(installed) && valid(target) && SemVersion(installed) < SemVersion(target)
    }

    func consider(installed: String, enabled: Bool) {
        guard enabled, !isBusy else { return }
        if installed == target {
            if phase != .current { change(.current) }
        } else if !attemptedAutomatically, Self.needsUpdate(installed: installed, target: target) {
            update()
        }
    }

    func update() {
        guard !isBusy else { return }
        // Also suppress automatic retries after a failed/cancelled manual attempt.
        attemptedAutomatically = true
        change(.installing)
        install { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.fail(error)
            case .success(true): self.change(.requiresApproval)
            case .success(false):
                self.change(.verifying)
                self.verify(remaining: 10)
            }
        }
    }

    private func verify(remaining: Int) {
        readVersion { [weak self] version in
            guard let self else { return }
            if version == self.target {
                self.change(.current)
            } else if remaining > 1 {
                self.schedule(1) { [weak self] in self?.verify(remaining: remaining - 1) }
            } else {
                self.fail(NSError(domain: "HelperUpdate", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("Nie udało się potwierdzić nowej wersji pomocnika. Spróbuj ponownie w Ustawieniach.")
                ]))
            }
        }
    }

    private func change(_ phase: Phase) {
        self.phase = phase
        onChange()
    }

    private func fail(_ error: Error) {
        change(.failed(error.localizedDescription))
        onFailure(error)
    }
}
