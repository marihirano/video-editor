import AppKit
import AVFoundation
import EditorCore
import Foundation

// Plain-program checks for the core. Run: swift run CoreChecks
if try await DebugDump.run() { exit(0) }
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vet-checks-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

print("Project file")
do {
    let source = tmp.appendingPathComponent("clip.mov")
    try Data("x".utf8).write(to: source)
    let package = tmp.appendingPathComponent("Demo.\(Settings.projectExtension)")
    try ProjectStore.save(Project(source: SourceVideo(path: source.path, width: 2880, height: 1800, duration: 3)),
                          sourceURL: source, to: package)
    let json = try String(contentsOf: package.appendingPathComponent(Settings.projectFileName), encoding: .utf8)
    check(json.contains("\"cursor\""), "project.json has the cursor slot")
    check(json.contains("\"relativePath\" : \"clip.mov\""), "source saved relative to the project")
    let (loaded, url) = try ProjectStore.load(from: package)
    check(url.standardizedFileURL.path == source.standardizedFileURL.path, "reopen finds the source video")
    check(loaded.output.width == 1920 && loaded.output.height == 1080, "output defaults to 1080p")

    let minimal = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1}}"#
    let p = try JSONDecoder().decode(Project.self, from: Data(minimal.utf8))
    check(p.output.fps == Settings.defaultOutputFPS && p.timeline.clips.isEmpty, "older or partial files still open")
}

print("Style")
do {
    var st = FrameStyle()
    st.kind = .image; st.imagePath = "/tmp/x.png"; st.padding = 12.5; st.cornerRadius = 30
    st.shadowOpacity = 0.7; st.shadowBlur = 55; st.shadowOffset = 9; st.wallpaper = 3
    st.gradientStart = RGBAColor(hex: 0x123456); st.gradientAngle = 200
    var proj = Project(source: SourceVideo(path: "/x.mov", width: 10, height: 10, duration: 1))
    proj.style = st
    let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(proj))
    check(back.style == st, "style survives save and reopen")

    let m1 = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"style":{"background":{"r":0,"g":0,"b":0,"a":1}}}"#
    let old = try JSONDecoder().decode(Project.self, from: Data(m1.utf8))
    check(old.style.padding == Settings.defaultPadding && old.style.cornerRadius == Settings.defaultCornerRadius
          && old.style.kind == Settings.defaultBackgroundKind && old.style.background.r == 0,
          "M1 project (only `background`) opens with default look")

    var padded = Project(source: SourceVideo(path: "", width: 1440, height: 900, duration: 1))
    padded.style.padding = 10
    let pu = FrameLayout.uniforms(project: padded, sourceSize: CGSize(width: 1440, height: 900), outputTime: 0)
    check(abs(pu.contentRect.y - 0.1) < 1e-5 && abs(pu.contentRect.w - 0.8) < 1e-5, "10% padding leaves 10% free above and below")
}

print("Timeline")
do {
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
    var tl = Timeline()
    check(tl.resolvedClips(sourceDuration: 10) == [Clip(start: 0, end: 10)], "no edits: one clip, the whole recording")
    check(near(TimeMap(timeline: tl, sourceDuration: 10).outputDuration, 10), "no edits: video is as long as the recording")
    // Split at 1, 3, 4, 5, 7, 9 → clips 0–1 | 1–3 | 3–4 | 4–5 | 5–7 | 7–9 | 9–10
    for at in [1.0, 3, 4, 5, 7, 9] { tl.split(atOutput: at, sourceDuration: 10) }
    check(tl.clips.count == 7, "six splits make seven clips")
    check(!tl.split(atOutput: 3.05, sourceDuration: 10), "a split right next to another is refused")
    tl.deleteClip(6, sourceDuration: 10)       // drop 9–10
    tl.deleteClip(2, sourceDuration: 10)       // drop 3–4
    tl.deleteClip(0, sourceDuration: 10)       // drop 0–1 → 1–3 | 4–5 | 5–7 | 7–9  (7 s)
    tl.setRate(4, ofClip: 2, sourceDuration: 10)  // 5–7 at 4× → 0.5 s → 5.5 s
    let map = TimeMap(timeline: tl, sourceDuration: 10)
    check(near(map.outputDuration, 5.5), "delete three clips + one at 4×: 5.5 s long (\(map.outputDuration))")
    check(near(map.sourceTime(forOutput: 0), 1), "video starts at the first kept clip")
    check(near(map.sourceTime(forOutput: 2.5), 4.5), "jumps over a deleted clip")
    check(near(map.sourceTime(forOutput: 3.25), 6), "sped-up clip runs 4× faster")
    check(near(map.sourceTime(forOutput: 5.5), 9), "video ends with the last clip")
    check(near(map.outputTime(forSource: 3.5), 2), "a deleted moment maps to where the video carries on")
    check(map.pieceIndex(atOutput: 3.0) == 2, "finds the clip under a timeline position")
    var last = -1.0, monotonic = true
    for i in 0...550 { let s = map.sourceTime(forOutput: Double(i) / 100); if s < last - 1e-9 { monotonic = false }; last = s }
    check(monotonic, "source time never goes backwards")
    var one = Timeline(); one.deleteClip(0, sourceDuration: 10)
    check(one.resolvedClips(sourceDuration: 10).count == 1, "the last clip can't be deleted")

    var proj = Project(source: SourceVideo(path: "/x.mov", width: 10, height: 10, duration: 10))
    proj.timeline = tl
    let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(proj))
    check(back.timeline == tl, "clips and speeds survive save and reopen")

    let m3 = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":10},"timeline":{"trim":{"start":1,"end":9},"cuts":[{"start":3,"end":4}],"speedSegments":[{"range":{"start":5,"end":7},"rate":4}]}}"#
    let old = try JSONDecoder().decode(Project.self, from: Data(m3.utf8))
    check(near(TimeMap(project: old, sourceDuration: 10).outputDuration, 5.5), "first-M3 files (trim, cuts, speed) open as clips")

    var h = UndoHistory<Int>()
    let t0 = Date()
    h.record(0, group: "style", now: t0); h.record(1, group: "style", now: t0 + 0.1); h.record(2, group: "style", now: t0 + 0.2)
    h.record(3, now: t0 + 0.3)
    check(h.undo(current: 4) == 3 && h.undo(current: 3) == 0 && !h.canUndo, "one slider drag is one undo step")
    check(h.redo(current: 0) == 3 && h.redo(current: 3) == 4 && !h.canRedo, "redo brings edits back")
}

print("Zoom and crop")
do {
    func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }
    // Easing curve shape.
    check(Spring.value(0, bounce: 0) == 0 && near(Spring.value(1, bounce: 0), 1), "easing starts at 0 and ends at 1")
    check(Spring.value(0.03, bounce: 0) < 0.03, "easing starts at rest (slow first moment)")
    check(Spring.value(0.5, bounce: 0) > 0.75, "easing is mostly there by halfway (spring feel)")
    var mono = true, prev = -1.0
    for i in 0...200 { let v = Spring.value(Double(i) / 200, bounce: 0); if v < prev - 1e-12 || v > 1 + 1e-9 { mono = false }; prev = v }
    check(mono, "no bounce: never goes backwards or past 1")
    let peak = (0...200).map { Spring.value(Double($0) / 200, bounce: 1) }.max()!
    check(peak > 1.05 && peak < 1.25 && near(Spring.value(1, bounce: 1), 1), "full bounce overshoots a little, then lands on 1 (peak \(String(format: "%.3f", peak)))")

    // Placement: zoom at 6–8 s of a 10 s recording.
    var tl = Timeline()
    tl.zooms = [ZoomSegment(range: TimeRange(start: 6, end: 8), centerX: 0.25, centerY: 0.75, scale: 2)]
    for at in [2.0, 4.0, 9.0] { tl.split(atOutput: at, sourceDuration: 10) }   // 0–2 | 2–4 | 4–9 | 9–10
    tl.deleteClip(1, sourceDuration: 10)                                         // drop 2–4
    var map = TimeMap(timeline: tl, sourceDuration: 10)
    var r = tl.zoomOutputRanges(map)[0]
    check(near(r.start, 4) && near(r.end, 6), "deleting an earlier clip moves the zoom with its content (\(r.start)–\(r.end))")
    tl.setRate(2, ofClip: 1, sourceDuration: 10)                                 // 4–9 at 2×
    map = TimeMap(timeline: tl, sourceDuration: 10)
    r = tl.zoomOutputRanges(map)[0]
    check(near(r.start, 3) && near(r.end, 4), "speeding up its clip shortens the zoom in the video (\(r.start)–\(r.end))")
    tl.zooms.append(ZoomSegment(range: TimeRange(start: 0.5, end: 1.5)))
    tl.deleteClip(0, sourceDuration: 10)                                         // drop 0–2 with its zoom
    check(tl.zooms.count == 1 && tl.zooms[0].scale == 2, "a zoom on a deleted clip goes with it")

    // Add / move / resize on the finished video's clock, never overlapping.
    var t2 = Timeline()
    let m2 = TimeMap(timeline: t2, sourceDuration: 10)
    let a = t2.addZoom(fromOutput: 2, to: 4, map: m2)
    let b = t2.addZoom(fromOutput: 7, to: 5, map: m2)
    check(a == 0 && b == 1 && t2.zooms.count == 2, "drag adds zooms (either direction)")
    check(t2.addZoom(fromOutput: 3, to: 3.5, map: m2) == nil, "can't add a zoom on top of another")
    t2.addZoom(fromOutput: 4.1, to: 9, map: m2)
    check(t2.zooms.count == 3 && near(t2.zooms[1].range.end, 5), "a new zoom stops at the next zoom")
    t2.deleteZoom(1)
    t2.moveZoom(0, toOutputStart: 6, map: m2)
    check(near(t2.zooms[0].range.start, 3) && near(t2.zooms[0].range.end, 5), "moving stops at the neighbour and keeps the length")
    t2.resizeZoom(0, startEdge: true, toOutput: 4.95, map: m2)
    check(near(t2.zooms[0].range.start, 5 - Settings.minimumZoomSeconds), "resizing keeps the minimum length")
    t2.resizeZoom(0, startEdge: true, toOutput: -3, map: m2)
    check(near(t2.zooms[0].range.start, 0), "resizing stops at the start of the video")

    // Click on the empty zoom track: 10% of the video from the click, fitted into the free space.
    var t3 = Timeline()
    let m36 = TimeMap(timeline: t3, sourceDuration: 36)
    let c1 = t3.clickZoomRange(atOutput: 10, map: m36)
    check(near(c1!.start, 10) && near(c1!.end, 13.6), "click adds 3.6 s (10% of a 36 s video) from the click")
    let ce = t3.clickZoomRange(atOutput: 35.5, map: m36)!
    check(near(ce.start, 32.4) && near(ce.end, 36), "near the end, the new zoom moves earlier to fit")
    check(TimeMap(timeline: Timeline(), sourceDuration: 10).outputDuration == 10
          && Timeline().clickZoomRange(atOutput: 2, map: TimeMap(timeline: Timeline(), sourceDuration: 10)) == TimeRange(start: 2, end: 3),
          "short video: at least 1 s")
    t3.addZoom(fromOutput: 11, to: 20, map: m36)
    let sq = t3.clickZoomRange(atOutput: 10.5, map: m36)!
    check(near(sq.start, 7.4) && near(sq.end, 11), "just before the next zoom, the new zoom moves earlier to fit")
    let tiny = Timeline(zooms: [ZoomSegment(range: TimeRange(start: 0, end: 5)), ZoomSegment(range: TimeRange(start: 5.6, end: 9))])
    let sh = tiny.clickZoomRange(atOutput: 5.2, map: m36)!
    check(near(sh.start, 5) && near(sh.end, 5.6), "a small gap gets a shorter zoom that fills it")
    check(t3.clickZoomRange(atOutput: 12, map: m36) == nil, "no placeholder on top of a zoom")

    // Camera.
    let cam = ZoomCamera(zooms: [ZoomSegment(range: TimeRange(start: 1, end: 5), centerX: 0.5, centerY: 0.5, scale: 2, transition: 1, bounce: 0)],
                         map: TimeMap(timeline: Timeline(), sourceDuration: 10))
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
    check(cam.visibleRect(atOutput: 0.5, cropped: frame) == frame, "before a zoom: whole frame")
    let mid = cam.visibleRect(atOutput: 3, cropped: frame)
    check(near(mid.width, 500, 1e-6) && near(mid.midX, 500, 1e-6) && near(mid.midY, 250, 1e-6), "fully zoomed: half the frame around the point")
    check(cam.visibleRect(atOutput: 1.5, cropped: frame).width < 1000 && cam.visibleRect(atOutput: 1.5, cropped: frame).width > 500, "halfway in: partly zoomed")
    let edge = ZoomCamera.targetRect(ZoomSegment(range: TimeRange(start: 0, end: 1), centerX: 1, centerY: 0, scale: 2), cropped: frame)
    check(edge == CGRect(x: 500, y: 0, width: 500, height: 250), "zooming at a corner stays inside the frame")

    // Zoom is a camera on the whole picture: fully zoomed, the framed video grows past the canvas edges.
    var padded = Project(source: SourceVideo(path: "/x.mov", width: 1440, height: 900, duration: 10))
    padded.style.padding = 10
    padded.timeline.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 5), centerX: 0.5, centerY: 0.5, scale: 2, transition: 1, bounce: 0)]
    let zu = FrameLayout.uniforms(project: padded, sourceSize: CGSize(width: 1440, height: 900), outputTime: 3)
    let r0 = FrameLayout.uniforms(project: padded, sourceSize: CGSize(width: 1440, height: 900), outputTime: 0)
    check(zu.contentRect.y < 0 && zu.contentRect.y + zu.contentRect.w > 1 && zu.sourceRect == r0.sourceRect,
          "fully zoomed: the whole frame grows past the picture's edges (video not re-cropped)")
    check(abs(zu.shape.x - 2 * r0.shape.x) < 1e-4 && abs(zu.camera.z - 0.5) < 1e-6, "corners and shadow grow with the zoom; background zooms too")
    padded.timeline.zooms[0].centerX = 0; padded.timeline.zooms[0].centerY = 0
    let zc = FrameLayout.uniforms(project: padded, sourceSize: CGSize(width: 1440, height: 900), outputTime: 3)
    check(abs(zc.camera.x) < 1e-6 && abs(zc.camera.y) < 1e-6 && zc.contentRect.x > 0.1 && zc.contentRect.y > 0.1,
          "zooming at a corner shows the padding and background there")

    // Save and reopen.
    var proj = Project(source: SourceVideo(path: "/x.mov", width: 1440, height: 900, duration: 10))
    proj.timeline.zooms = [ZoomSegment(range: TimeRange(start: 1, end: 3), centerX: 0.2, centerY: 0.8, scale: 2.5, transition: 0.7, bounce: 0.3)]
    proj.crop = CropRect(x: 100, y: 50, width: 800, height: 500)
    let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(proj))
    check(back.timeline.zooms == proj.timeline.zooms && back.crop == proj.crop, "zooms and crop survive save and reopen")
    let partial = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"timeline":{"zooms":[{"range":{"start":0,"end":1},"centerX":0.5,"centerY":0.5,"scale":2}]}}"#
    let pz = try JSONDecoder().decode(Project.self, from: Data(partial.utf8)).timeline.zooms[0]
    check(pz.scale == 2 && pz.transition == Settings.zoomEasingPresets[Settings.defaultZoomEasing].transition, "zooms without easing fields open with the default easing")
    let cu = FrameLayout.uniforms(project: proj, sourceSize: CGSize(width: 1440, height: 900), outputTime: 0)
    check(abs(cu.sourceRect.x - Float(100.0 / 1440)) < 1e-5 && abs(cu.sourceRect.z - Float(800.0 / 1440)) < 1e-5, "crop picks the right part of the frame")
    let cw = FrameLayout.uniforms(project: proj, sourceSize: CGSize(width: 1440, height: 900), outputTime: 0, mode: .wholeFrame)
    check(cw.sourceRect == SIMD4<Float>(0, 0, 1, 1), "crop editing shows the whole recording")
}

print("Renderer")
check(MetalContext.shared != nil, "Metal shaders compile at startup")
var plain = Project(source: SourceVideo(path: "", width: 1440, height: 900, duration: 1))
plain.style.padding = 0
let u = FrameLayout.uniforms(project: plain,
                             sourceSize: CGSize(width: 1440, height: 900), outputTime: 0)
check(abs(u.contentRect.z - Float(1.6 / (16.0 / 9.0))) < 1e-5 && u.contentRect.w == 1, "16:10 video fits a 16:9 canvas, centred")

print("Export")
do {
    let source = tmp.appendingPathComponent("source.mov")
    try await TestVideo.make(at: source, width: 1440, height: 900, seconds: 2, fps: 30)
    let info = try await VideoInfo.load(source)
    check(info.width == 1440 && abs(info.duration - 2) < 0.05, "reads the test video")

    let out = tmp.appendingPathComponent("out.mp4")
    let exporter = Exporter()
    let start = Date()
    try await exporter.export(project: Project(source: info.sourceVideo), sourceURL: source, to: out) { _ in }
    let asset = AVURLAsset(url: out)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let size = try await video[0].load(.naturalSize)
    let duration = try await asset.load(.duration).seconds
    let frames = try await video[0].load(.nominalFrameRate)
    check(size == CGSize(width: 1920, height: 1080), "MP4 is 1920×1080")
    check(abs(duration - 2) < 0.05, "MP4 is 2 seconds long (\(duration))")
    check(audio.isEmpty, "MP4 is silent")
    check(exporter.usedHardwareEncoder, "hardware encoder used")
    print(String(format: "  info took %.2fs, %.0f fps, file: %@", Date().timeIntervalSince(start), frames, out.path))

    if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] {
        let g = AVAssetImageGenerator(asset: asset)
        let (img, _) = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 60))
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("default-frame.png"))
    }
    // A styled export: 10% padding, big corners, plain magenta background, no shadow.
    var styled = Project(source: info.sourceVideo)
    styled.style.kind = .solid
    styled.style.background = RGBAColor(r: 1, g: 0, b: 1, a: 1)
    styled.style.padding = 10; styled.style.cornerRadius = 60; styled.style.shadowOpacity = 0
    let out2 = tmp.appendingPathComponent("styled.mp4")
    try await Exporter().export(project: styled, sourceURL: source, to: out2) { _ in }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out2))
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let (cg, _) = try await gen.image(at: .zero)
    if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] {
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        try png?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("styled-frame.png"))
    }
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let rep = NSBitmapImageRep(cgImage: cg)
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) < 90
    }
    check(near(pixel(5, 5), (255, 0, 255)), "styled export: canvas corner is background")
    check(near(pixel(272, 112), (255, 0, 255)), "styled export: video's corner is rounded off")
    check(near(pixel(960, 540), (0, 194, 208)), "styled export: video fills the middle")
    check(near(pixel(100, 540), (255, 0, 255)), "styled export: padding strip is background")

    // An edited export: split at 0.2, 0.6, 1.0, 1.4, 1.8; delete 0–0.2, 0.6–1.0, 1.8–2; 1.0–1.4 at 4×
    // → 0.4 + 0.1 + 0.4 = 0.9 s.
    var edited = Project(source: info.sourceVideo)
    edited.style.kind = .solid   // plain background so this check does not depend on the default look
    for at in [0.2, 0.6, 1.0, 1.4, 1.8] { edited.timeline.split(atOutput: at, sourceDuration: info.duration) }
    for i in [5, 2, 0] { edited.timeline.deleteClip(i, sourceDuration: info.duration) }
    edited.timeline.setRate(4, ofClip: 1, sourceDuration: info.duration)
    let expected = TimeMap(project: edited, sourceDuration: info.duration).outputDuration
    let out3 = tmp.appendingPathComponent("edited.mp4")
    try await Exporter().export(project: edited, sourceURL: source, to: out3) { _ in }
    let editedDuration = try await AVURLAsset(url: out3).load(.duration).seconds
    check(abs(expected - 0.9) < 1e-6 && abs(editedDuration - 0.9) < 0.04, "edited export (deleted clips, 4× clip) is 0.9 s (\(editedDuration))")

    // The test video changes colour every frame, so comparing the middle pixel with the unedited
    // export (same look) at the matching source moment shows each frame came from the right place.
    func redAt(_ url: URL, _ t: Double) async throws -> Double {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let (img, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
        return Double(NSBitmapImageRep(cgImage: img).colorAt(x: 960, y: 540)!.usingColorSpace(.sRGB)!.redComponent * 255)
    }
    var rightFrames = true, report = ""
    for (outT, srcT) in [(0.05, 0.25), (0.3, 0.5), (0.45, 1.2), (0.7, 1.6)] {
        let got = try await redAt(out3, outT), want = try await redAt(out, srcT)
        report += String(format: " %.0f/%.0f", got, want)
        if abs(got - want) > 6 { rightFrames = false }
    }
    check(rightFrames, "edited export shows the right moments (red got/expected:\(report))")
    // Crop + zoom export: crop to the top-left 384×240 (same shape as the recording), then a 2×
    // zoom on its centre for the whole video. Green = source row, blue steps 1 per source column.
    var zoomed = Project(source: info.sourceVideo)
    zoomed.style.padding = 0; zoomed.style.cornerRadius = 0; zoomed.style.shadowOpacity = 0
    zoomed.crop = CropRect(x: 0, y: 0, width: 384, height: 240)
    let out4 = tmp.appendingPathComponent("crop.mp4"), out5 = tmp.appendingPathComponent("zoom.mp4")
    try await Exporter().export(project: zoomed, sourceURL: source, to: out4) { _ in }
    zoomed.timeline.zooms = [ZoomSegment(range: TimeRange(start: 0, end: 2), centerX: 0.5, centerY: 0.5, scale: 2, transition: 0.3, bounce: 0)]
    try await Exporter().export(project: zoomed, sourceURL: source, to: out5) { _ in }
    func rgb(_ url: URL, _ t: Double, _ points: [(Int, Int)]) async throws -> [(Double, Double, Double)] {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let (img, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: img)
        if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-frame.png"))
        }
        return points.map { let c = rep.colorAt(x: $0.0, y: $0.1)!.usingColorSpace(.sRGB)!; return (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255) }
    }
    // Content is 1728×1080 at x 96 in all three exports. Each output spot should show the same
    // colour as the unedited export at the source spot it comes from.
    func matches(_ url: URL, at t: Double, _ pairs: [((Int, Int), (Double, Double))]) async throws -> (Bool, String) {
        let got = try await rgb(url, t, pairs.map(\.0))
        let r = FrameLayout.contentRect(project: Project(source: info.sourceVideo), mode: .normal)   // unedited has default padding
        let want = try await rgb(out, t, pairs.map { (Int((r.minX + $0.1.0 / 1440 * r.width) * 1920), Int((r.minY + $0.1.1 / 900 * r.height) * 1080)) })
        var ok = true, report = ""
        for (g, w) in zip(got, want) {
            let d = abs(g.0 - w.0) + abs(g.1 - w.1) + abs(g.2 - w.2)
            report += String(format: " %.0f", d)
            if d > 30 { ok = false }
        }
        return (ok, report)
    }
    let (cropOK, cropR) = try await matches(out4, at: 1, [((960, 540), (192, 120)), ((960, 900), (192, 200)), ((528, 540), (96, 120)), ((1392, 540), (288, 120))])
    check(cropOK, "crop export shows the cropped part (colour differences:\(cropR))")
    let (zoomOK, zoomR) = try await matches(out5, at: 1, [((960, 540), (192, 120)), ((960, 900), (192, 160)), ((528, 540), (144, 120)), ((1392, 540), (240, 120))])
    check(zoomOK, "zoom export shows 2× around the point (colour differences:\(zoomR))")
    // 9:16 framed + zoomed: magenta background, 8% padding, 2× zoom near the video's top-right
    // corner. The view stops at the picture's right edge, so the right padding and the background
    // above the band show; inside the band each spot shows the right part of the recording.
    var tall = Project(source: info.sourceVideo)
    tall.output.setShape(.vertical)
    tall.style.kind = .solid; tall.style.background = RGBAColor(r: 1, g: 0, b: 1, a: 1)
    tall.style.padding = 8; tall.style.cornerRadius = 0; tall.style.shadowOpacity = 0
    tall.timeline.zooms = [ZoomSegment(range: TimeRange(start: 0, end: 2), centerX: 0.95, centerY: 0.05, scale: 2, transition: 0.3, bounce: 0)]
    let out7 = tmp.appendingPathComponent("tall-zoom.mp4")
    try await Exporter().export(project: tall, sourceURL: source, to: out7) { _ in }
    let tallSize = try await AVURLAsset(url: out7).loadTracks(withMediaType: .video)[0].load(.naturalSize)
    check(tallSize == CGSize(width: 1080, height: 1920), "9:16 export is 1080×1920 (\(Int(tallSize.width))×\(Int(tallSize.height)))")
    let tu = FrameLayout.uniforms(project: tall, sourceSize: CGSize(width: 1440, height: 900), outputTime: 1)
    let tc = (x: Double(tu.contentRect.x), y: Double(tu.contentRect.y), w: Double(tu.contentRect.z), h: Double(tu.contentRect.w))
    check(abs(Double(tu.camera.x) - 0.5) < 1e-4 && abs(Double(tu.camera.z) - 0.5) < 1e-4,
          "9:16 zoom near the edge stops at the picture's right edge (camera x \(tu.camera.x))")
    func tallSource(_ px: Int, _ py: Int) -> (Double, Double) {
        ((Double(px) / 1080 - tc.x) / tc.w * 1440, (Double(py) / 1920 - tc.y) / tc.h * 900)
    }
    let inBand = [(540, 1300), (300, 1500), (800, 1200)]
    let tallGot = try await rgb(out7, 1, inBand + [(540, 400), (1050, 1300)])
    let r0 = FrameLayout.contentRect(project: Project(source: info.sourceVideo), mode: .normal)
    let tallWant = try await rgb(out, 1, inBand.map { let s = tallSource($0.0, $0.1)
        return (Int((r0.minX + s.0 / 1440 * r0.width) * 1920), Int((r0.minY + s.1 / 900 * r0.height) * 1080)) })
    var bandOK = true, bandR = ""
    for (g, w) in zip(tallGot, tallWant) {
        let d = abs(g.0 - w.0) + abs(g.1 - w.1) + abs(g.2 - w.2)
        bandR += String(format: " %.0f", d); if d > 30 { bandOK = false }
    }
    check(bandOK, "9:16 zoom shows the right part of the recording in the band (colour differences:\(bandR))")
    func magenta(_ c: (Double, Double, Double)) -> Bool { abs(c.0 - 255) + c.1 + abs(c.2 - 255) < 90 }
    check(magenta(tallGot[3]), "9:16 zoom near the top edge shows the background above the band \(tallGot[3])")
    check(magenta(tallGot[4]), "9:16 zoom near the right edge shows the padding \(tallGot[4])")
    // Example frames of a zoom with the default look, for eyeballing (only with VET_CHECK_FRAME_DIR).
    if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] {
        var look = Project(source: info.sourceVideo)
        look.timeline.zooms = [ZoomSegment(range: TimeRange(start: 0, end: 2), centerX: 0.9, centerY: 0.1, scale: 1.5, transition: 0.8, bounce: 0)]
        let out6 = tmp.appendingPathComponent("look.mp4")
        try await Exporter().export(project: look, sourceURL: source, to: out6) { _ in }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out6))
        g.maximumSize = CGSize(width: 640, height: 0)
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        for t in [0.0, 0.2, 0.4, 1.0] {
            let (img, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
            try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("zoom-look-\(t).png"))
        }
        // The same zoom in each shape, with the default look: before and fully in.
        for shape in VideoShape.allCases {
            var p = look
            p.output.setShape(shape)
            let url = tmp.appendingPathComponent("look-\(shape.rawValue).mp4")
            try await Exporter().export(project: p, sourceURL: source, to: url) { _ in }
            let sg = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            sg.maximumSize = CGSize(width: 640, height: 640)
            sg.requestedTimeToleranceBefore = .zero; sg.requestedTimeToleranceAfter = .zero
            for t in [0.0, 1.0] {
                let (img, _) = try await sg.image(at: CMTime(seconds: t, preferredTimescale: 600))
                try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("shape-\(shape.rawValue)-\(t).png"))
            }
        }
    }
    let (startOK, startR) = try await matches(out5, at: 0, [((960, 900), (192, 200)), ((528, 540), (96, 120))])
    check(startOK, "zoom export starts un-zoomed (colour differences:\(startR))")
}

print("Export options (M5)")
do {
    // Choices are stored in the project and survive save and reopen; older files get defaults.
    var proj = Project(source: SourceVideo(path: "/x.mov", width: 10, height: 10, duration: 1))
    proj.output.setMP4Height(2160); proj.output.fps = 30
    proj.output.format = .gif; proj.output.gifHeight = 480; proj.output.gifFPS = 10
    let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(proj))
    check(back.output == proj.output && back.output.width == 3840 && back.output.height == 2160, "export choices survive save and reopen")
    let oldFile = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"output":{"width":1920,"height":1080,"fps":60}}"#
    let o = try JSONDecoder().decode(Project.self, from: Data(oldFile.utf8)).output
    check(o.format == .mp4 && o.gifHeight == Settings.defaultGIFHeight && o.gifFPS == Settings.defaultGIFFPS, "files without export choices open with defaults")
    check(OutputSettings.size(forHeight: 720).width == 1280 && OutputSettings.size(forHeight: 480).width == 854, "16:9 widths are even numbers")

    let source = tmp.appendingPathComponent("m5-source.mov")
    try await TestVideo.make(at: source, width: 1440, height: 900, seconds: 2, fps: 30)
    let info = try await VideoInfo.load(source)

    func probe(_ url: URL) async throws -> (CGSize, Double, Double) {
        let asset = AVURLAsset(url: url)
        let t = try await asset.loadTracks(withMediaType: .video)[0]
        return (try await t.load(.naturalSize), try await asset.load(.duration).seconds, Double(try await t.load(.nominalFrameRate)))
    }
    for (height, fps) in [(720, 30), (2160, 30), (2160, 60)] {
        var p = Project(source: info.sourceVideo)
        p.output.setMP4Height(height); p.output.fps = fps
        let url = tmp.appendingPathComponent("m5-\(height)-\(fps).mp4")
        let started = Date()
        try await Exporter().export(project: p, sourceURL: source, to: url) { _ in }
        let (size, duration, rate) = try await probe(url)
        check(size.height == CGFloat(height) && size.width == CGFloat(OutputSettings.size(forHeight: height).width)
              && abs(duration - 2) < 0.1 && abs(rate - Double(fps)) < 1.5,
              "MP4 \(height)p \(fps) fps: \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", duration)) s, \(String(format: "%.1f", rate)) fps (took \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
    }

    // GIF: right size, frame count and length; the picture matches the MP4 export; the size guess is close.
    var g = Project(source: info.sourceVideo)
    g.output.format = .gif; g.output.gifHeight = 480; g.output.gifFPS = 10
    let gifURL = tmp.appendingPathComponent("m5.gif")
    let est = try await Exporter().estimateGIF(project: g, sourceURL: source)
    try await Exporter().export(project: g, sourceURL: source, to: gifURL) { _ in }
    let actual = (try FileManager.default.attributesOfItem(atPath: gifURL.path)[.size] as? Int) ?? 0
    guard let src = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else { fatalError("GIF unreadable") }
    let count = CGImageSourceGetCount(src)
    var total = 0.0
    for i in 0..<count {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        total += (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
    }
    let first = CGImageSourceCreateImageAtIndex(src, 0, nil)
    check(count == 20 && first?.width == 854 && first?.height == 480, "GIF 480p 10 fps: \(count) frames, \(first?.width ?? 0)×\(first?.height ?? 0)")
    check(abs(total - 2) < 0.05, "GIF plays for 2 seconds (\(total))")
    check(est.frames == 20 && est.bytes > actual / 2 && est.bytes < actual * 2, "GIF size guess \(est.bytes / 1024) KB is close to the real \(actual / 1024) KB")
    func centre(_ img: CGImage) -> (Double, Double, Double) {
        // Average a small block inside one tile (not on a sharp edge), so palette and dither noise cancel out.
        let rep = NSBitmapImageRep(cgImage: img)
        let x0 = Int(Double(img.width) * 0.19), y0 = Int(Double(img.height) * 0.23)
        var sum = (0.0, 0.0, 0.0)
        for y in y0..<y0 + 9 { for x in x0..<x0 + 9 {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            sum.0 += c.redComponent * 255 / 81; sum.1 += c.greenComponent * 255 / 81; sum.2 += c.blueComponent * 255 / 81
        } }
        return sum
    }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: tmp.appendingPathComponent("m5-720-30.mp4")))
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let mp4Frame = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    let gifFrame = CGImageSourceCreateImageAtIndex(src, 10, nil)!
    let (a, b) = (centre(mp4Frame), centre(gifFrame))
    check(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) < 45, "GIF frame looks like the MP4 frame (\(a) vs \(b))")
    if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] { try? FileManager.default.copyItem(at: gifURL, to: URL(fileURLWithPath: dir).appendingPathComponent("m5.gif")) }
}

print("Video shape")
do {
    let oldFile = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"output":{"width":1920,"height":1080,"fps":60}}"#
    let o = try JSONDecoder().decode(Project.self, from: Data(oldFile.utf8)).output
    check(o.shape == .wide && o.width == 1920 && o.height == 1080, "an older project opens as 16:9 1920×1080")
    let sizes = VideoShape.allCases.map { OutputSettings.size(level: 1080, shape: $0) }
    check(sizes.map(\.width) == [1920, 1080, 1080] && sizes.map(\.height) == [1080, 1080, 1920], "1080p is 1920×1080, 1080×1080 and 1080×1920")
    var out = OutputSettings()
    out.setMP4Height(2160); out.gifHeight = 480; out.setShape(.vertical)
    check(out.width == 2160 && out.height == 3840 && out.mp4Level == 2160 && out.gifSize == (480, 854),
          "changing the shape keeps the size choices (4K vertical 2160×3840, GIF 480×854)")
    var proj = Project(source: SourceVideo(path: "/x.mov", width: 10, height: 10, duration: 1))
    proj.output.setShape(.square)
    let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(proj))
    check(back.output.shape == .square && back.output.width == 1080 && back.output.height == 1080, "the shape survives save and reopen")

    // Layout: padding is a share of the shorter side, the recording keeps its shape.
    var lay = Project(source: SourceVideo(path: "", width: 1440, height: 900, duration: 1))
    lay.style.padding = 8
    lay.output.setShape(.vertical)
    let v = FrameLayout.contentRect(project: lay, mode: .normal)
    check(abs(v.minX - 0.08) < 1e-6 && abs(v.width * 1080 / (v.height * 1920) - 1.6) < 1e-4 && abs(v.midY - 0.5) < 1e-6,
          "9:16: a wide recording is a centred band with 8% padding at the sides")
    lay.output.setShape(.square)
    let sq = FrameLayout.contentRect(project: lay, mode: .normal)
    check(abs(sq.minX - 0.08) < 1e-6 && abs(sq.midY - 0.5) < 1e-6, "1:1: 8% padding at the sides, centred")
    lay.output.setShape(.wide)
    let wd = FrameLayout.contentRect(project: lay, mode: .normal)
    check(abs(wd.minY - 0.08) < 1e-6, "16:9: padding unchanged (8% above and below)")
    lay.crop = CropRect(x: 0, y: 0, width: 450, height: 900)   // a tall crop (1:2) in a vertical video
    lay.output.setShape(.vertical)
    let cr = FrameLayout.contentRect(project: lay, mode: .normal)
    check(abs(cr.width * 1080 / (cr.height * 1920) - 0.5) < 1e-4 && abs(cr.minY - 0.08 * 1080 / 1920) < 1e-6,
          "9:16 with a tall crop: the cropped part keeps its shape and fills the height")

    // Real exports of each shape: MP4 1080p and GIF 480p.
    let source = tmp.appendingPathComponent("shape-source.mov")
    try await TestVideo.make(at: source, width: 1440, height: 900, seconds: 1, fps: 30)
    let info = try await VideoInfo.load(source)
    for shape in VideoShape.allCases {
        var p = Project(source: info.sourceVideo)
        p.output.setShape(shape); p.output.setMP4Height(1080); p.output.fps = 30
        let url = tmp.appendingPathComponent("shape-\(shape.rawValue).mp4")
        try await Exporter().export(project: p, sourceURL: source, to: url) { _ in }
        let size = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0].load(.naturalSize)
        let want = OutputSettings.size(level: 1080, shape: shape)
        check(size == CGSize(width: want.width, height: want.height), "MP4 \(shape.ratioLabel) 1080p is \(Int(size.width))×\(Int(size.height))")
        p.output.format = .gif; p.output.gifHeight = 480; p.output.gifFPS = 10
        let gif = tmp.appendingPathComponent("shape-\(shape.rawValue).gif")
        let est = try await Exporter().estimateGIF(project: p, sourceURL: source)
        try await Exporter().export(project: p, sourceURL: source, to: gif) { _ in }
        let actual = (try FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
        let img = CGImageSourceCreateWithURL(gif as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let g = p.output.gifSize
        check(img?.width == g.width && img?.height == g.height && est.bytes > actual / 2 && est.bytes < actual * 2,
              "GIF \(shape.ratioLabel) 480p is \(img?.width ?? 0)×\(img?.height ?? 0), size guess \(est.bytes / 1024) KB vs \(actual / 1024) KB")
    }
}

print("Capture (P1)")
do {
    func near(_ a: CGPoint, _ x: Double, _ y: Double) -> Bool { abs(a.x - x) < 1e-6 && abs(a.y - y) < 1e-6 }
    // Retina main display, 1512×982 points at 2×.
    let retina = CaptureGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    check(retina.pixelSize == (3024, 1964), "Retina display records at 3024×1964 pixels")
    check(near(retina.pixel(fromGlobal: CGPoint(x: 756, y: 491)), 1512, 982), "Retina: middle of the screen → middle of the video")
    check(near(retina.pixel(fromGlobal: CGPoint(x: 1512, y: 982)), 3024, 1964), "Retina: far corner → far corner of the video")
    // A 1× display to the left of and above the main one (negative offsets).
    let left = CaptureGeometry(frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)
    check(near(left.pixel(fromGlobal: CGPoint(x: -960, y: 340)), 960, 540), "display left of and above the main one: offsets removed")
    check(left.pixel(fromGlobal: CGPoint(x: 10, y: 10)).x > 1920, "cursor on another display lands outside the video (kept, not clipped)")
    // An area drawn on a second Retina display placed right of the main one.
    let second = CGRect(x: 1512, y: 0, width: 1728, height: 1117)
    let areaLocal = CGRect(x: 100, y: 50, width: 400, height: 300)
    let areaGlobal = CaptureGeometry.globalRect(areaLocal, onDisplayAt: second)
    check(areaGlobal == CGRect(x: 1612, y: 50, width: 400, height: 300), "area on a second display → global position")
    let area = CaptureGeometry(frame: areaGlobal, scale: 2)
    check(area.pixelSize == (800, 600) && near(area.pixel(fromGlobal: CGPoint(x: 1812, y: 200)), 400, 300),
          "area capture: positions relative to the area, in Retina pixels")
    // Window capture: same maths with the window's frame.
    let win = CaptureGeometry(frame: CGRect(x: 200.5, y: 120, width: 801, height: 600.5), scale: 2)
    check(win.pixelSize.width % 2 == 0 && win.pixelSize.height % 2 == 0, "window sizes round to even pixels (\(win.pixelSize.width)×\(win.pixelSize.height))")
    check(near(win.pixel(fromGlobal: CGPoint(x: 200.5, y: 120)), 0, 0), "window: its top-left corner is pixel 0,0")
    // AppKit's bottom-left coordinates.
    check(near(CaptureGeometry.globalPoint(fromAppKit: CGPoint(x: 10, y: 900), mainDisplayHeight: 982), 10, 82),
          "AppKit (bottom-left) point → top-left screen point")
    check(CaptureGeometry.globalRect(fromAppKit: CGRect(x: 0, y: 882, width: 100, height: 100), mainDisplayHeight: 982)
          == CGRect(x: 0, y: 0, width: 100, height: 100), "AppKit rect → top-left screen rect")
    let clamped = CaptureGeometry.clampArea(CGRect(x: 1400, y: -20, width: 300, height: 200.3),
                                            to: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, minimumPoints: 64)
    check(clamped == CGRect(x: 1400, y: 0, width: 112, height: 180.5), "an area hanging off the display is trimmed to it (\(clamped))")
    let tiny = CaptureGeometry.clampArea(CGRect(x: 1500, y: 970, width: 5, height: 5),
                                         to: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, minimumPoints: 64)
    check(tiny.width == 64 && tiny.maxX <= 1512 && tiny.maxY <= 982, "a too-small area grows to the minimum and stays on the display")

    // Clock: pauses are cut out of both the video and the cursor log.
    var clock = CaptureClock()
    check(clock.videoTime(5) == nil, "no cursor times before the first frame")
    clock.begin(at: 100)
    check(clock.videoTime(101.5) == 1.5, "video time counts from the first frame")
    clock.pause(at: 102)
    check(clock.videoTime(103) == nil && clock.elapsed(104) == 2, "paused: nothing logged, timer stops")
    clock.resume(at: 105)
    check(clock.videoTime(106) == 3 && clock.elapsed(106) == 3, "after resuming, the pause is removed from the clock")

    // Cursor log.
    let info = CaptureInfo(kind: .area, width: 800, height: 600, scale: 2, frame: areaGlobal, name: "Area")
    var log = CursorLogBuilder(geometry: area, info: info)
    log.observe(videoTime: nil, global: CGPoint(x: 1700, y: 100), buttons: [], shape: .arrow)
    log.observe(videoTime: 0, global: CGPoint(x: 1612, y: 50), buttons: [], shape: .arrow)
    log.observe(videoTime: 0.01, global: CGPoint(x: 1612, y: 50), buttons: [], shape: .arrow)        // didn't move
    log.observe(videoTime: 0.02, global: CGPoint(x: 1662, y: 100), buttons: [.left], shape: .pointingHand)
    log.observe(videoTime: 0.03, global: CGPoint(x: 1662, y: 100), buttons: [.left], shape: .pointingHand)
    log.observe(videoTime: 0.05, global: CGPoint(x: 1662, y: 100), buttons: [], shape: .iBeam)
    log.observe(videoTime: 0.06, global: CGPoint(x: 1663, y: 100), buttons: [.right], shape: .iBeam)
    log.finish(at: 0.1)
    let t = log.track
    check(t.samples.count == 3 && t.samples[0] == CursorSample(time: 0, x: 0, y: 0) && t.samples[1] == CursorSample(time: 0.02, x: 100, y: 100),
          "samples only when the cursor moves, in video pixels (\(t.samples.count) samples)")
    check(t.clicks.map(\.phase) == [.down, .up, .down, .up] && t.clicks.map(\.button) == [.left, .left, .right, .right]
          && t.clicks[1].time == 0.05 && t.clicks[3].time == 0.1,
          "clicks: left down/up, right down, and a release added when recording stops")
    check(t.shapes.map(\.shape) == [.arrow, .pointingHand, .iBeam] && t.shapes[0].time == 0, "cursor shape changes, first one at 0 s")
    check(t.shape(at: 0.03) == .pointingHand && t.shape(at: 0.5) == .iBeam, "shape at a given moment")

    // Save and reopen with cursor data; older slots still open.
    let source = tmp.appendingPathComponent("rec.mov")
    try Data("x".utf8).write(to: source)
    var proj = Project(source: SourceVideo(path: source.path, width: 800, height: 600, duration: 0.1))
    proj.cursor = t
    let package = tmp.appendingPathComponent("Recording.\(Settings.projectExtension)")
    try ProjectStore.save(proj, sourceURL: source, to: package)
    let (reopened, _) = try ProjectStore.load(from: package)
    check(reopened.cursor == t && reopened.cursor.capture?.kind == .area && reopened.cursor.capture?.scale == 2,
          "cursor log survives save and reopen")
    let m1 = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"cursor":{"samples":[],"clicks":[]}}"#
    let old = try JSONDecoder().decode(Project.self, from: Data(m1.utf8))
    check(old.cursor.isEmpty && old.cursor.capture == nil && old.cursor.shapes.isEmpty, "projects from before P1 open with an empty cursor slot")
    let oddClick = #"{"samples":[{"time":0,"x":1,"y":2}],"clicks":[{"time":1,"x":1,"y":2}],"shapes":[{"time":0,"shape":"someNewCursor"}]}"#
    let odd = try JSONDecoder().decode(CursorTrack.self, from: Data(oddClick.utf8))
    check(odd.clicks.first?.button == .left && odd.clicks.first?.phase == .down && odd.shapes.first?.shape == .other,
          "clicks without a button read as left-down; unknown cursor names read as 'other'")
    check(Project(source: SourceVideo(path: "/x.mov", width: 1, height: 1, duration: 1)).cursor.isEmpty, "imported videos have an empty cursor slot")

    // The recording format: HEVC in short pieces, readable even if the app never finishes the file (a crash).
    let partial = tmp.appendingPathComponent("partial.mov")
    let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
    writer.movieFragmentInterval = CMTime(seconds: Settings.recordingFragmentSeconds, preferredTimescale: 600)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: ScreenRecorder.videoSettings(width: 640, height: 400))
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 400])
    writer.add(input)
    check(writer.startWriting(), "HEVC recording writer starts")
    writer.startSession(atSourceTime: .zero)
    for i in 0..<(30 * 7) {   // 7 s at 30 fps
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        if let pb {
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), Int32(i % 255), CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
    }
    try await Task.sleep(nanoseconds: 700_000_000)
    let copy = tmp.appendingPathComponent("crashed.mov")
    try FileManager.default.copyItem(at: partial, to: copy)   // the file as it is on disk mid-recording
    let crashed = try? await VideoInfo.load(copy)
    check((crashed?.duration ?? 0) >= 4, String(format: "unfinished recording still opens (%.1f of 7 s kept)", crashed?.duration ?? 0))
    input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 210, timescale: 30))
    await writer.finishWriting()
    let done = try? await VideoInfo.load(partial)
    check(writer.status == .completed && abs((done?.duration ?? 0) - 7) < 0.05 && done?.width == 640, "finished recording is 7 s, 640×400")
}

print("Cursor (P2)")
do {
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
    // Save and reopen; older files get the default look.
    var look = CursorLook()
    look.style = .white; look.size = 2.5; look.smoothing = 0.2; look.motionBlur = 0; look.clickEffect = .circle; look.hideWhenIdle = false; look.show = false
    var pj = Project(source: SourceVideo(path: "/x.mov", width: 100, height: 100, duration: 1))
    pj.cursorLook = look
    check(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(pj)).cursorLook == look, "cursor look survives save and reopen")
    let p1 = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"cursor":{"version":1,"samples":[{"time":0,"x":1,"y":2}]}}"#
    let oldP = try JSONDecoder().decode(Project.self, from: Data(p1.utf8))
    check(oldP.cursorLook == CursorLook() && oldP.cursor.samples.count == 1, "P1 project (no cursor look) opens with the default cursor")
    let weird = #"{"source":{"path":"/x.mov","width":10,"height":10,"duration":1},"cursorLook":{"style":"sparkly","size":3}}"#
    let wp = try JSONDecoder().decode(Project.self, from: Data(weird.utf8))
    check(wp.cursorLook.style == Settings.defaultCursorStyle && wp.cursorLook.size == 3, "unknown cursor style falls back, other settings kept")

    // Imported videos: nothing is drawn.
    let imported = Project(source: SourceVideo(path: "/x.mov", width: 1440, height: 900, duration: 4))
    check(FrameLayout.cursorFrame(project: imported, outputTime: 1) == nil && !FrameLayout.cursorUniforms(project: imported, outputTime: 1).isVisible,
          "imported video draws no cursor")

    // Smoothing: a jittery path is calmed, a straight steady move isn't delayed, a still cursor stays put.
    var jitter = CursorTrack()
    for i in 0..<480 { let t = Double(i) / 120; jitter.samples.append(CursorSample(time: t, x: 500 + t * 100 + (i % 2 == 0 ? 6 : -6), y: 300)) }
    let raw = CursorMotion(track: jitter, smoothing: 0), smooth = CursorMotion(track: jitter, smoothing: 0.5)
    func wobble(_ m: CursorMotion) -> Double {
        var w = 0.0; for i in 120..<360 { let t = Double(i) / 240; w = max(w, abs(m.position(at: t).x - (500 + t * 100))) }; return w
    }
    check(wobble(raw) > 5 && wobble(smooth) < 1, String(format: "smoothing calms jitter (%.1f px → %.2f px)", wobble(raw), wobble(smooth)))
    check(near(smooth.position(at: 2).x, 700, 1.5), String(format: "smoothing doesn't lag a steady move (%.1f, expected 700)", smooth.position(at: 2).x))
    var still = CursorTrack(); still.samples = [CursorSample(time: 0, x: 40, y: 50)]
    check(CursorMotion(track: still, smoothing: 1).position(at: 3) == CGPoint(x: 40, y: 50), "a still cursor stays exactly where it was")
    var hop = CursorTrack(); hop.samples = [CursorSample(time: 0, x: 0, y: 0), CursorSample(time: 1, x: 100, y: 0)]
    let hr = CursorMotion(track: hop, smoothing: 0)
    check(hr.position(at: 0.5).x == 0 && hr.position(at: 1.2).x == 100, "between far-apart samples the cursor waits, then moves")

    // Hide when idle, press, shapes.
    var idle = CursorTrack()
    idle.samples = [CursorSample(time: 0, x: 0, y: 0), CursorSample(time: 1, x: 10, y: 0), CursorSample(time: 6, x: 20, y: 0)]
    let im = CursorMotion(track: idle, smoothing: 0)
    check(im.idleOpacity(at: 1.5) == 1 && im.idleOpacity(at: 4) == 0 && im.idleOpacity(at: 6) == 1 && im.idleOpacity(at: 5.85) > 0 && im.idleOpacity(at: 5.85) < 1,
          "idle cursor fades out after 2 s still and back in as it moves")
    idle.clicks = [CursorClick(time: 2, x: 10, y: 0, phase: .down), CursorClick(time: 2.5, x: 10, y: 0, phase: .up)]
    let pm = CursorMotion(track: idle, smoothing: 0)
    check(pm.pressAmount(at: 1.9) == 0 && pm.pressAmount(at: 2.3) == 1 && pm.pressAmount(at: 3) == 0, "cursor presses while the button is held")
    check(pm.idleOpacity(at: 4) == 1 && pm.idleOpacity(at: 5) == 0, "a click counts as activity for hiding")
    check(CursorArt.cell(for: .other) == .arrow && CursorArt.cell(for: .iBeam) == .iBeam && CursorArt.cell(for: .resizeLeft) == .resizeLeftRight,
          "unknown cursors draw as the arrow, others as their own picture")
    var shaped = CursorTrack(); shaped.shapes = [CursorShapeChange(time: 0, shape: .arrow), CursorShapeChange(time: 1, shape: .pointingHand)]
    check(shaped.shape(at: 0.5) == .arrow && shaped.shape(at: 1.5) == .pointingHand, "the shape follows the log")

    // Timing through cuts and speed: x = 100 px per source second, clips 2–4 s at 2× and 6–8 s.
    var timed = Project(source: SourceVideo(path: "/x.mov", width: 1440, height: 900, duration: 8))
    for i in 0...960 { let t = Double(i) / 120; timed.cursor.samples.append(CursorSample(time: t, x: t * 100, y: 400)) }
    timed.cursor.clicks = [CursorClick(time: 3, x: 300, y: 400), CursorClick(time: 3.1, x: 310, y: 400, phase: .up),
                           CursorClick(time: 5, x: 500, y: 400)]
    timed.timeline.clips = [Clip(start: 2, end: 4, rate: 2), Clip(start: 6, end: 8)]
    timed.cursorLook.hideWhenIdle = false
    let tmap = TimeMap(project: timed, sourceDuration: 8)
    let f1 = FrameLayout.cursorFrame(project: timed, outputTime: 0.5, timeMap: tmap)!
    check(near(f1.position.x, 300, 1), String(format: "cursor follows a 2× clip (at 0.5 s shows source 3 s: x %.1f)", f1.position.x))
    let f2 = FrameLayout.cursorFrame(project: timed, outputTime: 1.5, timeMap: tmap)!
    check(near(f2.position.x, 650, 1), String(format: "cursor jumps over a deleted part (at 1.5 s: x %.1f, expected 650)", f2.position.x))
    check(f1.clicks.count == 1 && near(f1.clicks[0].progress, 0, 1e-6), "click effect starts at the click's moment in the finished video")
    let f3 = FrameLayout.cursorFrame(project: timed, outputTime: 0.5 + Settings.clickEffectSeconds * 0.5, timeMap: tmap)!
    check(f3.clicks.count == 1 && near(f3.clicks[0].progress, 0.5, 1e-6), "click effect lasts the same in a sped-up clip")
    check((0..<40).allSatisfy { FrameLayout.cursorFrame(project: timed, outputTime: 1.05 + Double($0) * 0.02, timeMap: tmap)!.clicks.isEmpty },
          "a click in a deleted part shows no effect")
    timed.cursorLook.motionBlur = 1
    let fb = FrameLayout.cursorFrame(project: timed, outputTime: 1.01, timeMap: tmap)!
    check(near(fb.blurFrom.x, 600, 1) && near(fb.position.x, 601, 1), String(format: "motion blur never streaks across a cut (from %.0f to %.0f)", fb.blurFrom.x, fb.position.x))
    let fm = FrameLayout.cursorFrame(project: timed, outputTime: 1.5, timeMap: tmap)!
    check(near(fm.position.x - fm.blurFrom.x, Settings.cursorMaxBlurSeconds * 100, 0.5), "motion blur covers the last moment of movement")

    // A real export with the cursor drawn, through crop and zoom.
    let source = tmp.appendingPathComponent("cursor-source.mov")
    try await TestVideo.make(at: source, width: 1440, height: 900, seconds: 2, fps: 30)
    let info = try await VideoInfo.load(source)
    var cp = Project(source: info.sourceVideo)
    cp.style.padding = 0; cp.style.cornerRadius = 0; cp.style.shadowOpacity = 0
    cp.cursor.capture = CaptureInfo(kind: .display, width: 1440, height: 900, scale: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), name: "Test")
    cp.cursor.samples = [CursorSample(time: 0, x: 720, y: 450)]
    cp.cursorLook.size = 2; cp.cursorLook.hideWhenIdle = false; cp.cursorLook.motionBlur = 0
    func frameAt(_ p: Project, _ name: String, _ t: Double = 1) async throws -> NSBitmapImageRep {
        let url = tmp.appendingPathComponent(name + ".mp4")
        try await Exporter().export(project: p, sourceURL: source, to: url) { _ in }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let (img, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
        if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] {
            try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("cursor-\(name).png"))
        }
        return NSBitmapImageRep(cgImage: img)
    }
    func lum(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        let c = r.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255
    }
    // Inside the arrow: 2.5 points right of and 9 below its tip. Canvas scale 1080/900 = 1.2, cursor size 2.
    let k = 1.2 * 2
    let plainR = try await frameAt(cp, "plain")
    let (bx, by) = (Int(960 + 2.5 * k), Int(540 + 9 * k))
    check(lum(plainR, bx, by) < 40, String(format: "export draws the black cursor at its spot (brightness %.0f)", lum(plainR, bx, by)))
    check(lum(plainR, Int(960 - 3 * k), by) > 150 || lum(plainR, Int(960 - 3 * k), by) > lum(plainR, bx, by) + 80,
          "the cursor has a light edge beside it")
    var white = cp; white.cursorLook.style = .white
    let whiteR = try await frameAt(white, "white")
    check(lum(whiteR, bx, by) > 215, String(format: "white style draws a white cursor (brightness %.0f)", lum(whiteR, bx, by)))
    var off = cp; off.cursorLook.show = false
    let offR = try await frameAt(off, "off")
    check(abs(lum(offR, bx, by) - lum(plainR, bx, by)) > 40, "switching the cursor off removes it")
    // Crop to the middle quarter: 720×450 shown 1728×1080 (2.4×) from x = 96; the source centre lands on the canvas centre.
    var cropped = cp; cropped.crop = CropRect(x: 360, y: 225, width: 720, height: 450)
    let k2 = 2.4 * 2
    let cropR = try await frameAt(cropped, "crop")
    check(lum(cropR, Int(960 + 2.5 * k2), Int(540 + 9 * k2)) < 40 && lum(cropR, Int(960 + 2.5 * k2), Int(540 + 16 * k2)) > 60,
          "cursor follows the crop (and grows with it)")
    // Plus a 2× zoom on the middle, fully in at 1 s: the cursor doubles again around the centre.
    var zoomed = cropped
    zoomed.timeline.zooms = [ZoomSegment(range: TimeRange(start: 0, end: 2), centerX: 0.5, centerY: 0.5, scale: 2, transition: 0.2, bounce: 0)]
    let zoomR = try await frameAt(zoomed, "zoom")
    let k3 = k2 * 2
    check(lum(zoomR, Int(960 + 2.5 * k3), Int(540 + 9 * k3)) < 40 && lum(zoomR, Int(960 + 2.5 * k3), Int(540 + 30 * k3)) > 60,
          "cursor follows the zoom")
    // Pixel art drawn by the app: the arrow cell has dark pixels inside a light edge, and a soft shadow.
    let art = CursorArt.atlas(cellPixels: 128)
    func px(_ cell: CursorArt.Cell, _ ux: Double, _ uy: Double, _ ch: Int) -> UInt8 {
        let r = CursorArt.rect(of: cell)
        let x = Int((r.minX + ux / 32 * r.width) * Double(art.width)), y = Int((r.minY + uy / 32 * r.height) * Double(art.height))
        return art.bytes[(y * art.width + x) * 4 + ch]
    }
    check(px(.arrow, 11, 14, 0) > 200 && px(.arrow, 11, 14, 1) > 200 && px(.arrow, 8.4, 14, 0) < 60 && px(.arrow, 8.4, 14, 1) > 150,
          "arrow art: dark inside, light edge")
    check(px(.pointingHand, 17, 22, 1) > 200 && px(.pointingHand, 17, 22, 0) < 60, "hand art: light inside")
    if let dir = ProcessInfo.processInfo.environment["VET_CHECK_FRAME_DIR"] {
        let full = CursorArt.atlas(cellPixels: 256)
        let provider = CGDataProvider(data: Data(full.bytes) as CFData)!
        // Shown as: dark parts black, light parts white, shadow grey, on a mid-grey background.
        var rgba = [UInt8](repeating: 0, count: full.width * full.height * 4)
        for i in 0..<(full.width * full.height) {
            let d = Double(full.bytes[i * 4]) / 255, b = Double(full.bytes[i * 4 + 1]) / 255, sh = Double(full.bytes[i * 4 + 2]) / 255 * 0.35
            var c = 0.6 * (1 - sh)
            c = c * (1 - b) + (b - d)
            let v = UInt8(max(0, min(255, c * 255)))
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v; rgba[i * 4 + 3] = 255
        }
        _ = provider
        let img = CGImage(width: full.width, height: full.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: full.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("cursor-art.png"))
        // Click effects and the dot, for eyeballing.
        var fx = cp; fx.cursor.clicks = [CursorClick(time: 0.85, x: 720, y: 450)]
        fx.cursorLook.clickEffect = .ripple; _ = try await frameAt(fx, "ripple")
        fx.cursorLook.clickEffect = .circle; _ = try await frameAt(fx, "circle")
        fx.cursorLook.style = .dot; _ = try await frameAt(fx, "dot")
    }
}

// Speed test, only when asked: VET_PERF=1 swift run -c release CoreChecks (makes a 4K, 30 s test recording).
if ProcessInfo.processInfo.environment["VET_PERF"] != nil {
    print("Speed")
    let source = tmp.appendingPathComponent("perf-4k.mov")
    var t0 = Date()
    try await TestVideo.make(at: source, width: 3840, height: 2160, seconds: 30, fps: 30)
    print(String(format: "  (made the test recording in %.1f s)", Date().timeIntervalSince(t0)))
    let info = try await VideoInfo.load(source)
    for (label, format, height, fps) in [("MP4 1080p60", OutputSettings.Format.mp4, 1080, 60), ("MP4 4K30", .mp4, 2160, 30), ("MP4 4K60", .mp4, 2160, 60), ("GIF 720p15", .gif, 720, 15)] {
        var p = Project(source: info.sourceVideo)
        p.output.format = format; p.output.setMP4Height(height); p.output.fps = fps; p.output.gifHeight = height; p.output.gifFPS = fps
        t0 = Date()
        try await Exporter().export(project: p, sourceURL: source, to: tmp.appendingPathComponent("perf.out")) { _ in }
        let secs = Date().timeIntervalSince(t0)
        print(String(format: "  %@: 30 s of 4K video exported in %.1f s (%.1f× real time)", label, secs, 30 / secs))
    }
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
