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
    @Published var previousSavedAt: Date?
    /// Shown in the menu only when something needs attention: a failed save, or
    /// a restore that could not place every window. Success says nothing —
    /// after a save the "Saved:" line already carries the new timestamp, and
    /// after a restore the windows have visibly moved. A status line repeating
    /// what the menu already shows is noise that then sits there for hours.
    @Published var notice: String?
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
    private var cachedFile: LayoutFile?
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

        let file = currentFile()
        let layout = file?.layout(id: LayoutStore.defaultLayoutID)
        hasSavedLayout = layout != nil
        savedAt = layout?.savedAt
        previousSavedAt = file?.layout(id: LayoutStore.previousLayoutID)?.savedAt
        mode = DisplayInventory.mode(for: displays,
                                     savedTargets: layout?.targetIdentities ?? [])
    }

    /// Decodes only when `layouts.json` has actually changed on disk.
    private func currentFile() -> LayoutFile? {
        let stamp = LayoutStore.modificationDate
        if stamp != cachedStamp {
            cachedStamp = stamp
            cachedFile = try? LayoutStore.load()
        }
        return cachedFile
    }

    var canUndoSave: Bool { previousSavedAt != nil }

    /// The menu item names where it would take you, so "undo" is never a guess.
    var undoSaveLabel: String {
        guard let previousSavedAt else { return "Undo Save" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Undo Save — back to \(formatter.string(from: previousSavedAt))"
    }

    func undoSave() {
        isWorking = true
        notice = nil
        watcher.undoSaveNow { [weak self] restored in
            guard let self else { return }
            self.isWorking = false
            self.refresh()
            self.notice = restored == nil ? "Nothing to undo" : nil
        }
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
        notice = nil
        watcher.saveNow { [weak self] ok in
            guard let self else { return }
            self.isWorking = false
            self.refresh()
            // On success the refreshed "Saved:" timestamp is the confirmation.
            self.notice = ok ? nil : "Save failed — see the debug log"
        }
    }

    func restore() {
        isWorking = true
        notice = nil
        watcher.restoreNow { [weak self] report in
            guard let self else { return }
            self.isWorking = false
            self.notice = AppModel.notice(for: report)
        }
    }

    /// nil when everything landed. Otherwise names only what went wrong, and
    /// stays until the next action, because a window that did not come back is
    /// worth noticing late.
    static func notice(for report: RestoreReport) -> String? {
        var problems: [String] = []
        if report.unmatchedSaved > 0 {
            problems.append("\(report.unmatchedSaved) not open")
        }
        if report.constrained > 0 {
            problems.append("\(report.constrained) could not be resized")
        }
        if report.failed > 0 {
            problems.append("\(report.failed) failed")
        }
        guard !problems.isEmpty else { return nil }
        return "Last restore: \(report.exact) placed, " + problems.joined(separator: ", ")
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Permissions.settingsURL)
    }
}
