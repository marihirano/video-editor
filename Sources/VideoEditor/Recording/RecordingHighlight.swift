import AppKit
import EditorCore
import SwiftUI

/// Shows what is being recorded (Mari's wireframe, 2026-11-14): an area gets the rest of its display
/// dimmed; a window gets a muted magenta border that follows it. A whole display gets nothing.
/// Both are this app's windows, so they never show in the recording, and clicks pass through them.
@MainActor
final class RecordingHighlight {
    private var window: OverlayWindow?
    private var follow: Timer?

    /// Dims the display around `rect` (the display's own points, top-left origin).
    func showArea(_ rect: CGRect, on screen: NSScreen) {
        let w = Self.passThroughWindow(frame: screen.frame)
        w.contentView = NSHostingView(rootView: AreaDim(hole: rect))
        w.orderFrontRegardless()
        window = w
    }

    /// Draws a border around a window and keeps it there if the window moves or resizes.
    func showWindow(_ id: CGWindowID) {
        guard let frame = Self.appKitFrame(of: id) else { return }
        let w = Self.passThroughWindow(frame: Self.borderFrame(frame))
        w.contentView = NSHostingView(rootView: WindowBorder())
        w.orderFrontRegardless()
        window = w
        let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, let f = Self.appKitFrame(of: id) else { return }
                let target = Self.borderFrame(f)
                if window.frame != target { window.setFrame(target, display: true) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        follow = t
    }

    func close() {
        follow?.invalidate(); follow = nil
        window?.orderOut(nil); window = nil
    }

    /// For the debug snapshot.
    var contentView: NSView? { window?.contentView }

    // MARK: Helpers

    private static func passThroughWindow(frame: NSRect) -> OverlayWindow {
        let w = OverlayWindow(frame: frame, level: .floating)
        w.ignoresMouseEvents = true
        return w
    }

    private static func borderFrame(_ f: NSRect) -> NSRect {
        let o = Settings.recordingWindowBorderWidth - Settings.recordingWindowBorderOverlap
        return f.insetBy(dx: -o, dy: -o)
    }

    /// A window's frame in AppKit screen coordinates (bottom-left origin), from the window server.
    static func appKitFrame(of id: CGWindowID) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict),
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// 45% black everywhere on the display except the recorded area.
private struct AreaDim: View {
    let hole: CGRect
    var body: some View {
        Canvas { ctx, size in
            var p = Path(CGRect(origin: .zero, size: size))
            p.addRect(hole)
            ctx.fill(p, with: .color(.black.opacity(Settings.recordingAreaDimOpacity)), style: FillStyle(eoFill: true))
        }
        .ignoresSafeArea()
    }
}

/// The muted magenta outline around a recorded window.
private struct WindowBorder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Settings.recordingWindowBorderInnerRadius + Settings.recordingWindowBorderWidth)
            .strokeBorder(Color(rgba: Settings.recordingWindowBorderColor), lineWidth: Settings.recordingWindowBorderWidth)
    }
}
