import AppKit
import EditorCore

/// For Claude's checks: launched with VET_SNAPSHOT=/path.png (and a video to open), the app
/// saves a picture of its window, logs whether the preview drew video, and quits.
/// The Metal preview itself shows as blank in this picture; only the layout around it is captured.
@MainActor
enum DebugSnapshot {
    private static let debugHighlight = RecordingHighlight()
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VET_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let model = EditorModel.shared
            // VET_SNAPSHOT_APPEARANCE=light|dark|system forces the look for this run only (nothing is saved).
            if let mode = ProcessInfo.processInfo.environment["VET_SNAPSHOT_APPEARANCE"] { Theme.AppearanceMode.apply(mode) }
            // VET_SNAPSHOT_SHAPE=wide|square|vertical picks the video's shape (same path as the Style panel's choice).
            if let raw = ProcessInfo.processInfo.environment["VET_SNAPSHOT_SHAPE"], let shape = VideoShape(rawValue: raw) {
                model.setOutput { $0.setShape(shape) }
            }
            // VET_SNAPSHOT_SPLIT=1 cuts once with the scissors tool at a third of the way and pins the blue line there.
            if ProcessInfo.processInfo.environment["VET_SNAPSHOT_SPLIT"] != nil, let map = model.timeMap {
                model.startCutMode()                       // same path as the scissors button
                model.cut(atOutput: map.outputDuration / 3)
                model.endCutMode()
                model.selectedClip = 1
            }
            // VET_SNAPSHOT_ZOOM=1 adds two zooms by the same path as dragging on the zoom track, and selects the second.
            let env = ProcessInfo.processInfo.environment
            if env["VET_SNAPSHOT_ZOOM"] != nil, let map = model.timeMap {
                let d = map.outputDuration
                model.addZoom(from: d * 0.08, to: d * 0.3)
                model.addZoom(from: d * 0.62, to: d * 0.45)
                model.updateZoom(1, group: "point") { $0.centerX = 0.7; $0.centerY = 0.35; $0.scale = 2 }
                model.setEditPoint(d * 0.5)
            }
            // VET_SNAPSHOT_CROP=1 crops to the middle and shows the crop handles.
            if env["VET_SNAPSHOT_CROP"] != nil {
                model.setCrop(CGRect(x: 0.15, y: 0.1, width: 0.6, height: 0.7))
                model.startCropMode()
            }
            // VET_SNAPSHOT_EXPORT=gif (or mp4) opens the export window with that format; it is saved as `…-sheet.png`.
            if let format = env["VET_SNAPSHOT_EXPORT"] {
                model.setOutput { $0.format = format == "gif" ? .gif : .mp4 }
                model.startExport()
            }
            // VET_SNAPSHOT_RECORD=display|window|area opens the Record window on that choice (`…-sheet.png`)
            // and shows the floating recording control (`…-panel.png`) as if recording for 12 s.
            var panelView: NSView?
            var overlayView: NSView?
            if let kind = env["VET_SNAPSHOT_RECORD"] {
                let rec = RecordingController.shared
                rec.kind = RecordingController.Kind(rawValue: kind) ?? .display
                if rec.kind == .area { rec.area = (CGMainDisplayID(), CGRect(x: 200, y: 150, width: 1280, height: 720)) }
                rec.showSetup()
                panelView = rec.debugControlPanelView()
                if rec.kind == .area, let a = rec.area, let screen = NSScreen.with(displayID: a.display) {
                    debugHighlight.showArea(a.rect, on: screen)
                    overlayView = debugHighlight.contentView
                }
            }
            let busy = env["VET_SNAPSHOT_ZOOM"] != nil || env["VET_SNAPSHOT_CROP"] != nil || env["VET_SNAPSHOT_EXPORT"] != nil || env["VET_SNAPSHOT_RECORD"] != nil
            if !busy { model.playback.play() }
            DispatchQueue.main.asyncAfter(deadline: .now() + (env["VET_SNAPSHOT_EXPORT"] != nil || env["VET_SNAPSHOT_RECORD"] != nil ? 5 : 1)) {
                if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible })?.contentView?.superview,
                   let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
                    sheet.cacheDisplay(in: sheet.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-sheet.png"))
                }
                if let v = overlayView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-overlay.png"))
                }
                if let v = panelView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-panel.png"))
                }
                // The window content, plus the top bar on its own (`…-top.png`).
                let content = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet })?.contentView
                for (view, file) in [(content, path), (content?.superview, path + "-top.png")] {
                    guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                }
                let line = "shape=\(model.project?.output.shape.rawValue ?? "-") zooms=\(model.zooms.count) crop=\(String(describing: model.project?.crop)) project=\(model.project != nil) playing=\(model.playback.isPlaying) time=\(model.playback.currentTime) videoFramesDrawn=\(model.drawer?.videoFramesDrawn ?? -1)\n"
                try? line.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                exit(0)   // quit without the save prompt (the snapshot may have made edits)
            }
        }
    }
}
