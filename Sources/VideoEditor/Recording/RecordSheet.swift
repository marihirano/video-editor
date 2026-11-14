import AppKit
import EditorCore
import SwiftUI

/// The Record window: what to record (display, window or area), hide desktop icons, then Start.
/// Without the screen recording permission it explains how to allow it instead.
/// Claude's layout, for Mari to review.
struct RecordSheet: View {
    @EnvironmentObject private var rec: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("New Recording").font(Theme.fontTitle)
            if rec.hasPermission { options } else { PermissionHelp() }
        }
        .padding(Theme.s5)
        .frame(width: 420)
        .font(Theme.fontBody)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let had = rec.hasPermission
            rec.refreshPermission()
            if !had && rec.hasPermission { Task { await rec.loadSources() } }
        }
    }

    @ViewBuilder private var options: some View {
        ChoiceButtons(choices: RecordingController.Kind.allCases, isSelected: { rec.kind == $0 },
                      label: { ["display": "Whole display", "window": "One window", "area": "Area"][$0.rawValue]! }) { rec.kind = $0 }

        Group {
            switch rec.kind {
            case .display: displayPicker
            case .window: windowPicker
            case .area: areaPicker
            }
        }
        // Fixed height, so the window doesn't jump between choices or when the lists load.
        .frame(height: 224, alignment: .top)

        Toggle("Hide desktop icons", isOn: $rec.hideDesktopIcons)
            .toggleStyle(.checkbox).font(Theme.fontCallout)
            .disabled(rec.kind == .window)
        PanelNote("A \(Settings.recordingCountdownSeconds)-second countdown, then recording starts. Press \(GlobalHotKey.label) in any app to start or stop. No sound is recorded, and the pointer is saved separately so it can be styled later.")

        HStack {
            Spacer()
            Button("Cancel") { rec.setupShown = false }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Start Recording") { rec.start() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .disabled(!rec.canStart)
        }
    }

    @ViewBuilder private var displayPicker: some View {
        if rec.displays.count > 1 {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(rec.displays) { d in
                        row(selected: rec.displayID == d.id, title: d.name, detail: d.pixels, icon: "display") { rec.displayID = d.id }
                    }
                }
            }
        } else if let d = rec.displays.first {
            row(selected: true, title: d.name, detail: d.pixels, icon: "display") {}
        }
    }

    @ViewBuilder private var windowPicker: some View {
        if rec.windows.isEmpty {
            PanelNote("No windows to record. Open the app you want to record, then come back.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    ForEach(rec.windows) { w in
                        row(selected: rec.windowID == w.id, title: w.title.isEmpty ? w.app : w.title,
                            detail: w.title.isEmpty ? w.size : "\(w.app) · \(w.size)",
                            image: NSRunningApplication(processIdentifier: w.pid)?.icon) { rec.windowID = w.id }
                    }
                }
            }
            .frame(height: 176)
            PanelNote("Only that window is recorded, even if others are in front of it. Keep it in place while recording.")
        }
    }

    @ViewBuilder private var areaPicker: some View {
        HStack(spacing: Theme.s3) {
            if let a = rec.area {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(Int(a.rect.width)) × \(Int(a.rect.height)) points").font(Theme.fontCallout)
                    Text(NSScreen.with(displayID: a.display)?.localizedName ?? "Display")
                        .font(Theme.fontCallout).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Redraw…") { rec.pickArea() }.buttonStyle(QuietButtonStyle())
            } else {
                Button("Choose Area…") { rec.pickArea() }.buttonStyle(QuietButtonStyle())
                Text("Drag over the part of the screen to record.").font(Theme.fontCallout).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func row(selected: Bool, title: String, detail: String, icon: String? = nil, image: NSImage? = nil,
                     pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: Theme.s3) {
                if let image { Image(nsImage: image).resizable().frame(width: 20, height: 20) }
                else if let icon { Image(systemName: icon).font(.system(size: 14, weight: .light)).frame(width: 20) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.fontCallout).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Theme.fontCaption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? Theme.controlFill : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
