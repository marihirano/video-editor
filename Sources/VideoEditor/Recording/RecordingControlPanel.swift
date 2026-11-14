import AppKit
import EditorCore
import SwiftUI

/// The small floating control while recording: a red dot and the timer, pause / resume, and stop.
/// It floats over other apps at the top of the recorded display and can be dragged anywhere.
/// It belongs to this app, so it never shows in the recording.
@MainActor
final class RecordingControlPanel {
    private let panel: NSPanel

    init(controller: RecordingController) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: RecordingControlView().environmentObject(controller))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let size = panel.frame.size
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - Theme.s3))
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
    var contentView: NSView? { panel.contentView }
}

/// Claude's layout, for Mari to review: [● 0:12] [pause] [stop], on the panel colour.
private struct RecordingControlView: View {
    @EnvironmentObject private var rec: RecordingController

    var body: some View {
        HStack(spacing: Theme.s2) {
            status
            Divider().frame(height: 18)
            switch rec.phase {
            case .countdown:
                Button("Cancel") { rec.cancel() }.buttonStyle(QuietButtonStyle())
            default:
                ToolButton(title: rec.phase == .paused ? "Resume" : "Pause",
                           systemImage: rec.phase == .paused ? "play.fill" : "pause.fill",
                           help: rec.phase == .paused ? "Resume recording" : "Pause recording") { rec.togglePause() }
                    .disabled(rec.phase == .finishing)
                ToolButton(title: "Stop", systemImage: "stop.fill",
                           help: "Stop recording and open it (\(GlobalHotKey.label))") { rec.stop() }
                    .disabled(rec.phase == .finishing)
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2)
        .fixedSize()
        .font(Theme.fontBody)
        .background(Capsule().fill(Theme.panelFill))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .padding(Theme.s1)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: Theme.s2) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(statusText).font(Theme.fontBody.monospacedDigit())
                .frame(minWidth: 64, alignment: .leading)
        }
    }

    private var dotColor: Color {
        switch rec.phase {
        case .recording: return .red
        case .paused: return .orange
        default: return Theme.tertiaryText
        }
    }

    private var statusText: String {
        switch rec.phase {
        case .countdown(let n): return "Starting in \(n)"
        case .paused: return "Paused \(RecordingController.timerText(rec.elapsed))"
        case .finishing: return "Saving…"
        default: return RecordingController.timerText(rec.elapsed)
        }
    }
}
