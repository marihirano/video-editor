import CoreGraphics
import Foundation

/// Turns a cursor position on the Mac's screens into a position in the recording's pixels.
///
/// Screen positions use macOS's global screen points with the origin at the top-left of the main
/// display and y going down (what `CGEvent.location`, `SCDisplay.frame` and `SCWindow.frame` use).
/// Other displays sit at offsets from it, including negative ones (a display left of or above the main one).
public struct CaptureGeometry: Equatable, Sendable {
    /// The recorded part of the screen, in global points.
    public var frame: CGRect
    /// Video pixels per point (2 on Retina).
    public var scale: Double

    public init(frame: CGRect, scale: Double) { self.frame = frame; self.scale = scale }

    /// Size of the video this capture makes, in pixels (rounded to even numbers, which encoders need).
    public var pixelSize: (width: Int, height: Int) {
        (Self.even(frame.width * scale), Self.even(frame.height * scale))
    }

    /// A global screen point → video pixels (may be outside 0…size when the cursor is outside the area).
    public func pixel(fromGlobal p: CGPoint) -> CGPoint {
        let s = pixelSize
        // Exact factors, so the far edge of the area lands exactly on the far edge of the video.
        let sx = frame.width > 0 ? Double(s.width) / frame.width : scale
        let sy = frame.height > 0 ? Double(s.height) / frame.height : scale
        return CGPoint(x: (p.x - frame.minX) * sx, y: (p.y - frame.minY) * sy)
    }

    /// An area drawn on one display, given in that display's own points (top-left origin), → global points.
    public static func globalRect(_ local: CGRect, onDisplayAt displayFrame: CGRect) -> CGRect {
        local.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
    }

    /// AppKit's bottom-left screen coordinates (NSEvent.mouseLocation, NSWindow frames) → global top-left points.
    /// `mainDisplayHeight` is the height of the main display (the one with the menu bar) in points.
    public static func globalPoint(fromAppKit p: CGPoint, mainDisplayHeight: Double) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    public static func globalRect(fromAppKit r: CGRect, mainDisplayHeight: Double) -> CGRect {
        CGRect(x: r.minX, y: mainDisplayHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Snaps an area to whole pixels on its display and keeps it inside the display.
    public static func clampArea(_ area: CGRect, to display: CGRect, scale: Double, minimumPoints: Double) -> CGRect {
        var r = area.standardized.intersection(display)
        if r.isNull { r = display }
        let snap = { (v: Double) in (v * scale).rounded() / scale }
        r = CGRect(x: snap(r.minX), y: snap(r.minY), width: max(snap(r.width), minimumPoints), height: max(snap(r.height), minimumPoints))
        if r.maxX > display.maxX { r.origin.x = display.maxX - r.width }
        if r.maxY > display.maxY { r.origin.y = display.maxY - r.height }
        return r
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
}
