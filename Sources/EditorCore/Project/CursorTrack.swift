import Foundation

/// The cursor and clicks recorded with a screen recording made in the app (P1). P2 draws the cursor
/// from it; the recording itself never shows the system cursor. Imported videos keep this empty.
///
/// Positions are in the **recording's own pixels** (0,0 = top-left of the video frame, before any crop),
/// so a Retina recording, a second display, a window or an area all work the same way.
/// Times are in **source seconds** on the video's clock (0 = the first frame), with pauses removed.
public struct CursorTrack: Codable, Equatable, Sendable {
    /// Format of this slot, bumped if its meaning changes.
    public var version: Int = 1
    /// What was recorded (nil for imported videos and projects from before P1).
    public var capture: CaptureInfo? = nil
    /// Where the cursor was, sampled while it moves (and once when recording starts).
    public var samples: [CursorSample] = []
    /// Mouse button presses and releases.
    public var clicks: [CursorClick] = []
    /// Which system cursor was showing, each time it changed (the first entry is at time 0).
    public var shapes: [CursorShapeChange] = []
    public init() {}

    /// True for imported videos: nothing to draw.
    public var isEmpty: Bool { samples.isEmpty && clicks.isEmpty }

    enum CodingKeys: String, CodingKey { case version, capture, samples, clicks, shapes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        capture = try c.decodeIfPresent(CaptureInfo.self, forKey: .capture)
        samples = try c.decodeIfPresent([CursorSample].self, forKey: .samples) ?? []
        clicks = try c.decodeIfPresent([CursorClick].self, forKey: .clicks) ?? []
        shapes = try c.decodeIfPresent([CursorShapeChange].self, forKey: .shapes) ?? []
    }

    /// The cursor shape showing at source time `t`.
    public func shape(at t: Double) -> CursorShape {
        var current = CursorShape.arrow
        for s in shapes { if s.time <= t { current = s.shape } else { break } }
        return current
    }
}

/// How a recording was made: what it captured and how big it was.
public struct CaptureInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case display, window, area }
    public var kind: Kind
    /// Size of the video in pixels.
    public var width: Int
    public var height: Int
    /// Video pixels per screen point (2 on a Retina display, 1 on most external ones).
    public var scale: Double
    /// The captured part of the screen in macOS screen points (top-left of the main display = 0,0; y goes down).
    public var x: Double, y: Double, pointWidth: Double, pointHeight: Double
    /// What was recorded, for people: "Built-in Retina Display", "Safari: Apple", "Area".
    public var name: String

    public init(kind: Kind, width: Int, height: Int, scale: Double, frame: CGRect, name: String) {
        self.kind = kind; self.width = width; self.height = height; self.scale = scale
        x = frame.minX; y = frame.minY; pointWidth = frame.width; pointHeight = frame.height; self.name = name
    }
    public var frame: CGRect { CGRect(x: x, y: y, width: pointWidth, height: pointHeight) }
}

/// One cursor position. `x`, `y` are video pixels; they can be outside the frame (the cursor left the
/// recorded area) so the cursor can glide off the edge.
public struct CursorSample: Codable, Equatable, Sendable {
    public var time: Double, x: Double, y: Double
    public init(time: Double, x: Double, y: Double) { self.time = time; self.x = x; self.y = y }
}

public enum MouseButton: String, Codable, Sendable { case left, right, other }

/// A button press (`down`) or release (`up`) at a position in video pixels.
public struct CursorClick: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case down, up }
    public var time: Double, x: Double, y: Double
    public var button: MouseButton
    public var phase: Phase
    public init(time: Double, x: Double, y: Double, button: MouseButton = .left, phase: Phase = .down) {
        self.time = time; self.x = x; self.y = y; self.button = button; self.phase = phase
    }
    enum CodingKeys: String, CodingKey { case time, x, y, button, phase }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        button = try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .down
    }
}

/// The system cursors P2 can redraw. `other` = a cursor the app didn't recognise (an app's own cursor).
public enum CursorShape: String, Codable, CaseIterable, Sendable {
    case arrow, iBeam, pointingHand, openHand, closedHand, crosshair
    case resizeLeftRight, resizeUpDown, resizeLeft, resizeRight, resizeUp, resizeDown
    case operationNotAllowed, dragCopy, dragLink, contextualMenu, iBeamVertical, disappearingItem
    case other
    public init(from decoder: Decoder) throws {
        self = CursorShape(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

public struct CursorShapeChange: Codable, Equatable, Sendable {
    public var time: Double
    public var shape: CursorShape
    public init(time: Double, shape: CursorShape) { self.time = time; self.shape = shape }
}
