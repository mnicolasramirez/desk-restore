import Foundation
import AppKit

/// Automatic restore, driven by `didChangeScreenParametersNotification`, which
/// also fires on clamshell transitions (SPEC section 11).
///
/// Two independent guards stop a noisy dock from producing a burst of restores.
/// The debounce collapses the several notifications macOS emits mid-transition;
/// the two-sample stability check refuses to act until the configuration has
/// stopped moving. Triggering on the laptop-to-desktop *edge* rather than the
/// desktop *state* is what guarantees one restore per docking sequence.
final class DisplayWatcher {

    /// One watcher for the process. Owned here rather than by the app delegate
    /// so the menu can reach it without depending on delegate lifecycle.
    static let shared = DisplayWatcher()

    /// Gap between the two fingerprint samples that decide whether the display
    /// configuration has settled.
    static let stabilitySampleGap: TimeInterval = 0.6
    /// How long to let windows settle before checking which ones missed.
    static let verificationDelay: TimeInterval = 1.5

    private let log = DebugLog.shared
    private let settings = Settings.shared
    private let coordinator = LayoutCoordinator.shared

    /// Serial: passes must never overlap, and every one of them blocks.
    private let queue = DispatchQueue(label: "com.nico.desk-restore.watcher")
    private var pendingConfirmation: DispatchWorkItem?

    private(set) var previousMode: ScreenMode = .laptop
    private(set) var currentMode: ScreenMode = .laptop

    /// Called after any mode change so the menu can redraw.
    var onModeChange: ((ScreenMode) -> Void)?

    init() {
        currentMode = Self.currentModeNow()
        previousMode = currentMode
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        log.note("watcher started — mode \(currentMode.rawValue), "
               + "automatic restore \(settings.automaticRestore ? "on" : "off")")
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        pendingConfirmation?.cancel()
        pendingConfirmation = nil
    }

    static func currentModeNow() -> ScreenMode {
        let displays = DisplayInventory.snapshot()
        let targets = (try? LayoutStore.load())?
            .layout(id: LayoutStore.defaultLayoutID)?.targetIdentities ?? []
        return DisplayInventory.mode(for: displays, savedTargets: targets)
    }

    @objc private func screenParametersChanged() {
        log.debug("screen parameters changed; debouncing \(settings.restoreDelay)s")
        scheduleConfirmation(after: settings.restoreDelay)
    }

    private func scheduleConfirmation(after delay: TimeInterval) {
        pendingConfirmation?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.confirm() }
        pendingConfirmation = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Two samples, `stabilitySampleGap` apart. Different fingerprints mean the
    /// configuration is still settling, so back off and look again rather than
    /// acting on a half-finished transition.
    private func confirm() {
        let first = DisplayInventory.fingerprint(of: DisplayInventory.snapshot())
        Thread.sleep(forTimeInterval: Self.stabilitySampleGap)
        let displays = DisplayInventory.snapshot()
        let second = DisplayInventory.fingerprint(of: displays)

        guard first == second else {
            log.debug("display configuration still settling; rescheduling")
            scheduleConfirmation(after: settings.restoreDelay)
            return
        }

        let targets = (try? LayoutStore.load())?
            .layout(id: LayoutStore.defaultLayoutID)?.targetIdentities ?? []
        let newMode = DisplayInventory.mode(for: displays, savedTargets: targets)

        let shouldRestore = newMode == .desktop
            && previousMode != .desktop          // edge, not level
            && settings.automaticRestore
            && !targets.isEmpty

        log.note("settled — mode \(previousMode.rawValue) -> \(newMode.rawValue)"
               + (shouldRestore ? "; restoring" : "; no restore"))

        if shouldRestore {
            _ = coordinator.restore()
            Thread.sleep(forTimeInterval: Self.verificationDelay)
            coordinator.verifyAndRepair()
        }

        previousMode = newMode
        currentMode = newMode
        DispatchQueue.main.async { [weak self] in self?.onModeChange?(newMode) }
    }

    /// Manual restore from the menu or the hotkey. Off the main thread, and on
    /// the same serial queue, so it cannot overlap an automatic pass.
    func restoreNow(completion: ((RestoreReport) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let report = self.coordinator.restore()
            DispatchQueue.main.async { completion?(report) }
        }
    }

    func saveNow(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.coordinator.save()
            self.previousMode = Self.currentModeNow()
            self.currentMode = self.previousMode
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    func runSelfTest(cycles: Int) {
        queue.async { SelfTest.runDeterminism(cycles: cycles) }
    }

    /// Test affordance for acceptance test 2, which otherwise needs a physical
    /// undock. Rewinds the remembered mode to `.laptop` and posts the real
    /// notification, so the entire chain runs for real — debounce, two-sample
    /// stability check, mode detection against live hardware, edge trigger,
    /// restore, verification pass. Only the hardware transition is simulated.
    func simulateDockTransition() {
        queue.async { [weak self] in
            guard let self else { return }
            self.previousMode = .laptop
            DebugLog.shared.note("simulating laptop -> desktop edge")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
            }
        }
    }

    func scatterNow() {
        queue.async {
            DebugLog.shared.heading("SCATTER")
            SelfTest.scatter(seed: UInt64(Date().timeIntervalSince1970))
            DebugLog.shared.note("scattered")
        }
    }
}
