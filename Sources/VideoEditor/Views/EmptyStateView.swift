import AppKit
import SwiftUI

/// Shown when nothing is open: the app icon, an invitation to drop a file, and the basics.
struct EmptyStateView: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var recorder: RecordingController
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: Theme.s3) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .scaleEffect(isTargeted ? 1.08 : 1)
            Text(isTargeted ? "Drop to open" : "Record your screen, or drop a recording here")
                .font(Theme.fontLarge)
            Text("MOV or MP4, or a saved project")
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: Theme.s3) {
                Button { recorder.showSetup() } label: { Label("Record Screen…", systemImage: "record.circle") }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Record a display, a window or an area (\(GlobalHotKey.label) starts and stops it from any app)")
                Button("Choose a File…") { Task { await model.showOpenPanel() } }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, Theme.s2)
            Text("Then: cut with the scissors (⌘T), add zooms on the zoom track, style the frame on the right, and Export (⌘E).")
                .font(Theme.fontCallout).foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, Theme.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLarge)
                .strokeBorder(isTargeted ? Theme.accent : Theme.hairline,
                              style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.accent.opacity(isTargeted ? 0.08 : 0)))
                .padding(Theme.s5)
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}
