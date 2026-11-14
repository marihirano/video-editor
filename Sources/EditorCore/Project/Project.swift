import Foundation

/// Everything the user has done to one recording. Saved as `project.json`.
///
/// M1 only uses `source` and `output`. The other parts are here, empty, so later
/// milestones add features without changing the file format.
public struct Project: Codable, Equatable, Sendable {
    public var version: Int = Settings.projectFormatVersion
    public var source: SourceVideo
    public var output: OutputSettings = .init()
    public var timeline: Timeline = .init()
    /// Part of the source to keep, in source pixels. `nil` means the whole frame (M4).
    public var crop: CropRect? = nil
    public var style: FrameStyle = .init()
    /// Cursor positions and clicks from in-app recording (phase 2). Empty for imported videos.
    public var cursor: CursorTrack = .init()
    /// How the cursor is drawn (P2). Only used when `cursor` has data.
    public var cursorLook: CursorLook = .init()

    public init(source: SourceVideo) { self.source = source }

    enum CodingKeys: String, CodingKey { case version, source, output, timeline, crop, style, cursor, cursorLook }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Settings.projectFormatVersion
        source = try c.decode(SourceVideo.self, forKey: .source)
        output = try c.decodeIfPresent(OutputSettings.self, forKey: .output) ?? .init()
        timeline = try c.decodeIfPresent(Timeline.self, forKey: .timeline) ?? .init()
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        style = try c.decodeIfPresent(FrameStyle.self, forKey: .style) ?? .init()
        cursor = try c.decodeIfPresent(CursorTrack.self, forKey: .cursor) ?? .init()
        cursorLook = try c.decodeIfPresent(CursorLook.self, forKey: .cursorLook) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(source, forKey: .source)
        try c.encode(output, forKey: .output)
        try c.encode(timeline, forKey: .timeline)
        try c.encode(crop, forKey: .crop)   // written as null when empty
        try c.encode(style, forKey: .style)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(cursorLook, forKey: .cursorLook)
    }
}

/// Where the original video lives. The video is never copied into the project.
public struct SourceVideo: Codable, Equatable, Sendable {
    /// Absolute path when the project was saved.
    public var path: String
    /// Path relative to the project package, so moving both together keeps working.
    public var relativePath: String?
    /// macOS bookmark (base64), which follows the file if it's renamed or moved.
    public var bookmark: String?
    /// Source size in pixels and duration in seconds, for display before loading.
    public var width: Int
    public var height: Int
    public var duration: Double

    public init(path: String, relativePath: String? = nil, bookmark: String? = nil,
                width: Int, height: Int, duration: Double) {
        self.path = path; self.relativePath = relativePath; self.bookmark = bookmark
        self.width = width; self.height = height; self.duration = duration
    }
}

/// The shape of the finished video: widescreen, square or vertical.
public enum VideoShape: String, Codable, CaseIterable, Sendable {
    case wide, square, vertical
    /// Width divided by height (16:9, 1:1, 9:16).
    public var aspect: Double {
        let r = Settings.wideAspect
        switch self {
        case .wide: return r
        case .square: return 1
        case .vertical: return 1 / r
        }
    }
    /// "16:9", "1:1", "9:16".
    public var ratioLabel: String {
        switch self {
        case .wide: return "16:9"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }
}

/// Shape, size and frame rate of the exported video. The canvas size is a setting from day one,
/// so the renderer draws any shape.
public struct OutputSettings: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case mp4, gif }
    /// Widescreen, square or vertical. Older projects (no shape saved) are widescreen.
    public var shape: VideoShape = Settings.defaultVideoShape
    /// MP4 size and frame rate. Width and height always follow `shape`; the size choices
    /// (720p, 1080p, 4K) are the shorter side (see `OutputSettings.size(level:shape:)`).
    public var width: Int = Settings.defaultOutputWidth
    public var height: Int = Settings.defaultOutputHeight
    public var fps: Int = Settings.defaultOutputFPS
    /// What the Export button makes, and the GIF's own size (its shorter side) and frame rate.
    public var format: Format = .mp4
    public var gifHeight: Int = Settings.defaultGIFHeight
    public var gifFPS: Int = Settings.defaultGIFFPS
    public init() {}

    enum CodingKeys: String, CodingKey { case shape, width, height, fps, format, gifHeight, gifFPS }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(VideoShape.self, forKey: .shape) ?? .wide
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? format
        gifHeight = try c.decodeIfPresent(Int.self, forKey: .gifHeight) ?? gifHeight
        gifFPS = try c.decodeIfPresent(Int.self, forKey: .gifFPS) ?? gifFPS
        setMP4Height(mp4Level)   // keeps width and height in step with the shape
    }

    /// A canvas of the given shape whose shorter side is `level` (the longer side rounded to an even number).
    public static func size(level: Int, shape: VideoShape) -> (width: Int, height: Int) {
        let long = Int((Double(level) * Settings.wideAspect / 2).rounded()) * 2
        switch shape {
        case .wide: return (long, level)
        case .square: return (level, level)
        case .vertical: return (level, long)
        }
    }

    /// A 16:9 canvas of the given height (width rounded to an even number).
    public static func size(forHeight h: Int) -> (width: Int, height: Int) { size(level: h, shape: .wide) }

    /// The MP4 size choice: the shorter side (720, 1080 or 2160).
    public var mp4Level: Int { min(width, height) }
    /// Sets the MP4 size from its shorter side (720, 1080 or 2160), in the current shape.
    public mutating func setMP4Height(_ level: Int) { let s = Self.size(level: level, shape: shape); width = s.width; height = s.height }
    /// Changes the shape; MP4 and GIF keep their size choices.
    public mutating func setShape(_ new: VideoShape) { let level = mp4Level; shape = new; setMP4Height(level) }
    public var gifSize: (width: Int, height: Int) { Self.size(level: gifHeight, shape: shape) }
}

/// Edits over time.
public struct Timeline: Codable, Equatable, Sendable {
    /// The pieces of the recording that make up the video, in order, each with its own speed.
    /// Empty = the whole recording at normal speed. Splitting makes two clips; deleting one
    /// removes that part from the video.
    public var clips: [Clip] = []
    public var zooms: [ZoomSegment] = []
    /// Room for sound later. v1 is silent.
    public var audioTracks: [AudioTrack] = []

    /// Only read from files saved by the first M3 build, which stored a trim, cuts and
    /// speed parts instead of clips. Turned into clips on the first edit; never written.
    public var legacyTrim: TimeRange? = nil
    public var legacyCuts: [TimeRange] = []
    public var legacySpeedSegments: [SpeedSegment] = []

    public init(clips: [Clip] = [], zooms: [ZoomSegment] = []) { self.clips = clips; self.zooms = zooms }

    enum CodingKeys: String, CodingKey { case clips, zooms, audioTracks, trim, cuts, speedSegments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        zooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? []
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
        legacyTrim = try c.decodeIfPresent(TimeRange.self, forKey: .trim)
        legacyCuts = try c.decodeIfPresent([TimeRange].self, forKey: .cuts) ?? []
        legacySpeedSegments = try c.decodeIfPresent([SpeedSegment].self, forKey: .speedSegments) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clips, forKey: .clips)
        try c.encode(zooms, forKey: .zooms)
        try c.encode(audioTracks, forKey: .audioTracks)
    }
}

/// One piece of the recording in the video: from `start` to `end` (source seconds) at `rate`.
public struct Clip: Codable, Equatable, Sendable {
    public var start: Double, end: Double
    public var rate: Double
    public init(start: Double, end: Double, rate: Double = 1) { self.start = start; self.end = end; self.rate = rate }
    public var sourceDuration: Double { end - start }
    public var outputDuration: Double { (end - start) / rate }
}

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double, end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct SpeedSegment: Codable, Equatable, Sendable {
    public var range: TimeRange
    public var rate: Double
    public init(range: TimeRange, rate: Double) { self.range = range; self.rate = rate }
}

/// One zoom on the zoom track. `range` is in **source** seconds (moments of the recording), so a
/// zoom stays on the same content when clips before it are deleted or sped up. Its animation
/// (`transition`) is in seconds of the finished video, so it feels the same at any clip speed.
public struct ZoomSegment: Codable, Equatable, Sendable {
    public var range: TimeRange
    /// Point to zoom towards, 0–1 across the (cropped) frame, from the top-left.
    public var centerX: Double, centerY: Double
    /// How far it zooms: 1.5 = 150%.
    public var scale: Double
    /// Length of the zoom-in and of the zoom-out, in seconds of the finished video.
    public var transition: Double
    /// 0 = settles smoothly, 1 = the most overshoot ("bounce") allowed.
    public var bounce: Double

    public init(range: TimeRange, centerX: Double = 0.5, centerY: Double = 0.5,
                scale: Double = Settings.defaultZoomScale,
                transition: Double = Settings.zoomEasingPresets[Settings.defaultZoomEasing].transition,
                bounce: Double = Settings.zoomEasingPresets[Settings.defaultZoomEasing].bounce) {
        self.range = range; self.centerX = centerX; self.centerY = centerY
        self.scale = scale; self.transition = transition; self.bounce = bounce
    }

    enum CodingKeys: String, CodingKey { case range, centerX, centerY, scale, transition, bounce }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ZoomSegment(range: try c.decode(TimeRange.self, forKey: .range))
        range = d.range
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? d.centerX
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? d.centerY
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        transition = try c.decodeIfPresent(Double.self, forKey: .transition) ?? d.transition
        bounce = try c.decodeIfPresent(Double.self, forKey: .bounce) ?? d.bounce
    }
}

public struct AudioTrack: Codable, Equatable, Sendable {
    public var name: String
}

/// Part of the recording to keep, in source pixels from the top-left.
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case wallpaper, gradient, solid, image
}

/// The frame around the video: background, padding, rounded corners and drop shadow.
/// Every field has a default, so older project files (which only had `background`) still open.
public struct FrameStyle: Codable, Equatable, Sendable {
    public var kind: BackgroundKind = Settings.defaultBackgroundKind
    /// The plain colour (also the key M1 projects used).
    public var background: RGBAColor = Settings.defaultBackground
    public var gradientStart: RGBAColor = Settings.gradients[Settings.defaultGradient].start
    public var gradientEnd: RGBAColor = Settings.gradients[Settings.defaultGradient].end
    public var gradientAngle: Double = Settings.defaultGradientAngle
    public var wallpaper: Int = Settings.defaultWallpaper
    /// The user's own background picture (absolute path to the file).
    public var imagePath: String? = nil
    public var padding: Double = Settings.defaultPadding
    public var cornerRadius: Double = Settings.defaultCornerRadius
    public var shadowOpacity: Double = Settings.defaultShadowOpacity
    public var shadowBlur: Double = Settings.defaultShadowBlur
    public var shadowOffset: Double = Settings.defaultShadowOffset
    public init() {}

    enum CodingKeys: String, CodingKey {
        case kind, background, gradientStart, gradientEnd, gradientAngle, wallpaper, imagePath
        case padding, cornerRadius, shadowOpacity, shadowBlur, shadowOffset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameStyle()
        kind = try c.decodeIfPresent(BackgroundKind.self, forKey: .kind) ?? d.kind
        background = try c.decodeIfPresent(RGBAColor.self, forKey: .background) ?? d.background
        gradientStart = try c.decodeIfPresent(RGBAColor.self, forKey: .gradientStart) ?? d.gradientStart
        gradientEnd = try c.decodeIfPresent(RGBAColor.self, forKey: .gradientEnd) ?? d.gradientEnd
        gradientAngle = try c.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? d.gradientAngle
        wallpaper = try c.decodeIfPresent(Int.self, forKey: .wallpaper) ?? d.wallpaper
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? d.shadowOpacity
        shadowBlur = try c.decodeIfPresent(Double.self, forKey: .shadowBlur) ?? d.shadowBlur
        shadowOffset = try c.decodeIfPresent(Double.self, forKey: .shadowOffset) ?? d.shadowOffset
    }
}
