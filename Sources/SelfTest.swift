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

// MARK: - Display tests

extension SelfTest {

    /// Everything here is synthetic, which is the point: it exercises display
    /// arrangements and monitor identities this machine does not have. Only one
    /// configuration was ever available to test against for real — a single
    /// external 4K at 2.0 scale reporting a non-zero serial — so the awkward
    /// cases other people will hit are covered here or not at all.
    static func runDisplayTests() {
        let log = DebugLog.shared
        log.heading("SELFTEST displays")

        var failures: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition { log.note("  PASS  \(name)") }
            else {
                failures.append(name)
                log.note("  FAIL  \(name)\(detail.isEmpty ? "" : " — " + detail)")
            }
        }

        // ---- Coordinate transform across display arrangements ----
        //
        // AppKit origin is the bottom-left of the display at (0, 0); CG origin
        // is its top-left. A display above the primary therefore has NEGATIVE
        // y in CG, and one below has y greater than the primary's height.
        // Getting these signs wrong is how a window lands off-screen.
        let H = 1080.0   // a 1920x1080 primary

        check("primary maps to CG origin",
              Coordinates.toCG(CGRect(x: 0, y: 0, width: 1920, height: 1080), flipHeight: H)
                == Rect(x: 0, y: 0, width: 1920, height: 1080))

        check("display above primary gets negative CG y",
              Coordinates.toCG(CGRect(x: 0, y: 1080, width: 1920, height: 1080), flipHeight: H)
                == Rect(x: 0, y: -1080, width: 1920, height: 1080))

        check("display below primary gets CG y past the primary",
              Coordinates.toCG(CGRect(x: 0, y: -1080, width: 1920, height: 1080), flipHeight: H)
                == Rect(x: 0, y: 1080, width: 1920, height: 1080))

        check("display left of primary keeps negative x",
              Coordinates.toCG(CGRect(x: -2560, y: 0, width: 2560, height: 1440), flipHeight: H)
                == Rect(x: -2560, y: -360, width: 2560, height: 1440))

        check("a window inside the primary flips correctly",
              Coordinates.toCG(CGRect(x: 100, y: 100, width: 800, height: 600), flipHeight: H)
                == Rect(x: 100, y: 380, width: 800, height: 600))

        // The transform must be its own inverse, on every arrangement.
        let arrangements = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: -2560, y: -300, width: 2560, height: 1440),
            CGRect(x: 340, y: -1234, width: 1512, height: 982),
        ]
        check("toAppKit(toCG(r)) == r on every arrangement",
              arrangements.allSatisfy {
                  Coordinates.toAppKit(Coordinates.toCG($0, flipHeight: H), flipHeight: H) == $0
              })

        // ---- Identity matching ----
        func identity(vendor: UInt32 = 100, model: UInt32 = 200, serial: UInt32 = 300,
                      name: String = "Acme 27", width: Double = 2560,
                      height: Double = 1440, builtin: Bool = false) -> DisplayIdentity {
            DisplayIdentity(vendorNumber: vendor, modelNumber: model, serialNumber: serial,
                            localizedName: name, pointWidth: width, pointHeight: height,
                            isBuiltin: builtin)
        }

        check("identical monitors match on vendor+model+serial",
              DisplayInventory.match(identity(), identity()) == .vendorModelSerial)

        // The important one. A great many monitors report serial 0, and if that
        // counted as a match, every serial-0 monitor would look like every
        // other one. Tier 1 must refuse a zero serial.
        check("serial 0 does NOT match on the serial tier",
              DisplayInventory.match(identity(serial: 0), identity(serial: 0)) == .vendorModelName,
              "\(DisplayInventory.match(identity(serial: 0), identity(serial: 0)).label)")

        check("two different serial-0 models do not match at all",
              DisplayInventory.match(identity(model: 200, serial: 0, name: "Acme 27", width: 2560),
                                     identity(model: 999, serial: 0, name: "Other 24", width: 1920))
                == .none)

        check("same monitor, renamed by macOS, still matches on serial",
              DisplayInventory.match(identity(name: "Acme 27"), identity(name: "Acme 27 (2)"))
                == .vendorModelSerial)

        check("a resolution change does not break serial matching",
              DisplayInventory.match(identity(width: 1920, height: 1080), identity())
                == .vendorModelSerial)

        check("unknown vendor falls back to name + size",
              DisplayInventory.match(identity(vendor: 0, model: 0, serial: 0),
                                     identity(vendor: 0, model: 0, serial: 0))
                == .nameAndSize)

        check("size-only match is reported as weak",
              DisplayInventory.match(identity(vendor: 0, model: 0, serial: 0, name: "A"),
                                     identity(vendor: 0, model: 0, serial: 0, name: "B")).isWeak)

        // ---- Snapshot behaviour that restore depends on ----
        func display(_ id: DisplayIdentity, visible: Rect, scale: Double) -> DisplaySnapshot {
            DisplaySnapshot(identity: id,
                            frame: Rect(x: visible.x, y: 0, width: visible.width,
                                        height: visible.height + 30),
                            visibleFrame: visible, backingScale: scale,
                            pixelWidth: Int(visible.width * scale),
                            pixelHeight: Int(visible.height * scale))
        }
        let hidpi = display(identity(), visible: Rect(x: 0, y: 30, width: 2560, height: 1410), scale: 2)
        let lodpi = display(identity(), visible: Rect(x: 0, y: 30, width: 2560, height: 1410), scale: 1)

        check("same size but different backing scale is NOT pixel-exact replayable",
              !hidpi.isGeometricallyIdentical(to: lodpi))
        check("same size and scale is pixel-exact replayable",
              hidpi.isGeometricallyIdentical(to: hidpi))

        // ---- Mode detection ----
        let builtin = display(identity(name: "Built-in", width: 1512, height: 982, builtin: true),
                              visible: Rect(x: 0, y: 30, width: 1512, height: 952), scale: 2)
        let external = hidpi

        check("laptop only, no layout saved -> laptop",
              DisplayInventory.mode(for: [builtin], savedTargets: []) == .laptop)
        check("external present, no layout saved -> desktop",
              DisplayInventory.mode(for: [external], savedTargets: []) == .desktop)
        check("the saved monitor is attached -> desktop",
              DisplayInventory.mode(for: [external], savedTargets: [external.identity]) == .desktop)
        check("a DIFFERENT external monitor is attached -> laptop, not desktop",
              DisplayInventory.mode(for: [display(identity(vendor: 7, model: 7, serial: 7, name: "Hotel TV",
                                                           width: 1920, height: 1080),
                                                  visible: Rect(x: 0, y: 30, width: 1920, height: 1050), scale: 1)],
                                    savedTargets: [external.identity]) == .laptop)

        // The travel case that motivated the rule above: a projector or hotel
        // screen at a resolution the desk monitor also uses must not be taken
        // for the desk monitor.
        check("an unidentifiable screen of the SAME size is not the desk monitor",
              DisplayInventory.mode(for: [display(identity(vendor: 0, model: 0, serial: 0,
                                                           name: "Conference Room", width: 2560, height: 1440),
                                                  visible: Rect(x: 0, y: 30, width: 2560, height: 1410), scale: 2)],
                                    savedTargets: [external.identity]) == .laptop)
        check("lid open, saved monitor also attached -> desktop",
              DisplayInventory.mode(for: [builtin, external],
                                    savedTargets: [external.identity]) == .desktop)

        // ---- Assigning a window to a display, multi-display ----
        let left = display(identity(name: "Left"), visible: Rect(x: 0, y: 30, width: 2560, height: 1410), scale: 2)
        let right = display(identity(name: "Right"), visible: Rect(x: 2560, y: 30, width: 1920, height: 1050), scale: 1)

        check("a window is assigned to the display containing its centre",
              DisplayInventory.display(for: Rect(x: 2700, y: 100, width: 600, height: 400),
                                       among: [left, right])?.identity.localizedName == "Right")
        check("a window straddling two displays goes to the larger overlap",
              DisplayInventory.display(for: Rect(x: 2400, y: 100, width: 900, height: 400),
                                       among: [left, right])?.identity.localizedName == "Right")

        // ---- Clamping onto a smaller display ----
        // The travel case: a layout saved on a big monitor, replayed on a
        // small one. Nothing may end up off-screen.
        let small = Rect(x: 0, y: 30, width: 1440, height: 870)
        let oversized = Rect(x: 200, y: 100, width: 3000, height: 1600)
        let fitted = oversized.clampedAndRounded(into: small)
        check("an oversized window is clamped inside the smaller display",
              fitted.minX >= small.minX && fitted.minY >= small.minY
                && fitted.maxX <= small.maxX && fitted.maxY <= small.maxY,
              fitted.shortDescription)
        check("clamping produces whole points",
              fitted == fitted.rounded, fitted.shortDescription)

        if failures.isEmpty { log.note("SELFTEST DISPLAYS PASS") }
        else { log.note("SELFTEST DISPLAYS FAIL — \(failures.count) case(s)") }
    }
}
