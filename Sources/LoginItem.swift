import Foundation
import ServiceManagement

/// Launch at login, via `SMAppService.mainApp`.
///
/// Registration is tied to the app's location. Moving the app breaks it, the
/// same way moving it invalidates the Accessibility grant — install once, then
/// leave it (SPEC section 17).
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:           return "enabled"
        case .notRegistered:     return "not registered"
        case .notFound:          return "not found"
        case .requiresApproval:  return "requires approval in System Settings > General > Login Items"
        @unknown default:        return "unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            DebugLog.shared.note("launch at login: \(enabled ? "registered" : "unregistered")")
            return true
        } catch {
            DebugLog.shared.note("launch at login \(enabled ? "registration" : "removal") "
                               + "failed: \(error.localizedDescription)")
            return false
        }
    }
}
