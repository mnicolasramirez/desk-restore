import Foundation
import AppKit
import ApplicationServices

/// One live window, addressed over the Accessibility API.
///
/// This layer knows nothing about displays or layouts. Positions and sizes it
/// reads and writes are already in CG top-left points — the Accessibility API
/// speaks that natively, so no conversion happens here or anywhere below it.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleIdentifier: String
    let applicationName: String
    /// Position among that application's windows, as enumerated.
    let index: Int

    var title: String {
        AXWindow.string(element, kAXTitleAttribute as String) ?? ""
    }

    var subrole: String {
        AXWindow.string(element, kAXSubroleAttribute as String) ?? ""
    }

    var frame: Rect? {
        guard let position: CGPoint = AXWindow.value(element, kAXPositionAttribute as String, .cgPoint),
              let size: CGSize = AXWindow.value(element, kAXSizeAttribute as String, .cgSize)
        else { return nil }
        return Rect(x: Double(position.x), y: Double(position.y),
                    width: Double(size.width), height: Double(size.height))
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    // MARK: - Attribute plumbing

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        guard let raw = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(axValue, type, out) else { return nil }
        return out.pointee
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }
}

/// Why a window was not managed. Every skip is logged; nothing aborts a pass.
struct SkippedWindow {
    let application: String
    let title: String
    let reason: String
}

/// Enumerates the windows Desk Restore is willing to touch.
enum WindowInventory {

    /// Minimum managed size, catching small utility windows that slip past the
    /// subrole filter (SPEC section 9).
    static let minimumSize = CGSize(width: 200, height: 100)

    /// One hung application must not stall a whole pass.
    static let messagingTimeout: Float = 1.0

    static func eligibleWindows(displays: [DisplaySnapshot])
        -> (windows: [AXWindow], skipped: [SkippedWindow]) {

        var eligible: [AXWindow] = []
        var skipped: [SkippedWindow] = []

        let ownPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"

            guard app.activationPolicy == .regular else { continue }
            guard !app.isTerminated else { continue }
            guard app.processIdentifier != ownPID else { continue }
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier
            else { continue }
            if app.isHidden {
                skipped.append(SkippedWindow(application: name, title: "",
                                             reason: "application hidden"))
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

            guard let raw = AXWindow.copyAttribute(appElement, kAXWindowsAttribute as String),
                  let windowList = raw as? [AXUIElement] else {
                skipped.append(SkippedWindow(application: name, title: "",
                                             reason: "no AX windows attribute (not scriptable, "
                                                   + "or AX request timed out)"))
                continue
            }

            for (index, element) in windowList.enumerated() {
                let window = AXWindow(element: element,
                                      pid: app.processIdentifier,
                                      bundleIdentifier: bundleID,
                                      applicationName: name,
                                      index: index)
                if let reason = ineligibilityReason(window, displays: displays) {
                    skipped.append(SkippedWindow(application: name,
                                                 title: window.title,
                                                 reason: reason))
                } else {
                    eligible.append(window)
                }
            }
        }
        return (eligible, skipped)
    }

    /// Returns nil when the window is managed, or the reason it is not.
    /// Ordered cheapest check first.
    static func ineligibilityReason(_ window: AXWindow,
                                    displays: [DisplaySnapshot]) -> String? {
        let role = AXWindow.string(window.element, kAXRoleAttribute as String) ?? ""
        guard role == (kAXWindowRole as String) else { return "role is \(role.isEmpty ? "unreadable" : role)" }

        let subrole = window.subrole
        // The single check that does the heavy lifting: drops dialogs, sheets,
        // floating palettes and system dialogs without a hand-kept blocklist.
        guard subrole == (kAXStandardWindowSubrole as String) else {
            return "subrole is \(subrole.isEmpty ? "unreadable" : subrole)"
        }

        if AXWindow.bool(window.element, kAXMinimizedAttribute as String) == true {
            return "minimized"
        }

        guard AXWindow.isSettable(window.element, kAXPositionAttribute as String) else {
            return "position not settable"
        }
        guard AXWindow.isSettable(window.element, kAXSizeAttribute as String) else {
            return "size not settable"
        }

        guard let frame = window.frame else { return "frame unreadable" }

        if isFullScreen(window, frame: frame, displays: displays) {
            return "native full screen"
        }

        if frame.width < Double(minimumSize.width) || frame.height < Double(minimumSize.height) {
            return String(format: "below minimum size (%.0f x %.0f)", frame.width, frame.height)
        }

        return nil
    }

    /// Native full-screen windows live in their own Space and cannot be
    /// repositioned. Detected, never fought.
    ///
    /// `kAXFullScreenAttribute` is not a public constant — the string
    /// "AXFullScreen" is read through the public copy-attribute call, which is
    /// a normal API call with a non-constant key, not a private API. Treated as
    /// best-effort, with the geometry heuristic from SPEC section 9 as the
    /// fallback when the attribute is absent.
    static func isFullScreen(_ window: AXWindow, frame: Rect,
                             displays: [DisplaySnapshot]) -> Bool {
        if let flag = AXWindow.bool(window.element, "AXFullScreen") { return flag }
        return displays.contains { display in
            frame == display.frame && display.visibleFrame != display.frame
        }
    }
}
