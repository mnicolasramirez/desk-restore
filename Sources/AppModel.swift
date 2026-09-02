import Foundation
import AppKit
import SwiftUI

/// Presentation state. The UI layer reads this and nothing else.
@MainActor
final class AppModel: ObservableObject {

    @Published var isTrusted = false
    @Published var mode: ScreenMode = .laptop
    @Published var externalDisplayName: String?
    @Published var hasSavedLayout = false
    @Published var savedAt: Date?
    @Published var lastStatus: String = ""
    @Published var isWorking = false

    /// Created eagerly and never optional. An earlier version handed the model
    /// to the menu through the app delegate; a MenuBarExtra scene does not
    /// reliably re-evaluate when an NSApplicationDelegateAdaptor publishes, so
    /// the menu rendered its "Starting..." fallback forever.
    static let shared = AppModel(watcher: .shared)

    let watcher: DisplayWatcher
    private var backstopTimer: Timer?

    /// `layouts.json` is only decoded when its modification date changes.
    /// Everything the menu shows is otherwise derived from one display
    /// enumeration, so an idle refresh costs a stat and a screen query.
    private var cachedLayout: Layout?
    private var cachedStamp: Date?

    init(watcher: DisplayWatcher) {
        self.watcher = watcher
        refresh()
    }

    /// Event-driven, not polled. The menu is redrawn when something actually
    /// happens: a display change, a save, a restore, or a permission grant.
    /// A 30 s backstop covers a notification we somehow miss; it is cheap
    /// because `refresh()` no longer decodes anything unless the file changed.
    func startRefreshing() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }

        backstopTimer?.invalidate()
        backstopTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        isTrusted = Permissions.isTrusted

        // One enumeration, reused for both the display name and the mode.
        let displays = DisplayInventory.snapshot()
        externalDisplayName = displays.first { !$0.identity.isBuiltin }?.identity.localizedName

        let layout = currentLayout()
        hasSavedLayout = layout != nil
        savedAt = layout?.savedAt
        mode = DisplayInventory.mode(for: displays,
                                     savedTargets: layout?.targetIdentities ?? [])
    }

    /// Decodes only when `layouts.json` has actually changed on disk.
    private func currentLayout() -> Layout? {
        let stamp = LayoutStore.modificationDate
        if stamp != cachedStamp {
            cachedStamp = stamp
            cachedLayout = (try? LayoutStore.load())?.layout(id: LayoutStore.defaultLayoutID)
        }
        return cachedLayout
    }

    var modeLabel: String {
        mode == .desktop ? "Desktop" : "Laptop"
    }

    var externalLabel: String {
        externalDisplayName ?? "none"
    }

    var savedAtLabel: String {
        guard let savedAt else { return "never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: savedAt)
    }

    // MARK: - Actions

    func save() {
        isWorking = true
        lastStatus = "Saving…"
        watcher.saveNow { [weak self] ok in
            guard let self else { return }
            self.isWorking = false
            self.refresh()
            self.lastStatus = ok
                ? "Saved \(self.savedAtLabel)"
                : "Save failed — see the debug log"
        }
    }

    func restore() {
        isWorking = true
        lastStatus = "Restoring…"
        watcher.restoreNow { [weak self] report in
            guard let self else { return }
            self.isWorking = false
            var parts = ["\(report.exact) restored"]
            if report.constrained > 0 { parts.append("\(report.constrained) constrained") }
            if report.failed > 0 { parts.append("\(report.failed) failed") }
            if report.unmatchedSaved > 0 { parts.append("\(report.unmatchedSaved) not open") }
            self.lastStatus = parts.joined(separator: ", ")
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Permissions.settingsURL)
    }
}
