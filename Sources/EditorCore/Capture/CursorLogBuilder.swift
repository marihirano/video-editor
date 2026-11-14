import CoreGraphics
import Foundation

/// Builds the cursor log while recording. The app feeds it what it sees on each poll
/// (where the cursor is, which buttons are held, which cursor is showing); this turns that into
/// samples, clicks and shape changes in video pixels and video seconds.
public struct CursorLogBuilder: Sendable {
    public private(set) var track = CursorTrack()
    public let geometry: CaptureGeometry
    private var lastPoint: CGPoint?
    private var lastButtons: Set<MouseButton> = []
    private var lastShape: CursorShape?

    public init(geometry: CaptureGeometry, info: CaptureInfo) {
        self.geometry = geometry
        track.capture = info
    }

    /// One poll. `videoTime` is nil before the first frame and while paused (nothing is logged then,
    /// but held buttons are remembered so a release after a pause isn't missed or doubled).
    public mutating func observe(videoTime: Double?, global: CGPoint, buttons: Set<MouseButton>, shape: CursorShape?) {
        guard let t = videoTime else { return }
        let p = geometry.pixel(fromGlobal: global)
        let moved = lastPoint.map { hypot($0.x - p.x, $0.y - p.y) >= Settings.cursorMinMovePixels } ?? true
        if moved {
            track.samples.append(CursorSample(time: round6(t), x: round2(p.x), y: round2(p.y)))
            lastPoint = p
        }
        for b in [MouseButton.left, .right, .other] {
            let now = buttons.contains(b), was = lastButtons.contains(b)
            if now != was {
                if !moved, lastPoint != p {   // a click always has a sample right where it happened
                    track.samples.append(CursorSample(time: round6(t), x: round2(p.x), y: round2(p.y))); lastPoint = p
                }
                track.clicks.append(CursorClick(time: round6(t), x: round2(p.x), y: round2(p.y), button: b, phase: now ? .down : .up))
            }
        }
        lastButtons = buttons
        if let shape, shape != lastShape {
            track.shapes.append(CursorShapeChange(time: track.shapes.isEmpty ? 0 : round6(t), shape: shape))
            lastShape = shape
        }
    }

    /// When recording stops: a button still held gets its release at the very end.
    public mutating func finish(at videoTime: Double) {
        guard let p = lastPoint else { return }
        for b in [MouseButton.left, .right, .other] where lastButtons.contains(b) {
            track.clicks.append(CursorClick(time: round6(videoTime), x: round2(p.x), y: round2(p.y), button: b, phase: .up))
        }
        lastButtons = []
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
}
