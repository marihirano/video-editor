import CoreGraphics
import simd

/// Numbers the shader needs to draw the cursor and click effects in one frame.
/// Layout must match `CursorUniforms` in Shaders.swift. Positions and sizes are in recording pixels,
/// so the cursor goes through the same crop and zoom as the video.
public struct CursorUniforms: Equatable {
    public var position: SIMD4<Float> = .zero    // xy now, zw where the motion blur starts
    public var params: SIMD4<Float> = .zero      // opacity (0 = not drawn), cell side, style, blur samples
    public var cell: SIMD4<Float> = .zero
    public var hotspot: SIMD4<Float> = .zero     // xy hotspot (fraction of cell), z click effect, w click radius
    public var recording: SIMD4<Float> = .zero   // xy recording size, z shadow strength, w dot radius
    public var dark: SIMD4<Float> = .zero
    public var light: SIMD4<Float> = .zero
    public var dotFill: SIMD4<Float> = .zero
    public var clickColor: SIMD4<Float> = .zero
    public var click0 = SIMD4<Float>(0, 0, -1, 0)
    public var click1 = SIMD4<Float>(0, 0, -1, 0)
    public var click2 = SIMD4<Float>(0, 0, -1, 0)
    public var click3 = SIMD4<Float>(0, 0, -1, 0)

    /// Nothing to draw (imported videos, cursor switched off).
    public static let hidden = CursorUniforms()
    public init() {}

    /// True when this frame draws a cursor.
    public var isVisible: Bool { params.x > 0.001 }
}

/// What the cursor looks like at one moment, worked out on the CPU (also used by the checks).
public struct CursorFrame: Equatable, Sendable {
    /// Source time shown at this output moment.
    public var sourceTime: Double
    /// Where the cursor is, and where its motion blur starts (recording pixels).
    public var position: CGPoint
    public var blurFrom: CGPoint
    public var opacity: Double
    /// Side of the cursor picture's 32-point cell, in recording pixels (already shrunk while pressed).
    public var cellSide: Double
    public var cell: CursorArt.Cell
    /// Click effects showing: where (recording pixels) and how far along (0–1).
    public var clicks: [(point: CGPoint, progress: Double)]

    public static func == (a: CursorFrame, b: CursorFrame) -> Bool {
        a.sourceTime == b.sourceTime && a.position == b.position && a.blurFrom == b.blurFrom && a.opacity == b.opacity
            && a.cellSide == b.cellSide && a.cell == b.cell && a.clicks.count == b.clicks.count
    }
}

extension FrameLayout {

    /// The cursor at an output moment, or nil when there's nothing to draw (no cursor log, or switched off).
    public static func cursorFrame(project: Project, outputTime t: Double, timeMap: TimeMap? = nil) -> CursorFrame? {
        let track = project.cursor, look = project.cursorLook
        guard look.show, !track.samples.isEmpty else { return nil }
        let map = timeMap ?? TimeMap(project: project, sourceDuration: project.source.duration)
        let s = map.sourceTime(forOutput: t)
        let motion = CursorMotion.cached(track: track, smoothing: look.smoothing)
        let position = motion.position(at: s)
        // Motion blur: where the cursor was a moment earlier in the finished video (never across a cut).
        let piece = map.pieces[map.pieceIndex(atOutput: max(0, t))]
        let t0 = max(piece.outputStart, t - look.motionBlur * Settings.cursorMaxBlurSeconds)
        let blurFrom = look.motionBlur > 0 ? motion.position(at: map.sourceTime(forOutput: t0)) : position
        let scale = track.capture?.scale ?? 1
        let press = motion.pressAmount(at: s)
        let side = CursorArt.cellPoints * scale * look.size * (1 - (1 - Settings.cursorPressScale) * press)
        var clicks: [(CGPoint, Double)] = []
        if look.clickEffect != .none {
            for c in track.clicks where c.phase == .down && c.button != .other {
                // Only clicks in a part of the recording that's still in the video.
                guard map.pieces.contains(where: { c.time >= $0.source.start && c.time <= $0.source.end }) else { continue }
                let age = t - map.outputTime(forSource: c.time)
                if age >= 0, age < Settings.clickEffectSeconds {
                    clicks.append((motion.position(at: c.time), age / Settings.clickEffectSeconds))
                }
            }
        }
        return CursorFrame(sourceTime: s, position: position, blurFrom: blurFrom,
                           opacity: look.hideWhenIdle ? motion.idleOpacity(at: s) : 1,
                           cellSide: side, cell: CursorArt.cell(for: track.shape(at: s)),
                           clicks: Array(clicks.suffix(4)))
    }

    /// Shader numbers for the cursor at an output moment (`.hidden` when there's nothing to draw).
    public static func cursorUniforms(project: Project, outputTime: Double, timeMap: TimeMap? = nil) -> CursorUniforms {
        guard let f = cursorFrame(project: project, outputTime: outputTime, timeMap: timeMap), f.opacity > 0.001 else { return .hidden }
        let look = project.cursorLook, track = project.cursor
        let scale = track.capture?.scale ?? 1
        let recW = Double(track.capture?.width ?? project.source.width), recH = Double(track.capture?.height ?? project.source.height)
        func v(_ c: RGBAColor) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
        var u = CursorUniforms()
        u.position = SIMD4(Float(f.position.x), Float(f.position.y), Float(f.blurFrom.x), Float(f.blurFrom.y))
        // Enough copies that the blurred cursor looks like a streak, not separate cursors.
        let dist = hypot(f.position.x - f.blurFrom.x, f.position.y - f.blurFrom.y)
        let samples = min(Settings.cursorMaxBlurSamples, Int(dist / max(f.cellSide * 0.03, 0.5)) + 1)
        let style: Float = look.style == .black ? 0 : look.style == .white ? 1 : 2
        u.params = SIMD4(Float(f.opacity), Float(f.cellSide), style, Float(samples))
        let r = CursorArt.rect(of: f.cell)
        u.cell = SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        let effect: Float = look.clickEffect == .none ? 0 : look.clickEffect == .circle ? 1 : 2
        u.hotspot = SIMD4(Float(f.cell.hotspot.x / CursorArt.cellPoints), Float(f.cell.hotspot.y / CursorArt.cellPoints),
                          effect, Float(Settings.clickEffectRadiusPoints * scale * look.size))
        let pressShrink = f.cellSide / (CursorArt.cellPoints * scale * look.size)
        u.recording = SIMD4(Float(recW), Float(recH), Float(Settings.cursorShadowOpacity),
                            Float(Settings.cursorDotRadiusPoints * scale * look.size * pressShrink))
        u.dark = v(Settings.cursorDark); u.light = v(Settings.cursorLight); u.dotFill = v(Settings.cursorDotFill)
        let cc = Settings.clickEffectColor
        u.clickColor = SIMD4(Float(cc.r), Float(cc.g), Float(cc.b), Float(Settings.clickEffectOpacity))
        let cs = f.clicks.map { SIMD4(Float($0.point.x), Float($0.point.y), Float($0.progress), Float(Settings.clickEffectEdgeOpacity)) }
        if cs.count > 0 { u.click0 = cs[0] }
        if cs.count > 1 { u.click1 = cs[1] }
        if cs.count > 2 { u.click2 = cs[2] }
        if cs.count > 3 { u.click3 = cs[3] }
        return u
    }
}
