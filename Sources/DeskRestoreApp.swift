import SwiftUI
import AppKit

/// A menu-bar agent: `LSUIElement`, no Dock icon, no main window.
@main
struct DeskRestoreApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = AppModel.shared

    /// A one-shot launch must not flash a menu bar icon on its way past.
    @State private var showsMenuBarItem = !LaunchMode.current.isOneShot

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuBarUI(model: model) { openSettingsWindow() }
        } label: {
            Image(systemName: "macwindow.on.rectangle")
        }

        Window("Desk Restore Settings", id: WindowID.settings) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Desk Restore", id: WindowID.permission) {
            PermissionView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func openSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.settings)
    }
}

enum WindowID {
    static let settings = "settings"
    static let permission = "permission"
}

/// AppKit delivers every delegate callback on the main thread, and the model it
/// touches is main-actor isolated, so the whole delegate is declared as such.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    let log = DebugLog.shared
    let settings = Settings.shared
    let watcher = DisplayWatcher.shared
    let model = AppModel.shared
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.isEnabled = settings.debugLogging
        log.rotateIfNeeded()
        // A one-shot launch does its one job and leaves. No menu bar, no
        // hotkey, no watcher, nothing resident.
        if LaunchMode.current.isOneShot, Permissions.isTrusted {
            runOneShotThenQuit(LaunchMode.current)
            return
        }
        if LaunchMode.current.isOneShot {
            // Asked to do a job it has no permission for. Falling through to
            // agent mode surfaces the permission window rather than exiting
            // silently, which would look like the app simply did not work.
            log.note("one-shot \(LaunchMode.current.rawValue) requested without "
                   + "Accessibility permission — starting normally to ask for it")
        }

        log.heading("agent launched — pid \(ProcessInfo.processInfo.processIdentifier)")

        model.startRefreshing()
        registerURLHandler()

        if Permissions.isTrusted {
            log.note("Accessibility: granted")
            for problem in DisplayInventory.verifyCoordinateConversion() {
                log.note("COORDINATE CHECK FAILED — \(problem)")
            }
        } else {
            log.note("Accessibility: NOT granted — save and restore are unavailable")
            Permissions.requestTrust()
            showPermissionWindow()
            pollUntilTrusted()
        }

        HotKeyCenter.shared.register(keyCode: settings.hotKeyCode,
                                     modifiers: settings.hotKeyModifiers) { [weak self] in
            self?.model.restore()
        }

        watcher.onModeChange = { [weak self] _ in self?.model.refresh() }
        watcher.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
        HotKeyCenter.shared.unregister()
        watcher.stop()
        log.note("agent terminating")
    }

    // MARK: - One-shot

    /// Runs off the main thread — a restore pass blocks on retries and settling
    /// delays — then terminates. The extra verification pass mirrors the
    /// automatic path, since a window that lands late would otherwise be missed
    /// with no menu left to notice it from.
    private func runOneShotThenQuit(_ mode: LaunchMode) {
        log.heading("one-shot \(mode.rawValue) — pid \(ProcessInfo.processInfo.processIdentifier)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch mode {
            case .restoreAndQuit:
                let report = LayoutCoordinator.shared.restore()
                Thread.sleep(forTimeInterval: 1.0)
                let repaired = LayoutCoordinator.shared.verifyAndRepair()
                self?.log.note("one-shot restore: \(report.summary)"
                             + (repaired > 0 ? ", \(repaired) repaired" : ""))
            case .saveAndQuit:
                let ok = LayoutCoordinator.shared.save()
                self?.log.note("one-shot save: \(ok ? "ok" : "failed")")
            case .agent:
                break
            }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Permission

    private func showPermissionWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let url = URL(string: "deskrestore://open-permission") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Poll until granted, then enable Save and Restore (SPEC section 15).
    private func pollUntilTrusted() {
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard Permissions.isTrusted else { return }
            timer.invalidate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionPoll = nil
                self.log.note("Accessibility granted — save and restore are now available")
                self.model.refresh()
            }
        }
    }

    // MARK: - URL commands

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor,
                              withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        handle(url)
    }

    /// deskrestore://save, ://restore, ://probe, ://scatter,
    /// ://selftest?cycles=10, ://simulate-dock, ://quit
    func handle(_ url: URL) {
        let command = url.host ?? url.path.replacingOccurrences(of: "/", with: "")
        log.debug("command: \(command)")

        switch command {
        case "save":
            watcher.saveNow { ok in self.log.note("save via URL: \(ok ? "ok" : "failed")") }
        case "restore":
            watcher.restoreNow { report in self.log.note("restore via URL: \(report.summary)") }
        case "undo-save":
            watcher.undoSaveNow { date in
                self.log.note("undo via URL: \(date.map { "back to \($0)" } ?? "nothing to undo")")
            }
        case "probe":
            DispatchQueue.global().async { Diagnostics.dump() }
        case "scatter":
            watcher.scatterNow()
        case "selftest":
            let cycles = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cycles" }
                .flatMap { $0.value }
                .flatMap { Int($0) } ?? 10
            watcher.runSelfTest(cycles: cycles)
        case "selftest-matcher":
            DispatchQueue.global().async { SelfTest.runMatcherTests() }
        case "selftest-displays":
            DispatchQueue.global().async { SelfTest.runDisplayTests() }
        case "simulate-dock":
            watcher.simulateDockTransition()
        case "open-permission", "open-settings":
            break  // the Window scenes handle presentation
        case "quit":
            NSApplication.shared.terminate(nil)
        default:
            log.note("unknown command: \(command)")
        }
    }
}

/// The Phase 1 probe, kept as a diagnostic dump.
enum Diagnostics {

    static func dump() {
        let log = DebugLog.shared
        log.heading("probe")

        guard Permissions.isTrusted else {
            log.note("Accessibility not granted")
            return
        }

        let problems = DisplayInventory.verifyCoordinateConversion()
        log.note(problems.isEmpty
            ? "coordinate check: toCG(frame) == CGDisplayBounds on every display"
            : "COORDINATE CHECK FAILED:")
        problems.forEach { log.note("  " + $0) }

        let displays = DisplayInventory.snapshot()
        log.note("displays: \(displays.count)")
        for display in displays {
            log.note("  \(display.identity.shortDescription) builtin=\(display.identity.isBuiltin)")
            log.note("    frame        \(display.frame.shortDescription)")
            log.note("    visibleFrame \(display.visibleFrame.shortDescription)")
            log.note("    scale \(display.backingScale)  pixels \(display.pixelWidth)x\(display.pixelHeight)")
        }
        log.note("mode: \(DisplayWatcher.currentModeNow().rawValue)")
        log.note("fingerprint: \(DisplayInventory.fingerprint(of: displays))")

        let (windows, skipped) = WindowInventory.eligibleWindows(displays: displays)
        log.note("eligible windows: \(windows.count)")
        for window in windows {
            let frame = window.frame?.shortDescription ?? "unreadable"
            let display = window.frame
                .flatMap { DisplayInventory.display(for: $0, among: displays) }
                .map { $0.identity.localizedName } ?? "-"
            log.note("  [\(window.index)] \(window.bundleIdentifier)  \(frame)  on \(display)")
            log.note("       title: \(window.title)")
        }
        log.note("skipped: \(skipped.count)")
        for skip in skipped {
            let title = skip.title.isEmpty ? "" : " \"\(skip.title)\""
            log.note("  \(skip.application)\(title) — \(skip.reason)")
        }
        log.note("probe complete")
    }
}
