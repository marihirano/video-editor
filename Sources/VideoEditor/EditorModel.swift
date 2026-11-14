import AppKit
import EditorCore
import SwiftUI

/// The app's state and actions: what's open, saving, and exporting.
@MainActor
final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    @Published private(set) var project: Project? {
        didSet {
            drawer?.project = project
            playback.timeMap = timeMap   // playback only reacts if the kept parts changed
        }
    }
    @Published private(set) var sourceURL: URL?
    @Published private(set) var projectURL: URL?
    /// Length of the open recording, in seconds.
    @Published private(set) var sourceDuration: Double = 0
    /// The project as last opened or saved, to tell whether there are unsaved changes.
    @Published private var savedProject: Project?
    @Published private var history = UndoHistory<Project>()
    /// The blue line: where the mouse is over the timeline (finished-video seconds), or nil.
    @Published private(set) var hoverTime: Double?
    /// The blue line when not hovering: the last clicked spot (finished-video seconds). Split happens here.
    @Published private(set) var editTime: Double?
    /// The clip last clicked (highlighted), by its position on the timeline.
    @Published var selectedClip: Int? { didSet { if selectedClip != nil { selectedZoom = nil; isCropMode = false } } }
    /// The zoom last clicked; its settings show in the side panel.
    @Published var selectedZoom: Int? {
        didSet { if selectedZoom != nil { selectedClip = nil; isCropMode = false } }
    }
    /// True while the crop handles are on the preview.
    @Published private(set) var isCropMode = false { didSet { updatePreviewMode() } }
    /// True while the scissors tool is out: the next click on the timeline cuts there.
    @Published private(set) var isCutMode = false
    private lazy var cutMode = CutMode { [weak self] in self?.endCutMode() }
    /// Which tab the Style panel shows (the Cursor tab exists only for recordings made in the app).
    enum StyleTab: Hashable { case general, cursor }
    @Published var styleTab: StyleTab = .general
    @Published var errorMessage: String?
    @Published var export: ExportState?

    let playback: PlaybackController
    let drawer: PreviewDrawer?
    private var exporter: Exporter?

    enum ExportState: Equatable {
        case choosing
        case running(progress: Double)
        case finished(URL)
        case failed(String)
    }

    init() {
        let playback = PlaybackController()
        self.playback = playback
        drawer = MetalContext.shared.map { PreviewDrawer(renderer: FrameRenderer(context: $0), playback: playback) }
        if drawer == nil { errorMessage = "This Mac's graphics chip couldn't be used for the preview." }
    }

    var hasUnsavedChanges: Bool { project != nil && project != savedProject }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// How the timeline edits map the recording onto the finished video.
    var timeMap: TimeMap? { project.map { TimeMap(project: $0, sourceDuration: sourceDuration) } }

    /// Every edit goes through here, so each one can be undone. Quick repeats with the same
    /// `group` (a slider or handle drag) become one undo step.
    func edit(group: String? = nil, _ change: (inout Project) -> Void) {
        guard let old = project else { return }
        var p = old
        change(&p)
        guard p != old else { return }
        history.record(old, group: group)
        project = p
    }

    func undo() {
        guard let current = project, let previous = history.undo(current: current) else { return }
        project = previous
    }

    func redo() {
        guard let current = project, let next = history.redo(current: current) else { return }
        project = next
    }

    /// Changes the frame style (background, padding, corners, shadow); the preview updates at once.
    func updateStyle(_ change: (inout FrameStyle) -> Void) {
        edit(group: "style") { change(&$0.style) }
    }

    /// True for recordings made in the app (they have a cursor log); only these show the cursor controls.
    var hasCursorData: Bool { !(project?.cursor.samples.isEmpty ?? true) }

    func updateCursorLook(_ change: (inout CursorLook) -> Void) {
        edit(group: "cursorLook") { change(&$0.cursorLook) }
    }

    // MARK: Timeline (positions are finished-video seconds)

    var clips: [Clip] { project?.timeline.resolvedClips(sourceDuration: sourceDuration) ?? [] }

    /// Where the blue line is drawn: under the mouse, else the clicked spot.
    var blueLineTime: Double? { hoverTime ?? editTime }

    /// Mouse over the timeline: the blue line follows and the preview shows that moment.
    func hover(at t: Double?) {
        hoverTime = t
        cutMode.setOverTimeline(t != nil)
        guard let map = timeMap else { return }
        if let t { playback.skim(to: map.sourceTime(forOutput: t)) } else { playback.endSkim() }
    }

    /// Click (or drag) on the timeline: pins the blue line and moves the playhead there.
    func setEditPoint(_ t: Double) {
        guard let map = timeMap else { return }
        let t = min(max(t, 0), map.outputDuration)
        editTime = t
        playback.seek(to: map.sourceTime(forOutput: t))
    }

    /// Scissors button: takes the scissors tool out, or puts it away if it's already out.
    func toggleCutMode() { isCutMode ? endCutMode() : startCutMode() }

    func startCutMode() {
        guard project != nil else { return }
        isCropMode = false
        isCutMode = true
        cutMode.start()
    }

    func endCutMode() {
        isCutMode = false
        cutMode.stop()
    }

    /// A click on the timeline with the scissors tool: splits the clip there. The tool stays out
    /// until the scissors button is clicked again.
    func cut(atOutput t: Double) {
        let d = sourceDuration
        edit { $0.timeline.split(atOutput: t, sourceDuration: d) }
        setEditPoint(t)
    }

    /// ⌘B: splits the clip under the blue line (or the playhead if no line is set).
    func splitAtEditPoint() {
        guard project != nil else { return }
        let t = blueLineTime ?? playback.outputTime
        let d = sourceDuration
        edit { $0.timeline.split(atOutput: t, sourceDuration: d) }
    }

    func deleteClip(_ i: Int) {
        let d = sourceDuration
        edit { $0.timeline.deleteClip(i, sourceDuration: d) }
        selectedClip = nil
        // Keep the blue line and playhead inside the shorter video.
        if let map = timeMap {
            if let e = editTime { editTime = min(e, map.outputDuration) }
            playback.seek(to: map.sourceTime(forOutput: min(playback.outputTime, map.outputDuration)))
        }
    }

    func setSpeed(_ rate: Double, ofClip i: Int) {
        let d = sourceDuration
        let src = editTime.flatMap { timeMap?.sourceTime(forOutput: $0) }
        edit { $0.timeline.setRate(rate, ofClip: i, sourceDuration: d) }
        // The video's clock changed; keep the blue line on the same recorded moment.
        if let src, let map = timeMap { editTime = map.outputTime(forSource: src) }
    }

    // MARK: Zooms (positions are finished-video seconds; stored as recording seconds)

    var zooms: [ZoomSegment] { project?.timeline.zooms ?? [] }

    /// Output-time position of each zoom on the zoom track.
    var zoomRanges: [TimeRange] { timeMap.map { project?.timeline.zoomOutputRanges($0) ?? [] } ?? [] }

    /// Dragging across empty space on the zoom track adds a zoom there and selects it.
    func addZoom(from a: Double, to b: Double) {
        guard let map = timeMap else { return }
        var added: Int?
        edit { added = $0.timeline.addZoom(fromOutput: a, to: b, map: map) }
        if let added { selectedZoom = added }
    }

    /// Zoom menu / shortcut: adds the same zoom a click on the zoom track would, at the blue line (or playhead).
    func addZoomAtEditPoint() {
        guard let map = timeMap else { return }
        let t = editTime ?? playback.outputTime
        guard let r = project?.timeline.clickZoomRange(atOutput: t, map: map) else { NSSound.beep(); return }
        addZoom(from: r.start, to: r.end)
        setEditPoint(t)
    }

    /// Playback menu: jump to the start or end of the finished video.
    func goToStart() { setEditPoint(0) }
    func goToEnd() { if let d = timeMap?.outputDuration { setEditPoint(d) } }

    /// Moving a zoom block (one drag = one undo step).
    func moveZoom(_ i: Int, toStart t: Double) {
        guard let map = timeMap else { return }
        edit(group: "zoom-move") { _ = $0.timeline.moveZoom(i, toOutputStart: t, map: map) }
    }

    /// Dragging one end of a zoom block.
    func resizeZoom(_ i: Int, startEdge: Bool, to t: Double) {
        guard let map = timeMap else { return }
        edit(group: "zoom-resize") { $0.timeline.resizeZoom(i, startEdge: startEdge, toOutput: t, map: map) }
    }

    /// Changes one zoom's amount, point or easing (slider drags = one undo step per control).
    func updateZoom(_ i: Int, group: String, _ change: (inout ZoomSegment) -> Void) {
        edit(group: "zoom-\(group)") { p in
            guard p.timeline.zooms.indices.contains(i) else { return }
            change(&p.timeline.zooms[i])
        }
    }

    func deleteZoom(_ i: Int) {
        edit { $0.timeline.deleteZoom(i) }
        selectedZoom = nil
    }

    // MARK: Crop

    /// Crop button: shows the crop handles on the preview (or puts them away).
    func toggleCropMode() { isCropMode ? endCropMode() : startCropMode() }

    func startCropMode() {
        guard project != nil else { return }
        endCutMode()
        selectedClip = nil; selectedZoom = nil
        isCropMode = true
    }

    func endCropMode() { isCropMode = false }

    /// The crop as fractions of the recording (0–1), or the whole frame.
    var cropFraction: CGRect {
        guard let p = project, let c = p.crop, p.source.width > 0, p.source.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: c.x / Double(p.source.width), y: c.y / Double(p.source.height),
                      width: c.width / Double(p.source.width), height: c.height / Double(p.source.height))
    }

    /// Sets the crop from fractions of the recording. The whole frame means "no crop".
    func setCrop(_ r: CGRect) {
        edit(group: "crop") { p in
            let w = Double(p.source.width), h = Double(p.source.height)
            let x0 = (r.minX * w).rounded(), y0 = (r.minY * h).rounded()
            let x1 = (r.maxX * w).rounded(), y1 = (r.maxY * h).rounded()
            let c = CropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            p.crop = (c.x <= 0 && c.y <= 0 && c.width >= w && c.height >= h) ? nil : c
        }
    }

    func resetCrop() { edit { $0.crop = nil } }

    /// Tells the preview what to leave out while editing on it.
    private func updatePreviewMode() {
        drawer?.mode = isCropMode ? .wholeFrame : .normal
    }

    /// Moves the playhead into the fully zoomed-in part of zoom `i` (unless it's already there),
    /// so the preview shows the zoom while it's being aimed.
    func showZoomInPreview(_ i: Int) {
        guard let map = timeMap, zoomRanges.indices.contains(i), zooms.indices.contains(i), !playback.isPlaying else { return }
        let r = zoomRanges[i]
        let d = min(zooms[i].transition, (r.end - r.start) / 2)
        let now = playback.outputTime
        if now < r.start + d || now > r.end - d {
            let mid = (r.start + r.end) / 2
            editTime = mid
            playback.seek(to: map.sourceTime(forOutput: mid))
        }
    }

    /// Recording moment (seconds) shown in the zoom's "where it points" picture: its middle.
    func zoomStillTime(_ i: Int) -> Double? {
        guard let map = timeMap, zoomRanges.indices.contains(i) else { return nil }
        let r = zoomRanges[i]
        return map.sourceTime(forOutput: (r.start + r.end) / 2)
    }

    /// Name shown in the window title.
    var displayName: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        return sourceURL?.lastPathComponent ?? "Video Editor"
    }

    // MARK: Opening

    func showOpenPanel() async {
        if let url = FilePanels.chooseFileToOpen() { await open(url) }
    }

    /// Opens a project package or imports a video, depending on what it is.
    func open(_ url: URL) async {
        guard confirmDiscardChanges() else { return }
        FilePanels.isProject(url) ? await openProject(url) : await importVideo(url)
    }

    func importVideo(_ url: URL) async {
        do {
            let info = try await VideoInfo.load(url)
            show(Project(source: info.sourceVideo), source: info, projectURL: nil)
        } catch {
            errorMessage = "Couldn't open “\(url.lastPathComponent)”. \(error.localizedDescription)"
        }
    }

    func openProject(_ url: URL) async {
        do {
            let (project, source) = try ProjectStore.load(from: url)
            let info = try await VideoInfo.load(source)
            show(project, source: info, projectURL: url)
        } catch {
            errorMessage = "Couldn't open the project “\(url.lastPathComponent)”. \(error.localizedDescription)"
        }
    }

    private func show(_ project: Project, source: VideoInfo, projectURL: URL?) {
        playback.pause()
        sourceDuration = source.duration
        self.project = project
        savedProject = project
        history.reset()
        hoverTime = nil; editTime = nil; selectedClip = nil; selectedZoom = nil; isCropMode = false
        self.sourceURL = source.url
        self.projectURL = projectURL
        playback.load(source)
        if projectURL == nil { NSDocumentController.shared.noteNewRecentDocumentURL(source.url) }
        else { NSDocumentController.shared.noteNewRecentDocumentURL(projectURL!) }
    }

    // MARK: Saving

    func save() {
        if let projectURL { write(to: projectURL) } else { saveAs() }
    }

    func saveAs() {
        guard let sourceURL else { return }
        let name = sourceURL.deletingPathExtension().lastPathComponent + "." + Settings.projectExtension
        if let url = FilePanels.chooseProjectLocation(suggestedName: name) { write(to: url) }
    }

    private func write(to url: URL) {
        guard let project, let sourceURL else { return }
        do {
            try ProjectStore.save(project, sourceURL: sourceURL, to: url)
            projectURL = url
            savedProject = project
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorMessage = "Couldn't save the project. \(error.localizedDescription)"
        }
    }

    /// Before closing, quitting or opening something else: offers to save unsaved changes.
    /// Returns false if the person chose Cancel (or cancelled the save).
    func confirmDiscardChanges() -> Bool {
        if isFreshRecording { return confirmCloseRecording() }
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        alert.addButton(withTitle: projectURL == nil ? "Save…" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !hasUnsavedChanges
        case .alertThirdButtonReturn: savedProject = project; return true   // so quitting next doesn't ask again
        default: return false
        }
    }

    /// True for a recording just made in the app, until it's exported or dealt with by the prompt below.
    var isFreshRecording = false

    /// Closing (or quitting, or opening something else) with a fresh recording asks first, even with no edits
    /// (Mari). Delete moves the video and its project to the Trash; Keep saves any edits and leaves both
    /// in Movies › Video Editor.
    private func confirmCloseRecording() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(displayName)”?"
        alert.informativeText = "Closing will move this recording to the Trash. To keep it, choose Keep Recording. It stays in Movies › Video Editor."
        alert.addButton(withTitle: "Delete Recording").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep Recording")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for url in [sourceURL, projectURL].compactMap({ $0 }) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            savedProject = project; isFreshRecording = false
            return true
        case .alertThirdButtonReturn:
            if hasUnsavedChanges { save() }
            isFreshRecording = false
            return !hasUnsavedChanges
        default: return false
        }
    }

    // MARK: Exporting

    /// Export button / menu: opens the options sheet. "Export…" in the sheet then asks where to save.
    func startExport() {
        guard project != nil, export == nil else { return }
        export = .choosing
    }

    /// Changes the export choices (format, size, frame rate); saved with the project and undoable.
    func setOutput(_ change: (inout OutputSettings) -> Void) {
        edit(group: "output") { change(&$0.output) }
    }

    /// One line describing what the current choices will make, e.g. "1920×1080 · 60 fps".
    var exportSummary: String {
        guard let o = project?.output else { return "" }
        return o.format == .gif ? "GIF \(o.gifSize.width)×\(o.gifSize.height) · \(o.gifFPS) fps"
                                : "MP4 \(o.width)×\(o.height) · \(o.fps) fps"
    }

    func confirmExport() {
        guard let project, let sourceURL, case .choosing? = export else { return }
        let isGIF = project.output.format == .gif
        let name = displayName.replacingOccurrences(of: "." + sourceURL.pathExtension, with: "") + (isGIF ? ".gif" : ".mp4")
        export = nil
        guard let outURL = FilePanels.chooseExportLocation(suggestedName: name, gif: isGIF) else { export = .choosing; return }
        playback.pause()
        let exporter = Exporter()
        self.exporter = exporter
        export = .running(progress: 0)
        Task {
            do {
                try await exporter.export(project: project, sourceURL: sourceURL, to: outURL) { [weak self] p in
                    MainActor.assumeIsolated {
                        if case .running = self?.export { self?.export = .running(progress: p) }
                    }
                }
                export = .finished(outURL)
                isFreshRecording = false   // exported, so closing no longer offers to delete it
            } catch is CancellationError {
                export = nil
            } catch {
                export = .failed(error.localizedDescription)
            }
            self.exporter = nil
        }
    }

    func cancelExport() { exporter?.cancel() }

    func dismissExport() { export = nil }
}
