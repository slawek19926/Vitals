// Hotkey.swift - globalny skrót klawiszowy pokazujący okno (Carbon: działa bez zgody na dostępność)
import AppKit
import Carbon.HIToolbox

/// Gotowe kombinacje do wyboru w ustawieniach
enum HotkeyCombo: Int, CaseIterable {
    case ctrlShiftEsc = 0, cmdShiftV = 1, ctrlOptCmdV = 2, ctrlShiftM = 3

    var title: String {
        switch self {
        case .ctrlShiftEsc: return "⌃⇧⎋"
        case .cmdShiftV: return "⌘⇧V"
        case .ctrlOptCmdV: return "⌃⌥⌘V"
        case .ctrlShiftM: return "⌃⇧M"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .ctrlShiftEsc: return UInt32(kVK_Escape)
        case .cmdShiftV, .ctrlOptCmdV: return UInt32(kVK_ANSI_V)
        case .ctrlShiftM: return UInt32(kVK_ANSI_M)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .ctrlShiftEsc: return UInt32(controlKey | shiftKey)
        case .cmdShiftV: return UInt32(cmdKey | shiftKey)
        case .ctrlOptCmdV: return UInt32(controlKey | optionKey | cmdKey)
        case .ctrlShiftM: return UInt32(controlKey | shiftKey)
        }
    }
}

final class Hotkey {
    static let shared = Hotkey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature = OSType(0x56_54_4C_53)   // „VTLS”

    private init() {}

    /// Rejestruje skrót zgodnie z ustawieniami; wołane przy starcie i po każdej zmianie
    func apply() {
        unregister()
        guard Prefs.shared.hotkeyEnabled else { return }
        installHandlerIfNeeded()
        let combo = HotkeyCombo(rawValue: Prefs.shared.hotkeyCombo) ?? .ctrlShiftEsc
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Vitals: nie udało się zarejestrować skrótu (%d)", status) }
    }

    /// true, gdy skrót jest zajęty przez system albo inny program
    var isRegistered: Bool { ref != nil }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { Hotkey.shared.trigger() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Skrót działa jak przełącznik: pokazuje okno, a gdy jest już na wierzchu – chowa je
    private func trigger() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let window = delegate.mainWindow
        if let window, window.isVisible, NSApp.isActive {
            window.orderOut(nil)
        } else {
            delegate.showMainWindow(nil)
        }
    }
}
