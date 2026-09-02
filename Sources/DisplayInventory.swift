import Foundation
import AppKit
import CoreGraphics

/// Stable identity for a physical display.
///
/// `CGDirectDisplayID` is deliberately absent: it is a runtime handle that
/// changes across reconnects (the desk monitor currently enumerates as 3) and
/// must never be persisted or matched on.
struct DisplayIdentity: Codable, Equatable, Hashable {
    var vendorNumber: UInt32
    var modelNumber: UInt32
    var serialNumber: UInt32
    var localizedName: String
    var pointWidth: Double
    var pointHeight: Double
    var isBuiltin: Bool

    var shortDescription: String {
        "\(localizedName) [\(vendorNumber)/\(modelNumber)/\(serialNumber)] "
            + String(format: "%.0fx%.0f", pointWidth, pointHeight)
    }
}

/// How confidently a live display was matched to a saved one. Ordered, so the
/// best available match wins and a weak one can be logged as such.
enum DisplayMatch: Int, Comparable {
    case none = 0
    case sizeOnly = 1           // last resort, logged as weak
    case nameAndSize = 2
    case vendorModelName = 3
    case vendorModelSerial = 4  // the desk monitor reaches this, so matching stops here

    static func < (a: DisplayMatch, b: DisplayMatch) -> Bool { a.rawValue < b.rawValue }

    var isWeak: Bool { self == .sizeOnly }

    var label: String {
        switch self {
        case .none:             return "no match"
        case .sizeOnly:         return "size only (weak)"
        case .nameAndSize:      return "name + size"
        case .vendorModelName:  return "vendor + model + name"
        case .vendorModelSerial:return "vendor + model + serial"
        }
    }
}

/// One display as it exists right now, in CG top-left points.
struct DisplaySnapshot: Codable, Equatable {
    var identity: DisplayIdentity
    var frame: Rect
    var visibleFrame: Rect
    var backingScale: Double
    var pixelWidth: Int
    var pixelHeight: Int

    /// Runtime handle only — never encoded, never matched on.
    var displayID: CGDirectDisplayID = 0

    enum CodingKeys: String, CodingKey {
        case identity, frame, visibleFrame, backingScale, pixelWidth, pixelHeight
    }

    /// True when a saved layout's geometry can be replayed pixel-exact rather
    /// than proportionally: same usable area, same backing scale.
    func isGeometricallyIdentical(to other: DisplaySnapshot) -> Bool {
        visibleFrame.size == other.visibleFrame.size && backingScale == other.backingScale
    }
}

enum ScreenMode: String {
    case laptop
    case desktop
}

/// Enumerates screens, derives stable identity, and owns all coordinate maths.
/// Knows nothing about windows.
enum DisplayInventory {

    /// Every active display, in CG top-left points.
    static func snapshot() -> [DisplaySnapshot] {
        let H = Coordinates.flipHeight
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let did = CGDirectDisplayID(number.uint32Value)

            let frame = Coordinates.toCG(screen.frame, flipHeight: H)
            let visible = Coordinates.toCG(screen.visibleFrame, flipHeight: H)

            let mode = CGDisplayCopyDisplayMode(did)
            let identity = DisplayIdentity(
                vendorNumber: CGDisplayVendorNumber(did),
                modelNumber: CGDisplayModelNumber(did),
                serialNumber: CGDisplaySerialNumber(did),
                localizedName: screen.localizedName,
                pointWidth: frame.width,
                pointHeight: frame.height,
                isBuiltin: CGDisplayIsBuiltin(did) != 0)

            return DisplaySnapshot(
                identity: identity,
                frame: frame,
                visibleFrame: visible,
                backingScale: Double(screen.backingScaleFactor),
                pixelWidth: mode?.pixelWidth ?? Int(frame.width),
                pixelHeight: mode?.pixelHeight ?? Int(frame.height),
                displayID: did)
        }
    }

    /// Debug-build assertion from SPEC section 7: `toCG(screen.frame)` must
    /// equal `CGDisplayBounds(displayID)`. If these ever disagree the flip is
    /// wrong and every frame downstream is garbage.
    static func verifyCoordinateConversion() -> [String] {
        var problems: [String] = []
        for display in snapshot() {
            let bounds = Rect(cg: CGDisplayBounds(display.displayID))
            if display.frame != bounds {
                problems.append("\(display.identity.localizedName): toCG(frame) "
                    + "\(display.frame.shortDescription) != CGDisplayBounds "
                    + "\(bounds.shortDescription)")
            }
        }
        return problems
    }

    // MARK: - Identity matching

    /// Match priority from SPEC section 8, best first.
    static func match(_ live: DisplayIdentity, _ saved: DisplayIdentity) -> DisplayMatch {
        if live.vendorNumber == saved.vendorNumber,
           live.modelNumber == saved.modelNumber,
           live.serialNumber == saved.serialNumber,
           saved.serialNumber != 0 {
            return .vendorModelSerial
        }
        if live.vendorNumber == saved.vendorNumber,
           live.modelNumber == saved.modelNumber,
           live.localizedName == saved.localizedName {
            return .vendorModelName
        }
        if live.localizedName == saved.localizedName,
           live.pointWidth == saved.pointWidth,
           live.pointHeight == saved.pointHeight {
            return .nameAndSize
        }
        if live.pointWidth == saved.pointWidth, live.pointHeight == saved.pointHeight {
            return .sizeOnly
        }
        return .none
    }

    /// Best live display for a saved identity, with the strength of the match
    /// so a weak one can be logged.
    static func bestMatch(for saved: DisplayIdentity,
                          among live: [DisplaySnapshot]) -> (DisplaySnapshot, DisplayMatch)? {
        var best: (DisplaySnapshot, DisplayMatch)?
        for candidate in live {
            let strength = match(candidate.identity, saved)
            guard strength != .none else { continue }
            if best == nil || strength > best!.1 { best = (candidate, strength) }
        }
        return best
    }

    /// The display a rect belongs to: whose visibleFrame contains its centre,
    /// else the largest intersection, else the main display (SPEC section 13).
    static func display(for rect: Rect, among displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        if let hit = displays.first(where: { $0.visibleFrame.contains(rect.center) }) {
            return hit
        }
        let overlapping = displays
            .map { ($0, rect.intersectionArea($0.visibleFrame)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        if let overlapping { return overlapping.0 }
        return displays.first { $0.displayID == CGMainDisplayID() } ?? displays.first
    }

    // MARK: - Mode and fingerprint

    /// `.desktop` when at least one active display is non-builtin and, once a
    /// layout exists, its identity matches that layout's target display.
    /// Before any layout is saved, any external display counts, so the menu
    /// shows the right thing on first run.
    static func mode(for displays: [DisplaySnapshot],
                     savedTargets: [DisplayIdentity]) -> ScreenMode {
        let externals = displays.filter { !$0.identity.isBuiltin }
        guard !externals.isEmpty else { return .laptop }
        guard !savedTargets.isEmpty else { return .desktop }
        for saved in savedTargets where saved.isBuiltin == false {
            if externals.contains(where: { match($0.identity, saved) != .none }) {
                return .desktop
            }
        }
        return .laptop
    }

    /// Hash over the sorted set of active displays, their identities and their
    /// bounds. Two identical fingerprints 0.6 s apart mean the display
    /// configuration has stopped moving.
    static func fingerprint(of displays: [DisplaySnapshot]) -> String {
        displays
            .map { "\($0.identity.shortDescription)@\($0.frame.shortDescription)"
                 + "/\($0.visibleFrame.shortDescription)/\($0.backingScale)" }
            .sorted()
            .joined(separator: "|")
    }

    static var externalDisplayName: String? {
        snapshot().first { !$0.identity.isBuiltin }?.identity.localizedName
    }
}
