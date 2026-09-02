import Foundation

/// Acceptance test 3, run in place.
///
/// The real test docks and undocks ten times. That cannot be automated, but the
/// thing it is actually looking for can: whether restore output depends on where
/// a window happened to be when the pass started. If it does — if anything reads
/// current geometry and adjusts it rather than recomputing from the saved record
/// — scattering differently on each cycle produces different results, and this
/// catches it. Deterministic scatter, so a failure is reproducible.
enum SelfTest {

    /// Small seeded LCG. Not cryptographic; it only has to be repeatable.
    struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func runDeterminism(cycles: Int, layoutID: String = LayoutStore.defaultLayoutID) {
        let log = DebugLog.shared
        let coordinator = LayoutCoordinator.shared
        log.heading("SELFTEST determinism — \(cycles) cycles")

        guard coordinator.save(layoutID: layoutID, name: "Desktop Layout") else {
            log.note("selftest aborted: save failed")
            return
        }

        var perCycle: [[String: Rect]] = []

        for cycle in 1...cycles {
            scatter(seed: UInt64(cycle) &* 7919)
            Thread.sleep(forTimeInterval: 0.4)
            _ = coordinator.restore(layoutID: layoutID)
            Thread.sleep(forTimeInterval: 0.4)
            perCycle.append(capture())
            log.note("cycle \(cycle): captured \(perCycle[cycle - 1].count) frames")
        }

        compare(perCycle, log: log)
    }

    /// Move every eligible window somewhere else inside its display, so each
    /// cycle's restore starts from a different arrangement.
    static func scatter(seed: UInt64) {
        var rng = Seeded(seed: seed)
        let displays = DisplayInventory.snapshot()
        let (windows, _) = WindowInventory.eligibleWindows(displays: displays)

        for window in windows {
            guard let frame = window.frame,
                  let display = DisplayInventory.display(for: frame, among: displays)
            else { continue }
            let v = display.visibleFrame

            let width = Double.random(in: 400...max(401, v.width * 0.7), using: &rng)
            let height = Double.random(in: 300...max(301, v.height * 0.7), using: &rng)
            let x = Double.random(in: v.minX...max(v.minX + 1, v.maxX - width), using: &rng)
            let y = Double.random(in: v.minY...max(v.minY + 1, v.maxY - height), using: &rng)

            let scattered = Rect(x: x, y: y, width: width, height: height)
                .clampedAndRounded(into: v)
            window.setPosition(scattered.origin)
            window.setSize(scattered.size)
        }
    }

    /// Current frames, keyed stably enough to compare across cycles.
    static func capture() -> [String: Rect] {
        let displays = DisplayInventory.snapshot()
        let (windows, _) = WindowInventory.eligibleWindows(displays: displays)
        var result: [String: Rect] = [:]
        for window in windows {
            guard let frame = window.frame else { continue }
            result["\(window.bundleIdentifier)#\(window.index)"] = frame
        }
        return result
    }

    static func compare(_ cycles: [[String: Rect]], log: DebugLog) {
        guard let reference = cycles.first else {
            log.note("SELFTEST: no cycles recorded")
            return
        }

        var drifting: [String] = []
        let keys = Set(cycles.flatMap { $0.keys }).sorted()

        for key in keys {
            let frames = cycles.map { $0[key] }
            guard let expected = reference[key] else {
                drifting.append("\(key): absent from cycle 1, present later")
                continue
            }
            for (index, frame) in frames.enumerated() {
                guard let frame else {
                    drifting.append("\(key): missing in cycle \(index + 1)")
                    break
                }
                if frame != expected {
                    drifting.append("\(key): cycle 1 \(expected.shortDescription) "
                                  + "vs cycle \(index + 1) \(frame.shortDescription)")
                    break
                }
            }
        }

        if drifting.isEmpty {
            log.note("SELFTEST PASS — \(keys.count) windows identical across "
                   + "\(cycles.count) cycles, no drift")
        } else {
            log.note("SELFTEST FAIL — \(drifting.count) of \(keys.count) windows drifted:")
            drifting.forEach { log.note("  " + $0) }
        }
    }
}

// MARK: - Matcher tests

extension SelfTest {

    /// Exercises SPEC section 12 under the conditions it exists for: several
    /// windows of one application, indices that no longer line up, and geometry
    /// that has just been disturbed. Pure logic — no window server needed.
    static func runMatcherTests() {
        let log = DebugLog.shared
        log.heading("SELFTEST matcher")

        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                log.note("  PASS  \(name)")
            } else {
                failures.append(name + (detail.isEmpty ? "" : " — " + detail))
                log.note("  FAIL  \(name)\(detail.isEmpty ? "" : " — " + detail)")
            }
        }

        let display = DisplaySnapshot(
            identity: DisplayIdentity(vendorNumber: 1, modelNumber: 2, serialNumber: 3,
                                      localizedName: "Test", pointWidth: 3360,
                                      pointHeight: 1890, isBuiltin: false),
            frame: Rect(x: 0, y: 0, width: 3360, height: 1890),
            visibleFrame: Rect(x: 0, y: 30, width: 3360, height: 1860),
            backingScale: 2, pixelWidth: 6720, pixelHeight: 3780)

        func saved(_ title: String, index: Int, frame: Rect) -> SavedWindow {
            SavedWindow(bundleIdentifier: "com.google.Chrome", applicationName: "Chrome",
                        title: title, windowIndex: index, subrole: "AXStandardWindow",
                        absoluteFrame: frame, display: display)
        }
        func candidate(_ title: String, index: Int, frame: Rect?) -> WindowMatcher.Candidate {
            WindowMatcher.Candidate(bundleID: "com.google.Chrome", title: title,
                                    index: index, frame: frame, key: "p#\(index)")
        }

        let gmailFrame = Rect(x: 100, y: 100, width: 1200, height: 900)
        let calendarFrame = Rect(x: 1800, y: 200, width: 1400, height: 1000)

        // 1. Titles must beat index when the two disagree. Live windows are
        //    presented in swapped index order, and their geometry is scrambled.
        do {
            let savedWindows = [saved("Inbox — Gmail", index: 0, frame: gmailFrame),
                                saved("Calendar — Week of 30 Aug", index: 1, frame: calendarFrame)]
            let live = [candidate("Calendar — Week of 30 Aug", index: 0,
                                  frame: Rect(x: 500, y: 700, width: 640, height: 480)),
                        candidate("Inbox — Gmail", index: 1,
                                  frame: Rect(x: 2200, y: 40, width: 900, height: 620))]
            let assignment = WindowMatcher.assign(saved: savedWindows, candidates: live)
            let map = Dictionary(uniqueKeysWithValues: assignment.pairs.map { ($0.saved, $0.candidate) })
            check("title beats index when they disagree",
                  map[0] == 1 && map[1] == 0,
                  "got \(map)")
        }

        // 2. Titles that changed since the save still pair sensibly, and never
        //    cross-pair two windows of the same application.
        do {
            let savedWindows = [saved("Inbox — Gmail", index: 0, frame: gmailFrame),
                                saved("Calendar — Week of 30 Aug", index: 1, frame: calendarFrame)]
            let live = [candidate("Calendar — Week of 6 Sep", index: 0, frame: calendarFrame),
                        candidate("Drafts — Gmail", index: 1, frame: gmailFrame)]
            let assignment = WindowMatcher.assign(saved: savedWindows, candidates: live)
            let map = Dictionary(uniqueKeysWithValues: assignment.pairs.map { ($0.saved, $0.candidate) })
            check("changed titles still pair by similarity + geometry",
                  map[0] == 1 && map[1] == 0,
                  "got \(map)")
        }

        // 3. One-to-one: two saved, one live. One pair, one unmatched, never a
        //    double assignment.
        do {
            let savedWindows = [saved("Inbox — Gmail", index: 0, frame: gmailFrame),
                                saved("Calendar — Week of 30 Aug", index: 1, frame: calendarFrame)]
            let live = [candidate("Inbox — Gmail", index: 0, frame: gmailFrame)]
            let assignment = WindowMatcher.assign(saved: savedWindows, candidates: live)
            check("fewer live windows than saved: one pair, one unmatched",
                  assignment.pairs.count == 1 && assignment.unmatchedSaved == [1],
                  "pairs \(assignment.pairs.count), unmatched \(assignment.unmatchedSaved)")
        }

        // 4. Live windows with no saved entry are never touched.
        do {
            let savedWindows = [saved("Inbox — Gmail", index: 0, frame: gmailFrame)]
            let live = [candidate("Inbox — Gmail", index: 0, frame: gmailFrame),
                        candidate("A brand new window", index: 1, frame: calendarFrame)]
            let assignment = WindowMatcher.assign(saved: savedWindows, candidates: live)
            check("extra live windows are left untouched",
                  assignment.pairs.count == 1 && assignment.untouchedCandidates == [1],
                  "pairs \(assignment.pairs.count), untouched \(assignment.untouchedCandidates)")
        }

        // 5. An application present in the layout but no longer running.
        do {
            let savedWindows = [saved("Inbox — Gmail", index: 0, frame: gmailFrame)]
            let assignment = WindowMatcher.assign(saved: savedWindows, candidates: [])
            check("application quit: saved entry unmatched, nothing crashes",
                  assignment.pairs.isEmpty && assignment.unmatchedSaved == [0])
        }

        // 6. Empty titles must not score as an exact match against each other.
        do {
            let savedWindows = [saved("", index: 0, frame: gmailFrame)]
            let live = [candidate("", index: 5, frame: nil)]
            let (score, _) = WindowMatcher.score(savedWindows[0], live[0])
            check("two empty titles do not count as an exact title match",
                  score < WindowMatcher.Points.exactTitle,
                  String(format: "score %.0f", score))
        }

        // 7. Similarity behaves at the edges.
        do {
            check("identical titles score 1.0",
                  WindowMatcher.titleSimilarity("abc def", "abc def") == 1.0)
            check("disjoint titles score 0.0",
                  WindowMatcher.titleSimilarity("aaaa", "bbbb") == 0.0)
            let partial = WindowMatcher.titleSimilarity(
                "Project Notes — Google Chrome", "Team Calendar — Google Chrome")
            check("shared suffix gives partial credit",
                  partial > 0.3 && partial < 0.9,
                  String(format: "%.2f", partial))
        }

        if failures.isEmpty {
            log.note("SELFTEST MATCHER PASS")
        } else {
            log.note("SELFTEST MATCHER FAIL — \(failures.count) case(s):")
            failures.forEach { log.note("  " + $0) }
        }
    }
}
