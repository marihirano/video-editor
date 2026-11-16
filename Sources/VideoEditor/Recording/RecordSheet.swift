import AppKit
import EditorCore
import SwiftUI

/// Only shown when the Mac hasn't allowed screen recording yet (the choices moved to the area picker, 2026-11-16).
struct RecordSheet: View {
    @EnvironmentObject private var rec: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("New Recording").font(Theme.fontTitle)
            PermissionHelp()
        }
        .padding(Theme.s5)
        .frame(width: 420)
        .font(Theme.fontBody)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            rec.refreshPermission()
            if rec.hasPermission { rec.setupShown = false; rec.pickArea() }   // allowed: carry on to choosing the area
        }
    }
}

/// Shown when the Mac hasn't allowed screen recording yet.
private struct PermissionHelp: View {
    @EnvironmentObject private var rec: RecordingController

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Image(systemName: "lock.shield").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Allow screen recording").font(Theme.fontBody)
                Text("To record your screen, macOS needs your permission. Click Allow, then switch on Video Editor in System Settings › Privacy & Security › Screen & System Audio Recording.")
                    .font(Theme.fontCallout).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                Text("If macOS asks to quit and reopen Video Editor, do that, then come back here.")
                    .font(Theme.fontCallout).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("Cancel") { rec.setupShown = false }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Allow…") { rec.requestPermission() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
        }
    }
}
