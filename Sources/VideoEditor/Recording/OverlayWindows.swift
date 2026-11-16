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

/// Dims every display with a hint in the middle; drag a rectangle on any of them. When the mouse is let go
/// a small card appears in the middle of the area with its size and "Record Video" (Return does the same);
/// dragging again redraws. Esc cancels. (Mari's mockups, 2026-11-16.)
@MainActor
final class AreaPicker {
    private var windows: [OverlayWindow] = []
    private var views: [AreaPickerView] = []

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
            v.began = { [weak self, weak v] in
                // Drawing on one display clears the hint and any earlier area on the others.
                self?.views.filter { $0 !== v }.forEach { $0.clear() }
            }
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
            views.append(v)
        }
        NSCursor.crosshair.push()
    }

    private func close() {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
    }

    /// For the debug snapshot: the picker's view, with an area already chosen (or none, to show the hint).
    static func debugView(size: CGSize, area: CGRect?) -> NSView {
        let v = AreaPickerView(frame: CGRect(origin: .zero, size: size))
        v.debugSet(area)
        return v
    }
}

private final class AreaPickerView: NSView {
    var finish: ((CGRect?) -> Void)?
    var began: (() -> Void)?
    private var start: CGPoint?
    private var rect: CGRect?
    private var dragging = false
    private var showHint = true
    private var card: NSHostingView<AreaCard>?
    private let cardModel = AreaCardModel()

    override var isFlipped: Bool { true }   // top-left origin, like the capture's coordinates
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    func clear() { rect = nil; showHint = false; removeCard(); needsDisplay = true }
    func debugSet(_ r: CGRect?) { rect = r; showHint = r == nil; if let r { showCard(for: r) } }

    private func removeCard() { card?.removeFromSuperview(); card = nil }

    private func showCard(for r: CGRect) {
        removeCard()
        cardModel.width = Int(r.width); cardModel.height = Int(r.height)
        let host = NSHostingView(rootView: AreaCard(
            model: cardModel,
            resize: { [weak self] w, h, refocus in self?.resize(toWidth: w, height: h, refocus: refocus) },
            record: { [weak self] in if let r = self?.rect { self?.finish?(r.integral) } },
            cancel: { [weak self] in self?.finish?(nil) }))
        host.setFrameSize(host.fittingSize)
        card = host
        addSubview(host)
        placeCard()
    }

    /// The card sits in the middle of the area.
    private func placeCard() {
        guard let card, let r = rect else { return }
        card.setFrameOrigin(CGPoint(x: (r.midX - card.frame.width / 2).rounded(), y: (r.midY - card.frame.height / 2).rounded()))
    }

    /// Typed size: the area grows or shrinks around its centre (Mari), kept on the display and at least the minimum size.
    private func resize(toWidth w: Int, height h: Int, refocus: Bool) {
        guard let r = rect else { return }
        let minSide = Settings.recordingMinAreaPoints
        let nw = min(max(CGFloat(w), minSide), bounds.width)
        let nh = min(max(CGFloat(h), minSide), bounds.height)
        var x = r.midX - nw / 2, y = r.midY - nh / 2
        x = min(max(x, 0), bounds.width - nw); y = min(max(y, 0), bounds.height - nh)   // nudged back on if it would leave the display
        rect = CGRect(x: x, y: y, width: nw, height: nh).integral
        cardModel.width = Int(rect!.width); cardModel.height = Int(rect!.height)
        placeCard()
        if refocus { window?.makeFirstResponder(self) }   // after Return, so the next Return means Record Video
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        start = convert(e.locationInWindow, from: nil); rect = nil; dragging = true; showHint = false
        removeCard(); began?(); needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard let start else { return }
        let p = convert(e.locationInWindow, from: nil)
        rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        dragging = false
        guard let r = rect, r.width >= Settings.recordingMinAreaPoints, r.height >= Settings.recordingMinAreaPoints else {
            rect = nil; showHint = true; needsDisplay = true; return
        }
        rect = r.integral
        showCard(for: rect!)
        needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: finish?(nil)                                        // Esc
        case 36, 76: if let r = rect, !dragging { finish?(r.integral) }   // Return
        default: super.keyDown(with: e)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let r = rect {
            NSGraphicsContext.current?.compositingOperation = .clear
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke(); border.stroke()
            if dragging { label("\(Int(r.width)) × \(Int(r.height))", at: CGPoint(x: r.midX, y: r.maxY + 18)) }
        }
        if showHint { hintPill("Drag to record a part of the screen.") }
    }

    /// The light pill in the middle of the screen (Mari's first mockup).
    private func hintPill(_ s: String) {
        let font = NSFont(name: Theme.fontName, size: 20) ?? .systemFont(ofSize: 20)
        let text = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        let size = text.size()
        let box = CGRect(x: bounds.midX - size.width / 2 - 28, y: bounds.midY - size.height / 2 - 16, width: size.width + 56, height: size.height + 32)
        NSColor(white: 0.96, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: box.minX + 28, y: box.minY + 16))
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

final class AreaCardModel: ObservableObject {
    @Published var width = 0
    @Published var height = 0
}

/// The card in the middle of the chosen area (Mari's third mockup): its size in two boxes you can type in
/// (the area changes around its centre), then Record Video.
private struct AreaCard: View {
    @ObservedObject var model: AreaCardModel
    let resize: (Int, Int, Bool) -> Void
    let record: () -> Void
    let cancel: () -> Void
    @State private var w = ""
    @State private var h = ""
    @FocusState private var focus: Field?
    private enum Field { case width, height }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                box($w, .width)
                Text("×").font(Theme.fontBody)
                box($h, .height)
            }
            .padding(.vertical, Theme.s3)
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            Button(action: record) {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "video.fill").font(.system(size: 15))
                    Text("Record Video").font(Theme.fontBody)
                    Spacer(minLength: Theme.s4)
                    Image(systemName: "return").font(.system(size: 12, weight: .light)).opacity(0.7)
                }
                .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.2, opacity: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(20)   // room for the shadow
        .onAppear(perform: sync)
        .onChange(of: model.width) { sync() }
        .onChange(of: model.height) { sync() }
        .onChange(of: focus) { commit() }   // leaving a box applies it too
    }

    private func sync() { w = "\(model.width)"; h = "\(model.height)" }

    /// `submitted` (Return in a box) always hands focus back, so the next Return records.
    private func commit(submitted: Bool = false) {
        guard let nw = Int(w), let nh = Int(h), nw > 0, nh > 0 else { sync(); return }
        if submitted || nw != model.width || nh != model.height { resize(nw, nh, submitted) } else { sync() }
    }

    private func box(_ text: Binding<String>, _ field: Field) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Theme.fontBody.monospacedDigit())
            .focused($focus, equals: field)
            .onChange(of: text.wrappedValue) { text.wrappedValue = text.wrappedValue.filter(\.isNumber) }
            .onSubmit { commit(submitted: true) }
            .onExitCommand(perform: cancel)
            .onKeyPress(.tab) {   // Tab and Shift-Tab swap between the two boxes
                focus = field == .width ? .height : .width
                return .handled
            }
            .frame(width: 76).padding(.vertical, Theme.s1 + 1)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.white.opacity(field == focus ? 0.14 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: field == focus ? 1.5 : 0))
    }
}
