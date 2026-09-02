import SwiftUI
import Carbon.HIToolbox

/// Settings, kept deliberately small (SPEC section 14).
struct SettingsView: View {

    @ObservedObject var model: AppModel

    @State private var automaticRestore = Settings.shared.automaticRestore
    @State private var restoreDelay = Settings.shared.restoreDelay
    @State private var debugLogging = Settings.shared.debugLogging
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var recordingHotKey = false
    @State private var hotKeyDescription = HotKeyCenter.symbolic(
        keyCode: Settings.shared.hotKeyCode, modifiers: Settings.shared.hotKeyModifiers)

    var body: some View {
        Form {
            Section {
                Toggle("Restore automatically when the desktop monitor connects",
                       isOn: $automaticRestore)
                    .onChange(of: automaticRestore) { _, value in
                        Settings.shared.automaticRestore = value
                    }

                LabeledContent("Restore delay") {
                    HStack {
                        Slider(value: $restoreDelay,
                               in: Settings.minimumRestoreDelay...Settings.maximumRestoreDelay,
                               step: 0.5)
                            .onChange(of: restoreDelay) { _, value in
                                Settings.shared.restoreDelay = value
                            }
                        Text(String(format: "%.1f s", restoreDelay))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("How long to wait after a display change before acting, so the "
                   + "several notifications macOS emits mid-transition collapse into one restore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Global restore shortcut") {
                    Button(recordingHotKey ? "Press a combination…" : hotKeyDescription) {
                        recordingHotKey.toggle()
                    }
                    .buttonStyle(.bordered)
                    .background(HotKeyRecorder(isRecording: $recordingHotKey) { code, modifiers in
                        Settings.shared.hotKeyCode = code
                        Settings.shared.hotKeyModifiers = modifiers
                        hotKeyDescription = HotKeyCenter.symbolic(keyCode: code, modifiers: modifiers)
                        recordingHotKey = false
                        HotKeyCenter.shared.register(keyCode: code, modifiers: modifiers) {
                            model.restore()
                        }
                    })
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        if !LoginItem.setEnabled(value) { launchAtLogin = LoginItem.isEnabled }
                    }
                if SMAppServiceNeedsApproval {
                    Text(LoginItem.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Debug logging", isOn: $debugLogging)
                    .onChange(of: debugLogging) { _, value in
                        Settings.shared.debugLogging = value
                    }
                Text("Writes geometry, bundle identifiers, window titles and AX error codes to "
                   + "~/Library/Application Support/DeskRestore/debug.log. Never window content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Accessibility",
                               value: model.isTrusted ? "Granted" : "Not granted")
                if !model.isTrusted {
                    Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
                }
                LabeledContent("Saved layout", value: model.hasSavedLayout ? model.savedAtLabel : "none")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }

    private var SMAppServiceNeedsApproval: Bool {
        LoginItem.statusDescription.hasPrefix("requires approval")
    }
}

/// Captures one key combination for the global shortcut. A local monitor is
/// enough — the app is frontmost while its own settings window has focus, so
/// this needs no extra permission.
struct HotKeyRecorder: NSViewRepresentable {

    @Binding var isRecording: Bool
    var onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isRecording = isRecording
        context.coordinator.onCapture = onCapture
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var isRecording = false
        var onCapture: ((UInt32, UInt32) -> Void)?
        private var monitor: Any?

        func attach() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isRecording else { return event }
                var carbon: UInt32 = 0
                if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
                if event.modifierFlags.contains(.option)  { carbon |= UInt32(optionKey) }
                if event.modifierFlags.contains(.shift)   { carbon |= UInt32(shiftKey) }
                if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
                guard carbon != 0 else { return event }   // a bare key is not a global shortcut
                self.onCapture?(UInt32(event.keyCode), carbon)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Shown on first launch when Accessibility has not been granted.
struct PermissionView: View {

    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Accessibility permission needed")
                .font(.title2.weight(.semibold))

            Text("Desk Restore needs Accessibility permission to resize and reposition "
               + "application windows.")

            Text("It reads window metadata only — position, size, title and role. "
               + "It never reads window content, never requests Screen Recording, and "
               + "has no network access of any kind.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if model.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
