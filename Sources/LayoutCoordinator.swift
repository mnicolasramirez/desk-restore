import Foundation
import AppKit

/// What happened when a target frame was pushed onto a window.
enum ApplyOutcome {
    case exact(Rect)
    /// Landed close but not exact. Some applications legitimately quantise
    /// their size — Terminal snaps to character cells. Not an error.
    case constrained(requested: Rect, achieved: Rect)
    case failed(String)
}

struct RestoreReport {
    var exact = 0
    var constrained = 0
    var failed = 0
    var unmatchedSaved = 0
    var untouchedLive = 0

    var summary: String {
        "exact \(exact), constrained \(constrained), failed \(failed), "
            + "unmatched-saved \(unmatchedSaved), untouched-live \(untouchedLive)"
    }
}

/// The only orchestrator: save, restore, retry, match. Knows nothing about UI.
///
/// Blocking sleeps live here, so every entry point must be called off the main
/// thread once there is a UI to block.
final class LayoutCoordinator {

    static let shared = LayoutCoordinator()

    /// SPEC section 10. Some applications quantise their geometry, so a window
    /// that lands within this is recorded as placed, not as an error.
    static let tolerance: Double = 2.0
    static let retryDelay: TimeInterval = 0.25
    static let maximumAttempts = 3

    private let log = DebugLog.shared

    // MARK: - Save

    @discardableResult
    func save(layoutID: String = LayoutStore.defaultLayoutID,
              name: String = "Desktop Layout") -> Bool {
        log.heading("SAVE \(layoutID)")

        guard Permissions.isTrusted else {
            log.note("save aborted: Accessibility permission not granted")
            return false
        }

        let displays = DisplayInventory.snapshot()
        for problem in DisplayInventory.verifyCoordinateConversion() {
            log.note("COORDINATE CHECK FAILED — \(problem)")
        }
        guard !displays.isEmpty else {
            log.note("save aborted: no active displays")
            return false
        }

        let (windows, skipped) = WindowInventory.eligibleWindows(displays: displays)
        var records: [SavedWindow] = []

        for window in windows {
            guard let frame = window.frame else {
                log.debug("skip \(window.bundleIdentifier): frame unreadable at save time")
                continue
            }
            guard let display = DisplayInventory.display(for: frame, among: displays) else {
                log.debug("skip \(window.bundleIdentifier): no display owns \(frame.shortDescription)")
                continue
            }
            let record = SavedWindow(bundleIdentifier: window.bundleIdentifier,
                                     applicationName: window.applicationName,
                                     title: window.title,
                                     windowIndex: window.index,
                                     subrole: window.subrole,
                                     absoluteFrame: frame,
                                     display: display)
            records.append(record)
            log.debug("save \(window.bundleIdentifier)[\(window.index)] "
                    + "\(frame.shortDescription) local \(record.displayLocalFrame.shortDescription) "
                    + "on \(display.identity.localizedName)  \"\(window.title)\"")
        }

        let layout = Layout(id: layoutID, name: name, savedAt: Date(),
                            displays: displays, windows: records)
        do {
            var file = (try? LayoutStore.load()) ?? .empty
            file.version = LayoutFile.currentVersion
            file.upsert(layout)
            try LayoutStore.save(file)
        } catch {
            log.note("save FAILED writing \(LayoutStore.url.path): \(error)")
            return false
        }

        log.note("saved \(records.count) windows across \(displays.count) display(s); "
               + "\(skipped.count) skipped")
        for skip in skipped {
            log.debug("  skipped \(skip.application) — \(skip.reason)")
        }
        return true
    }

    // MARK: - Restore

    @discardableResult
    func restore(layoutID: String = LayoutStore.defaultLayoutID) -> RestoreReport {
        log.heading("RESTORE \(layoutID)")
        var report = RestoreReport()

        guard Permissions.isTrusted else {
            log.note("restore aborted: Accessibility permission not granted")
            return report
        }
        guard let file = try? LayoutStore.load(), let layout = file.layout(id: layoutID) else {
            log.note("restore aborted: no saved layout '\(layoutID)'")
            return report
        }

        let displays = DisplayInventory.snapshot()
        for problem in DisplayInventory.verifyCoordinateConversion() {
            log.note("COORDINATE CHECK FAILED — \(problem)")
        }

        let (live, _) = WindowInventory.eligibleWindows(displays: displays)
        let matched = WindowMatcher.pair(saved: layout.windows, live: live)
        report.unmatchedSaved = matched.unmatchedSaved.count
        report.untouchedLive = matched.untouchedLive.count

        for entry in matched.unmatchedSaved {
            log.debug("unmatched saved: \(entry.bundleIdentifier)[\(entry.windowIndex)] "
                    + "\"\(entry.title)\" — no live window")
        }

        for pair in matched.pairs {
            guard let target = targetFrame(for: pair.saved, layout: layout, displays: displays) else {
                report.failed += 1
                log.note("FAILED \(pair.saved.bundleIdentifier)[\(pair.saved.windowIndex)]: "
                       + "no display matches saved identity "
                       + "\(pair.saved.displayIdentity.shortDescription)")
                continue
            }

            switch apply(target, to: pair.live) {
            case .exact(let achieved):
                report.exact += 1
                log.debug("ok \(pair.saved.bundleIdentifier)[\(pair.live.index)] "
                        + "-> \(achieved.shortDescription)  "
                        + "[match \(String(format: "%.0f", pair.score)): \(pair.reason)]")
            case .constrained(let requested, let achieved):
                report.constrained += 1
                log.note("CONSTRAINED \(pair.saved.bundleIdentifier)[\(pair.live.index)] "
                       + "requested \(requested.shortDescription) "
                       + "achieved \(achieved.shortDescription) "
                       + String(format: "(off by %.1f pt)", achieved.maxDeviation(from: requested)))
            case .failed(let reason):
                report.failed += 1
                log.note("FAILED \(pair.saved.bundleIdentifier)[\(pair.live.index)]: \(reason)")
            }
        }

        log.note("restore complete — \(report.summary)")
        return report
    }

    /// Second look after an automatic restore, once windows have had time to
    /// settle. Re-applies only the ones that missed — targets are recomputed
    /// from the saved record, never from what the window is doing now, so a
    /// repair pass cannot introduce drift either.
    @discardableResult
    func verifyAndRepair(layoutID: String = LayoutStore.defaultLayoutID) -> Int {
        guard Permissions.isTrusted,
              let file = try? LayoutStore.load(),
              let layout = file.layout(id: layoutID)
        else { return 0 }

        let displays = DisplayInventory.snapshot()
        let (live, _) = WindowInventory.eligibleWindows(displays: displays)
        let matched = WindowMatcher.pair(saved: layout.windows, live: live)

        var repaired = 0
        for pair in matched.pairs {
            guard let target = targetFrame(for: pair.saved, layout: layout, displays: displays),
                  let actual = pair.live.frame
            else { continue }
            guard actual.maxDeviation(from: target) > LayoutCoordinator.tolerance else { continue }

            log.debug("repair \(pair.saved.bundleIdentifier)[\(pair.live.index)] "
                    + "\(actual.shortDescription) -> \(target.shortDescription)")
            if case .exact = apply(target, to: pair.live) { repaired += 1 }
        }
        if repaired > 0 { log.note("verification repaired \(repaired) window(s)") }
        else { log.debug("verification: nothing to repair") }
        return repaired
    }

    // MARK: - Geometry

    /// Computes a target frame purely from the *saved* record and the *current*
    /// display. It never reads the window's present position — reading current
    /// geometry and adjusting it is the classic drift bug and is prohibited
    /// here (SPEC section 7). Identical inputs give identical output, so ten
    /// dock cycles produce ten identical frames.
    func targetFrame(for saved: SavedWindow, layout: Layout,
                     displays: [DisplaySnapshot]) -> Rect? {
        guard let (liveDisplay, strength) =
                DisplayInventory.bestMatch(for: saved.displayIdentity, among: displays)
        else { return nil }

        if strength.isWeak {
            log.debug("weak display match for \(saved.bundleIdentifier): "
                    + "\(strength.label) -> \(liveDisplay.identity.localizedName)")
        }

        let v = liveDisplay.visibleFrame
        let savedDisplay = layout.savedDisplay(for: saved.displayIdentity)
        let canReplayExactly = savedDisplay.map { liveDisplay.isGeometricallyIdentical(to: $0) } ?? false

        let target: Rect
        if canReplayExactly {
            let local = saved.displayLocalFrame
            target = Rect(x: v.minX + local.x, y: v.minY + local.y,
                          width: local.width, height: local.height)
        } else {
            let n = saved.normalized
            target = Rect(x: v.minX + n.normalizedX * v.width,
                          y: v.minY + n.normalizedY * v.height,
                          width: n.normalizedWidth * v.width,
                          height: n.normalizedHeight * v.height)
            log.debug("proportional restore for \(saved.bundleIdentifier): saved visibleFrame "
                    + "\(savedDisplay?.visibleFrame.shortDescription ?? "unknown") "
                    + "now \(v.shortDescription)")
        }

        return target.clampedAndRounded(into: v)
    }

    // MARK: - Applying a frame

    /// Position first, then size, then correct the origin the resize shifted.
    ///
    /// macOS clamps a resize against the display the window currently occupies.
    /// Moving a small laptop-sized window onto the large monitor and resizing in
    /// one step silently truncates the resize, because at the moment of the
    /// resize the window still belongs to the old display. So: move, grow, then
    /// fix the origin (SPEC section 10).
    func apply(_ target: Rect, to window: AXWindow) -> ApplyOutcome {
        var lastAchieved: Rect?

        for attempt in 1...LayoutCoordinator.maximumAttempts {
            window.setPosition(target.origin)
            window.setSize(target.size)

            guard let first = window.frame else {
                return .failed("frame unreadable after attempt \(attempt)")
            }
            lastAchieved = first
            if first.maxDeviation(from: target) <= LayoutCoordinator.tolerance {
                return .exact(first)
            }

            // The resize moved the origin; push both again.
            window.setPosition(target.origin)
            window.setSize(target.size)

            guard let second = window.frame else {
                return .failed("frame unreadable after correction on attempt \(attempt)")
            }
            lastAchieved = second
            if second.maxDeviation(from: target) <= LayoutCoordinator.tolerance {
                return .exact(second)
            }

            if attempt < LayoutCoordinator.maximumAttempts {
                Thread.sleep(forTimeInterval: LayoutCoordinator.retryDelay)
            }
        }

        guard let achieved = lastAchieved else { return .failed("frame never readable") }
        return .constrained(requested: target, achieved: achieved)
    }
}
