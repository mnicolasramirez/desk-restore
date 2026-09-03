import SwiftUI

/// The menu.
///
/// Restore comes first because it is the function that gets used. Save is the
/// rare, deliberate one — you press it when you have rearranged things, added an
/// application, or changed monitors — so it sits below the status block, behind
/// a divider, where it cannot be hit by accident while reaching for Restore.
///
/// Save and Restore are disabled, with an explanatory line, until Accessibility
/// is granted. Restore is also disabled when nothing has been saved.
struct MenuBarUI: View {

    @ObservedObject var model: AppModel
    var openSettings: () -> Void

    var body: some View {
        // When permission is missing, the actionable thing is granting it, so
        // that takes the top slot instead.
        if !model.isTrusted {
            Text("Accessibility permission is required")
            Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
            Divider()
        }

        Button("Restore Desktop Layout") { model.restore() }
            .disabled(!model.isTrusted || !model.hasSavedLayout || model.isWorking)

        Divider()

        Text("Current mode: \(model.modeLabel)")
        Text("External monitor: \(model.externalLabel)")
        Text(model.hasSavedLayout ? "Saved: \(model.savedAtLabel)" : "No layout saved yet")

        // Only present when something needs attention. A successful save shows
        // itself in the line above; a successful restore shows itself on screen.
        if let notice = model.notice {
            Text(notice)
        }

        Divider()

        Button("Save Current Desktop Layout") { model.save() }
            .disabled(!model.isTrusted || model.isWorking)

        Button(model.undoSaveLabel) { model.undoSave() }
            .disabled(!model.canUndoSave || model.isWorking)

        Divider()

        Toggle("Automatic Restore", isOn: Binding(
            get: { Settings.shared.automaticRestore },
            set: { Settings.shared.automaticRestore = $0 }))

        Divider()

        Button("Settings…") { openSettings() }
        Button("Quit Desk Restore") { NSApplication.shared.terminate(nil) }
    }
}
