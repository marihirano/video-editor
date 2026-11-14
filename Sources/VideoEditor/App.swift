import AppKit
import SwiftUI

@main
struct VideoEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel.shared
    @StateObject private var recorder = RecordingController.shared
    @AppStorage(Theme.appearanceKey) private var appearance = Theme.AppearanceMode.system.rawValue

    init() { Theme.registerFonts() }

    var body: some Scene {
        Window("Video Editor", id: "editor") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.playback)
                .environmentObject(recorder)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { Theme.AppearanceMode.apply(appearance) }
                .onChange(of: appearance) { Theme.AppearanceMode.apply(appearance) }
                .font(Theme.fontBody)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppMenus(model: model, recorder: recorder) }
    }
}

/// Opens files handed over by Finder (double-clicked projects, videos dropped on the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            RecordingController.shared.registerHotKey()
            DebugSnapshot.runIfRequested()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in await EditorModel.shared.open(url) }
    }

    /// Quitting with unsaved edits asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { EditorModel.shared.confirmDiscardChanges() } ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
