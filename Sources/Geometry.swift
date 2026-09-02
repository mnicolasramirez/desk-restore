import Foundation
import AppKit
import CoreGraphics

/// A rectangle in CoreGraphics top-left point space.
///
/// Desk Restore speaks CG points everywhere: origin at the top-left of the
/// primary display, y increasing downward, and points rather than pixels
/// because the desk monitor runs a scaled HiDPI mode. AppKit rectangles are
/// converted exactly once, on the way in — see `Coordinates.toCG`.
struct Rect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Wraps a CGRect that is *already* in CG top-left space. The Accessibility
    /// API hands us these directly; NSScreen does not, so never call this on an
    /// NSScreen rect.
    init(cg r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y),
                  width: Double(r.size.width), height: Double(r.size.height))
    }

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var origin: CGPoint { CGPoint(x: x, y: y) }
    var size: CGSize { CGSize(width: width, height: height) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    func contains(_ p: CGPoint) -> Bool {
        Double(p.x) >= minX && Double(p.x) < maxX && Double(p.y) >= minY && Double(p.y) < maxY
    }

    /// Area of overlap with another rect, 0 when they do not intersect.
    func intersectionArea(_ other: Rect) -> Double {
        let w = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let h = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        return w * h
    }

    var rounded: Rect {
        Rect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Largest coordinate difference against another rect, in points. Used for
    /// the +/- 2 point tolerance when verifying an applied frame.
    func maxDeviation(from other: Rect) -> Double {
        max(abs(x - other.x), abs(y - other.y),
            abs(width - other.width), abs(height - other.height))
    }

    /// Clamp into a container, then round — in that order, per SPEC section 7.
    /// Rounding after clamping keeps the result inside the container; rounding
    /// first can push a window one point off the edge.
    func clampedAndRounded(into v: Rect) -> Rect {
        var w = self
        w.width = min(w.width, v.width)
        w.height = min(w.height, v.height)
        w.x = min(max(w.x, v.minX), v.maxX - w.width)
        w.y = min(max(w.y, v.minY), v.maxY - w.height)
        return w.rounded
    }

    var shortDescription: String {
        String(format: "(%.0f, %.0f, %.0f x %.0f)", x, y, width, height)
    }
}

/// A frame expressed as fractions of its display's visibleFrame, 0...1.
/// The fallback when the target display's geometry no longer matches what was
/// saved. Field names match the on-disk JSON in SPEC section 13.
struct NormalizedFrame: Codable, Equatable {
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double
}

/// The AppKit-to-CoreGraphics conversion, isolated so there is exactly one
/// place where a sign error can live.
///
/// AppKit puts the origin at the bottom-left of the primary display with y
/// increasing upward. CoreGraphics and the Accessibility API put it at the
/// top-left with y increasing downward. The transform is its own inverse.
enum Coordinates {

    /// Height of the AppKit global coordinate space: the max-y of the display
    /// that defines the origin.
    ///
    /// `NSScreen.screens[0]` is documented as the display carrying the menu
    /// bar, and therefore the one at AppKit origin (0, 0). Rather than trust
    /// that, this looks for the screen actually at the origin and falls back to
    /// index 0. The two agree on every normal setup; if they ever diverge, the
    /// derived value is the correct one, and `verifyCoordinateConversion()`
    /// would catch it either way.
    static var flipHeight: Double {
        let screens = NSScreen.screens
        let origin = screens.first { $0.frame.origin == .zero } ?? screens.first
        return Double(origin?.frame.maxY ?? 0)
    }

    static func toCG(_ r: CGRect, flipHeight H: Double) -> Rect {
        Rect(x: Double(r.origin.x),
             y: H - Double(r.maxY),
             width: Double(r.size.width),
             height: Double(r.size.height))
    }

    static func toAppKit(_ r: Rect, flipHeight H: Double) -> CGRect {
        CGRect(x: r.x, y: H - r.maxY, width: r.width, height: r.height)
    }
}
