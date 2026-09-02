import Foundation
import ApplicationServices

/// Accessibility is the only permission Desk Restore ever asks for.
/// Screen Recording is never requested: the app reads window metadata —
/// position, size, title, role — never pixels or content.
enum Permissions {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask macOS to show the standard Accessibility prompt and add this app to
    /// the list in System Settings. Returns the trust state at call time, which
    /// is false on the run that triggers the prompt.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
