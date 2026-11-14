import AppKit
import EditorCore

/// Watches the real cursor while recording: where it is, which mouse buttons are held, and which
/// system cursor is showing. Needs no permission: it polls instead of listening to other apps' events.
@MainActor
final class CursorWatcher {
    private var timer: Timer?
    private var shapeTimer: Timer?
    private var shape: CursorShape?
    private let observe: (CGPoint, Set<MouseButton>, CursorShape?) -> Void

    /// `observe` gets the cursor's global position (top-left origin, points), the held buttons and the shape.
    init(observe: @escaping (CGPoint, Set<MouseButton>, CursorShape?) -> Void) { self.observe = observe }

    func start() {
        shape = CursorShapes.current()
        poll()
        let t = Timer(timeInterval: 1 / Settings.cursorPollHz, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        let s = Timer(timeInterval: 1 / Settings.cursorShapePollHz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shape = CursorShapes.current() }
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(s, forMode: .common)
        timer = t; shapeTimer = s
    }

    func stop() { timer?.invalidate(); shapeTimer?.invalidate(); timer = nil; shapeTimer = nil }

    private func poll() {
        guard let p = CGEvent(source: nil)?.location else { return }
        let mask = NSEvent.pressedMouseButtons
        var buttons = Set<MouseButton>()
        if mask & 1 != 0 { buttons.insert(.left) }
        if mask & 2 != 0 { buttons.insert(.right) }
        if mask & ~3 != 0 { buttons.insert(.other) }
        observe(p, buttons, shape)
    }
}

/// Tells which system cursor is showing by comparing it with the standard ones.
@MainActor
enum CursorShapes {
    private struct Print { let hot: CGPoint; let size: CGSize; let pixels: [UInt8] }

    private static let known: [(CursorShape, Print)] = {
        var list: [(CursorShape, NSCursor)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand), (.openHand, .openHand),
            (.closedHand, .closedHand), (.crosshair, .crosshair), (.resizeLeftRight, .resizeLeftRight),
            (.resizeUpDown, .resizeUpDown), (.resizeLeft, .resizeLeft), (.resizeRight, .resizeRight),
            (.resizeUp, .resizeUp), (.resizeDown, .resizeDown), (.operationNotAllowed, .operationNotAllowed),
            (.dragCopy, .dragCopy), (.dragLink, .dragLink), (.contextualMenu, .contextualMenu),
            (.iBeamVertical, .iBeamCursorForVerticalLayout), (.disappearingItem, .disappearingItem),
        ]
        list.removeAll { $0.1.image.size == .zero }
        return list.map { ($0.0, fingerprint($0.1)) }
    }()

    static func current() -> CursorShape? {
        guard let c = NSCursor.currentSystem else { return nil }
        let p = fingerprint(c)
        var best: (CursorShape, Int)?
        for (shape, k) in known where abs(k.hot.x - p.hot.x) < 1.5 && abs(k.hot.y - p.hot.y) < 1.5 {
            let d = zip(k.pixels, p.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            if best == nil || d < best!.1 { best = (shape, d) }
        }
        // Same hot spot and nearly the same picture (allowing for a larger cursor size in Accessibility settings).
        if let best, best.1 < 16 * 16 * 24 { return best.0 }
        return .other
    }

    /// Hot spot as a fraction of the cursor's size, plus a tiny 16×16 picture of its alpha.
    private static func fingerprint(_ c: NSCursor) -> Print {
        let size = c.image.size
        let hot = CGPoint(x: size.width > 0 ? c.hotSpot.x / size.width * 32 : 0, y: size.height > 0 ? c.hotSpot.y / size.height * 32 : 0)
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n)
        if let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
           let cg = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        return Print(hot: hot, size: size, pixels: pixels)
    }
}
