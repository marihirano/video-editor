import AppKit
import EditorCore
import SwiftUI

/// The recording control at the bottom of the recorded display (Mari's wireframe, 2026-11-14):
/// [■ 0:05 in red = stop] | [pause] | [delete]. It floats over other apps, can be dragged anywhere,
/// and belongs to this app, so it never shows in the recording.
@MainActor
final class RecordingControlPanel {
    private let panel: NSPanel

    init(controller: RecordingController) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar                          // above the area dimming and the window border
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)  // always dark: it sits over any content
        let host = NSHostingView(rootView: RecordingControlView().environmentObject(controller))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    /// Bottom centre of the screen, just above the Dock.
    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let size = panel.frame.size
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.minY + Settings.recordingControlBottomGap))
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
    var contentView: NSView? { panel.contentView }
}

private struct RecordingControlView: View {
    @EnvironmentObject private var rec: RecordingController

    private var isCountdown: Bool { if case .countdown = rec.phase { return true }; return false }
    private var busy: Bool { rec.phase == .finishing }

    var body: some View {
        HStack(spacing: 0) {
            segment(help: "Stop and open the recording (\(GlobalHotKey.label))", action: rec.stop) {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "stop.circle").font(.system(size: 20, weight: .light))
                    Text(timeText).font(Theme.font(15).monospacedDigit())
                        .frame(minWidth: 40, alignment: .leading)
                }
                .foregroundStyle(stopColor)
            }
            .disabled(isCountdown || busy)
            divider
            segment(help: rec.phase == .paused ? "Resume recording" : "Pause recording", action: rec.togglePause) {
                Image(systemName: rec.phase == .paused ? "play.circle" : "pause.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isCountdown ? Color.white.opacity(0.35) : .white)
            }
            .disabled(isCountdown || busy)
            divider
            segment(help: isCountdown ? "Cancel" : "Delete this recording", action: deleteTapped) {
                Image(systemName: "trash").font(.system(size: 18, weight: .light)).foregroundStyle(.white)
            }
            .disabled(busy)
        }
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Theme.radiusPanel).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
        .padding(Theme.s1)
    }

    private func segment<Content: View>(help: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content().padding(.horizontal, Theme.s3).frame(minWidth: 48, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(ControlSegmentStyle())
        .help(help)
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 24) }

    private func deleteTapped() {
        if isCountdown { rec.cancel() } else { rec.deleteRecording() }
    }

    private var stopColor: Color {
        switch rec.phase {
        case .recording: return Color(red: 1, green: 0.27, blue: 0.23)          // #FF453A
        case .paused: return .white                                             // white while paused (Mari)
        default: return Color.white.opacity(0.45)
        }
    }

    private var timeText: String {
        switch rec.phase {
        case .countdown: return "0:00"
        case .finishing: return "Saving…"
        default: return RecordingController.timerText(rec.elapsed)
        }
    }
}

/// A light highlight under the pointer and while pressed.
private struct ControlSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(Color.white.opacity(!enabled ? 0 : configuration.isPressed ? 0.16 : hovering ? 0.08 : 0))
                    .padding(4))
                .onHover { hovering = $0 }
        }
    }
}
