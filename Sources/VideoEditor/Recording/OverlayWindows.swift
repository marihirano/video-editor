import AppKit
import EditorCore
import SwiftUI

/// Borderless windows the app shows over everything while recording (countdown, area picker).
/// They belong to this app, so they're never in the recording.
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    static func with(displayID id: CGDirectDisplayID) -> NSScreen? { screens.first { $0.displayID == id } }
}

// MARK: Countdown

/// The big 3 · 2 · 1 in the middle of the display about to be recorded, with Skip. Esc cancels.
@MainActor
final class CountdownOverlay {
    private var window: OverlayWindow?
    private let model = Model()

    final class Model: ObservableObject { @Published var number = 3 }

    func show(on screen: NSScreen, from n: Int, skip: @escaping () -> Void, cancel: @escaping () -> Void) {
        model.number = n
        let size: CGFloat = 168
        let f = screen.frame
        let w = OverlayWindow(frame: NSRect(x: f.midX - size / 2, y: f.midY - size / 2, width: size, height: size), level: .screenSaver)
        w.contentView = NSHostingView(rootView: CountdownView(model: model, skip: skip, cancel: cancel))
        w.orderFrontRegardless()
        window = w
    }

    func set(_ n: Int) { withAnimation(.easeOut(duration: 0.2)) { model.number = n } }

    func close() { window?.orderOut(nil); window = nil }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownOverlay.Model
    let skip: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: Theme.s1) {
            Text("\(model.number)").font(Theme.font(72).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
            Button("Skip", action: skip).buttonStyle(QuietButtonStyle()).help("Start recording now (Esc cancels)")
        }
        .frame(width: 168, height: 168)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge * 2).fill(Theme.panelFill.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge * 2).strokeBorder(Theme.hairline))
        .background(KeyCatcher(onEscape: cancel))
    }
}

/// Catches Esc in an overlay window.
private struct KeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void
    func makeNSView(context: Context) -> NSView { let v = EscView(); v.onEscape = onEscape; return v }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class EscView: NSView {
        var onEscape: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with e: NSEvent) { e.keyCode == 53 ? onEscape?() : super.keyDown(with: e) }
    }
}

// MARK: Area picker

/// Dims every display; drag a rectangle on one of them to choose the area to record. Esc cancels.
@MainActor
final class AreaPicker {
    private var windows: [OverlayWindow] = []

    /// `done` gets the display and the area in that display's own points (top-left origin), or nil if cancelled.
    func run(done: @escaping ((CGDirectDisplayID, CGRect)?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let w = OverlayWindow(frame: screen.frame, level: .screenSaver)
            let v = AreaPickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let id = screen.displayID
            v.finish = { [weak self] rect in
                self?.close()
                done(rect.map { (id, $0) })
            }
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSCursor.crosshair.push()
    }

    private func close() {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

private final class AreaPickerView: NSView {
    var finish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var rect: CGRect?

    override var isFlipped: Bool { true }   // top-left origin, like the capture's coordinates
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); rect = nil; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) {
        guard let start else { return }
        let p = convert(e.locationInWindow, from: nil)
        rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard let r = rect, r.width >= Settings.recordingMinAreaPoints, r.height >= Settings.recordingMinAreaPoints else {
            rect = nil; needsDisplay = true; return
        }
        finish?(r.integral)
    }
    override func keyDown(with e: NSEvent) { e.keyCode == 53 ? finish?(nil) : super.keyDown(with: e) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let hint = rect == nil ? "Drag to choose the area to record · Esc to cancel" : nil
        if let r = rect {
            NSGraphicsContext.current?.compositingOperation = .clear
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke(); border.stroke()
            label("\(Int(r.width)) × \(Int(r.height))", at: CGPoint(x: r.midX, y: r.maxY + 18))
        }
        if let hint { label(hint, at: CGPoint(x: bounds.midX, y: bounds.midY)) }
    }

    private func label(_ s: String, at p: CGPoint) {
        let font = NSFont(name: Theme.fontName, size: 13) ?? .systemFont(ofSize: 13)
        let text = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let box = CGRect(x: p.x - size.width / 2 - 10, y: p.y - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: Theme.radius, yRadius: Theme.radius).fill()
        text.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5))
    }
}
