// LoginItem.swift - uruchamianie przy starcie systemu (SMAppService, macOS 13+)
import Foundation
import ServiceManagement

enum LoginItem {
    /// Czy aplikacja jest zarejestrowana do uruchamiania po zalogowaniu
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// true = użytkownik musi zatwierdzić pozycję w Ustawieniach systemowych
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return L("włączone")
        case .requiresApproval: return L("wymaga zatwierdzenia w Ustawieniach systemowych")
        case .notFound: return L("niedostępne")
        default: return L("wyłączone")
        }
    }

    /// Zwraca nil przy powodzeniu albo opis błędu
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Otwiera panel „Elementy logowania”, gdy system czeka na zatwierdzenie
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
