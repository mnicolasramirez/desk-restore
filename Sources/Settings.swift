import Foundation
import Carbon.HIToolbox

/// Preferences, in UserDefaults.
///
/// Deliberately not in layouts.json: these are preferences, not layout data,
/// and mixing them would make a layout non-portable (SPEC section 13).
final class Settings {

    static let shared = Settings()

    private enum Key {
        static let automaticRestore = "automaticRestore"
        static let restoreDelay = "restoreDelay"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let debugLogging = "debugLogging"
    }

    static let minimumRestoreDelay: Double = 0.5
    static let maximumRestoreDelay: Double = 10.0
    static let defaultRestoreDelay: Double = 2.5

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.automaticRestore: true,
            Key.restoreDelay: Settings.defaultRestoreDelay,
            Key.hotKeyCode: Int(kVK_ANSI_R),
            Key.hotKeyModifiers: Int(controlKey | optionKey | cmdKey),
            Key.debugLogging: false,
        ])
        DebugLog.shared.isEnabled = debugLogging
    }

    var automaticRestore: Bool {
        get { defaults.bool(forKey: Key.automaticRestore) }
        set { defaults.set(newValue, forKey: Key.automaticRestore) }
    }

    /// Debounce before acting on a display change. Collapses the several
    /// notifications macOS emits mid-transition.
    var restoreDelay: Double {
        get {
            let value = defaults.double(forKey: Key.restoreDelay)
            return min(max(value, Settings.minimumRestoreDelay), Settings.maximumRestoreDelay)
        }
        set {
            defaults.set(min(max(newValue, Settings.minimumRestoreDelay),
                             Settings.maximumRestoreDelay),
                         forKey: Key.restoreDelay)
        }
    }

    /// Default Control + Option + Command + R.
    var hotKeyCode: UInt32 {
        get { UInt32(defaults.integer(forKey: Key.hotKeyCode)) }
        set { defaults.set(Int(newValue), forKey: Key.hotKeyCode) }
    }

    var hotKeyModifiers: UInt32 {
        get { UInt32(defaults.integer(forKey: Key.hotKeyModifiers)) }
        set { defaults.set(Int(newValue), forKey: Key.hotKeyModifiers) }
    }

    var debugLogging: Bool {
        get { defaults.bool(forKey: Key.debugLogging) }
        set {
            defaults.set(newValue, forKey: Key.debugLogging)
            DebugLog.shared.isEnabled = newValue
        }
    }
}
