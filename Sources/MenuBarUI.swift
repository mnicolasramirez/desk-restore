import SwiftUI

/// The menu, laid out as SPEC section 14 specifies.
///
/// Save and Restore are disabled, with an explanatory line, until Accessibility
/// is granted. Restore is also disabled when nothing has been saved.
struct MenuBarUI: View {

    @ObservedObject var model: AppModel
    var openSettings: () -> Void

    var body: some View {
        Text(model.hasSavedLayout ? "Desktop Layout" : "Desktop Layout — not saved yet")

        Divider()

        Text("Current mode: \(model.modeLabel)")
        Text("External monitor: \(model.externalLabel)")
        if model.hasSavedLayout {
            Text("Saved: \(model.savedAtLabel)")
        }
        if !model.lastStatus.isEmpty {
            Text(model.lastStatus)
        }

        Divider()

        if !model.isTrusted {
            Text("Accessibility permission is required")
            Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
            Divider()
        }

        Button("Save Current Desktop Layout") { model.save() }
            .disabled(!model.isTrusted || model.isWorking)

        Button("Restore Desktop Layout") { model.restore() }
            .disabled(!model.isTrusted || !model.hasSavedLayout || model.isWorking)

        Divider()

        Toggle("Automatic Restore", isOn: Binding(
            get: { Settings.shared.automaticRestore },
            set: { Settings.shared.automaticRestore = $0 }))

        Divider()

        Button("Settings…") { openSettings() }
        Button("Quit Desk Restore") { NSApplication.shared.terminate(nil) }
    }
}
