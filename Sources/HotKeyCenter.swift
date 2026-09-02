import Foundation
import Carbon.HIToolbox

/// System-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Carbon looks archaic, but this is still the only supported way to get a
/// global hotkey without installing an event tap — and an event tap is a much
/// heavier permission than this app should ask for (SPEC section 6).
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    fileprivate static let signature: OSType = 0x44534B52  // 'DSKR'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    fileprivate var action: (() -> Void)?

    private init() {}

    /// Replaces any previously registered combination.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: HotKeyCenter.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            DebugLog.shared.note("hotkey registration failed (OSStatus \(status)) — "
                               + "another application probably owns that combination")
            return false
        }
        DebugLog.shared.note("hotkey registered: \(Self.describe(keyCode: keyCode, modifiers: modifiers))")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            if pressed.signature == HotKeyCenter.signature {
                DispatchQueue.main.async { center.action?() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey)  != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey)   != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey)     != 0 { parts.append("Command") }
        parts.append(keyName(keyCode))
        return parts.joined(separator: " + ")
    }

    static func symbolic(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "\u{2303}" }
        if modifiers & UInt32(optionKey)  != 0 { parts += "\u{2325}" }
        if modifiers & UInt32(shiftKey)   != 0 { parts += "\u{21E7}" }
        if modifiers & UInt32(cmdKey)     != 0 { parts += "\u{2318}" }
        return parts + keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Escape: "Escape",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return names[Int(keyCode)] ?? "Key \(keyCode)"
    }
}
