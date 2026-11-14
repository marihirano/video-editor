import AppKit
import EditorCore
import ScreenCaptureKit
import SwiftUI

/// Runs a recording from start to finish: the Record window's choices, the permission, the countdown,
/// the capture and cursor log, the floating control, and opening the result in the editor.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum Phase: Equatable { case idle, countdown(Int), recording, paused, finishing }
    enum Kind: String, CaseIterable { case display, window, area }

    struct DisplayChoice: Identifiable, Hashable { let id: CGDirectDisplayID; let name: String; let pixels: String }
    struct WindowChoice: Identifiable, Hashable { let id: CGWindowID; let app: String; let title: String; let pid: pid_t; let size: String }

    @Published private(set) var phase: Phase = .idle
    /// Seconds recorded so far (pauses not counted), for the timer.
    @Published private(set) var elapsed: Double = 0
    @Published var setupShown = false
    @Published private(set) var hasPermission = ScreenRecordingPermission.isGranted

    // The Record window's choices. Kind, display and "hide icons" are remembered between launches.
    @Published var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: "recordKind") ?? "") ?? .display {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "recordKind") }
    }
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var windowID: CGWindowID?
    @Published var area: (display: CGDirectDisplayID, rect: CGRect)?
    @Published var hideDesktopIcons: Bool = UserDefaults.standard.object(forKey: "hideDesktopIcons") as? Bool ?? Settings.defaultHideDesktopIcons {
        didSet { UserDefaults.standard.set(hideDesktopIcons, forKey: "hideDesktopIcons") }
    }
    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var windows: [WindowChoice] = []

    private var recorder: ScreenRecorder?
    private var log: CursorLogBuilder?
    private var watcher: CursorWatcher?
    private var countdown: CountdownOverlay?
    private var countdownTask: Task<Void, Never>?
    private var skipRequested = false
    private var panel: RecordingControlPanel?
    private var highlight: RecordingHighlight?
    private var timer: Timer?
    private var hiddenWindows: [NSWindow] = []
    private let picker = AreaPicker()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.hotKeyPressed() }

    var isBusy: Bool { phase != .idle }

    func registerHotKey() { hotKey.register() }

    // MARK: The Record window

    /// File › New Recording / the empty window's Record button.
    func showSetup() {
        guard !isBusy else { return }
        refreshPermission()
        setupShown = true
        Task { await loadSources() }
    }

    func refreshPermission() { hasPermission = ScreenRecordingPermission.isGranted || debugAssumePermission }
    /// Debug snapshot only: show the options as if the permission were granted.
    var debugAssumePermission = ProcessInfo.processInfo.environment["VET_SNAPSHOT_RECORD_ALLOWED"] != nil

    /// Asks macOS for the permission (its own dialog appears the first time), then opens System Settings.
    func requestPermission() {
        if ScreenRecordingPermission.request() { hasPermission = true; Task { await loadSources() }; return }
        NSWorkspace.shared.open(ScreenRecordingPermission.settingsURL)
    }

    func loadSources() async {
        displays = NSScreen.screens.map { s in
            let px = "\(Int(s.frame.width * s.backingScaleFactor)) × \(Int(s.frame.height * s.backingScaleFactor))"
            return DisplayChoice(id: s.displayID, name: s.localizedName, pixels: px)
        }
        if !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id ?? CGMainDisplayID() }
        guard hasPermission, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let me = getpid()
        windows = content.windows.compactMap { w in
            guard let app = w.owningApplication, app.processID != me, w.windowLayer == 0, w.isOnScreen,
                  w.frame.width >= 80, w.frame.height >= 60 else { return nil }
            let title = (w.title ?? "").trimmingCharacters(in: .whitespaces)
            return WindowChoice(id: w.windowID, app: app.applicationName, title: title, pid: app.processID,
                                size: "\(Int(w.frame.width)) × \(Int(w.frame.height))")
        }
        if let id = windowID, !windows.contains(where: { $0.id == id }) { windowID = nil }
        if windowID == nil { windowID = windows.first?.id }
    }

    /// Area: hides the Record window, lets the person drag a rectangle, then brings it back.
    func pickArea() {
        setupShown = false
        let shown = visibleMainWindows()
        shown.forEach { $0.orderOut(nil) }
        picker.run { [weak self] result in
            guard let self else { return }
            if let result { area = (result.0, result.1); kind = .area }
            shown.forEach { $0.makeKeyAndOrderFront(nil) }
            setupShown = true
        }
    }

    var canStart: Bool {
        guard hasPermission else { return false }
        switch kind {
        case .display: return true
        case .window: return windowID != nil
        case .area: return area != nil
        }
    }

    // MARK: Starting

    /// The global shortcut: starts a recording with the last choices, stops one, or cancels a countdown.
    func hotKeyPressed() {
        switch phase {
        case .idle:
            refreshPermission()
            if !hasPermission || (kind == .area && area == nil) || (kind == .window && windowID == nil) {
                NSApp.activate(ignoringOtherApps: true); showSetup(); return
            }
            start()
        case .countdown: cancel()
        case .recording, .paused: stop()
        case .finishing: break
        }
    }

    /// "Start Recording": counts down, then records.
    func start() {
        refreshPermission()
        guard phase == .idle, canStart else { if !hasPermission { showSetup() }; return }
        guard EditorModel.shared.confirmDiscardChanges() else { return }
        setupShown = false

        let target: CaptureTarget
        let name: String
        var screen = NSScreen.with(displayID: displayID) ?? NSScreen.main
        switch kind {
        case .display:
            target = .display(displayID)
            name = displays.first { $0.id == displayID }?.name ?? "Display"
        case .window:
            guard let id = windowID else { return }
            target = .window(id)
            let w = windows.first { $0.id == id }
            name = [w?.app, w?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if let w { NSRunningApplication(processIdentifier: w.pid)?.activate() }
        case .area:
            guard let a = area else { return }
            target = .area(a.display, a.rect)
            name = "Area"
            screen = NSScreen.with(displayID: a.display) ?? screen
        }


        let url: URL
        do { url = try Self.newRecordingURL() } catch { fail(error); return }
        let recorder = ScreenRecorder(fileURL: url)
        recorder.onUnexpectedStop = { [weak self] _ in
            Task { @MainActor in self?.stop() }   // e.g. the recorded window closed: keep what was recorded
        }
        self.recorder = recorder

        // Show what's being recorded before the stream is set up, so these windows are left out of it too.
        let highlight = RecordingHighlight()
        switch kind {
        case .area: if let a = area, let s = NSScreen.with(displayID: a.display) { highlight.showArea(a.rect, on: s) }
        case .window:
            if let id = windowID {
                highlight.showWindow(id)
                if let f = RecordingHighlight.appKitFrame(of: id) {
                    screen = NSScreen.screens.first { $0.frame.intersects(f) && $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) } ?? screen
                }
            }
        case .display: break
        }
        self.highlight = highlight

        let panel = RecordingControlPanel(controller: self)
        panel.show(on: screen)
        self.panel = panel

        let seconds = Settings.recordingCountdownSeconds
        phase = .countdown(seconds)   // set before hiding the editor, so the app doesn't quit with no window showing
        skipRequested = false
        // Out of the way: this app's windows aren't recorded anyway, but they'd cover what is.
        hiddenWindows = visibleMainWindows()
        hiddenWindows.forEach { $0.orderOut(nil) }
        let overlay = CountdownOverlay()
        if seconds > 0, let screen {
            overlay.show(on: screen, from: seconds, skip: { [weak self] in self?.skipRequested = true },
                         cancel: { [weak self] in self?.cancel() })
        }
        countdown = overlay

        countdownTask = Task { [weak self] in
            do {
                // Getting the stream ready runs during the countdown (the overlay and control are this app's, so not recorded).
                let prep = try await recorder.prepare(target: target, hideDesktopIcons: self?.hideDesktopIcons ?? true,
                                                      excludingWindowsOf: getpid(), name: name)
                countdown: for n in stride(from: seconds, to: 0, by: -1) {
                    self?.phase = .countdown(n); overlay.set(n)
                    for _ in 0..<20 {                                   // 1 s in small steps, so Skip is instant
                        if self?.skipRequested ?? false { break countdown }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                overlay.close()
                try await Task.sleep(nanoseconds: 120_000_000)   // let the countdown fade off the screen
                guard let self, case .countdown = phase else { return }
                log = CursorLogBuilder(geometry: prep.geometry, info: prep.info)
                try await recorder.start()
                beginRecording()
            } catch is CancellationError {
            } catch {
                self?.fail(error)
            }
        }
    }

    private func beginRecording() {
        phase = .recording
        let watcher = CursorWatcher { [weak self] point, buttons, shape in
            guard let self, let recorder else { return }
            log?.observe(videoTime: recorder.videoTime(atHost: ScreenRecorder.hostNow()), global: point, buttons: buttons, shape: shape)
        }
        watcher.start()
        self.watcher = watcher
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = self?.recorder?.clock.elapsed(ScreenRecorder.hostNow()) ?? 0 }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: While recording

    func togglePause() {
        switch phase {
        case .recording: recorder?.pause(); phase = .paused
        case .paused: recorder?.resume(); phase = .recording
        default: break
        }
    }

    /// Cancel during the countdown: nothing is kept.
    func cancel() {
        guard case .countdown = phase else { return }
        countdownTask?.cancel()
        let recorder = self.recorder
        Task { await recorder?.discard() }
        cleanUp()
    }

    /// Delete (the control's trash button, after its confirm): stops and keeps nothing.
    func deleteRecording() {
        guard phase == .recording || phase == .paused, let recorder else { return }
        watcher?.stop()
        Task { await recorder.discard() }
        cleanUp()
    }

    /// Stop: finishes the file, saves a project with the cursor log beside it, and opens it in the editor.
    func stop() {
        guard phase == .recording || phase == .paused, let recorder else { return }
        phase = .finishing
        watcher?.stop()
        NSApp.activate()   // asked now, while the Stop click or shortcut still counts as the user's own action
        Task {
            do {
                let duration = try await recorder.stop()
                log?.finish(at: duration)
                let package = try await saveProject(video: recorder.fileURL)
                await EditorModel.shared.openProject(package)
                EditorModel.shared.isFreshRecording = true
                cleanUp()   // after opening, so the window comes forward already showing the recording
            } catch {
                fail(error)
            }
        }
    }

    private func saveProject(video: URL) async throws -> URL {
        let info = try await VideoInfo.load(video)
        var project = Project(source: info.sourceVideo)
        project.cursor = log?.track ?? CursorTrack()
        let package = video.deletingPathExtension().appendingPathExtension(Settings.projectExtension)
        try ProjectStore.save(project, sourceURL: video, to: package)
        return package
    }

    private func fail(_ error: Error) {
        let recorder = self.recorder
        if phase != .finishing { Task { await recorder?.discard() } }
        cleanUp()
        EditorModel.shared.errorMessage = "Recording stopped. \(error.localizedDescription)"
    }

    private func cleanUp() {
        watcher?.stop(); watcher = nil
        timer?.invalidate(); timer = nil
        countdown?.close(); countdown = nil
        panel?.close(); panel = nil
        highlight?.close(); highlight = nil
        recorder = nil; log = nil; countdownTask = nil
        phase = .idle; elapsed = 0
        bringEditorForward()
    }

    /// Shows the editor window in front of whatever app was being recorded. `orderFrontRegardless`
    /// works even when macOS won't let the app become active from the background.
    private func bringEditorForward() {
        let windows = hiddenWindows.isEmpty
            ? NSApp.windows.filter { !($0 is NSPanel) && !($0 is OverlayWindow) && $0.canBecomeMain }
            : hiddenWindows
        hiddenWindows = []
        NSApp.activate()
        windows.forEach { $0.deminiaturize(nil); $0.orderFrontRegardless(); $0.makeKey() }
    }

    // MARK: Helpers

    /// For the debug snapshot: the floating control as it looks 12 s into a recording (nothing is recorded).
    func debugControlPanelView() -> NSView? {
        phase = .recording; elapsed = 12
        let p = RecordingControlPanel(controller: self)
        p.show(on: NSScreen.main)
        panel = p
        return p.contentView
    }

    /// The editor window(s), not the overlays or the floating control.
    private func visibleMainWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && !($0 is OverlayWindow) && $0.canBecomeMain }
    }

    /// ~/Movies/Video Editor/Recording 2026-11-13 at 14.05.22.mov
    static func newRecordingURL() throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent(Settings.recordingsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("Recording \(f.string(from: Date())).mov")
    }

    /// "0:07" or "1:02:07".
    static func timerText(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
