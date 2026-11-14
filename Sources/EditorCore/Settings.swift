import CoreGraphics
import Foundation

/// Every tunable value in the app lives here, so tuning never means hunting through code.
public enum Settings {

    // MARK: Project files
    /// Extension of the project package (a folder that Finder shows as one file).
    public static let projectExtension = "vetproj"
    /// Uniform type id declared in the app's Info.plist for project packages.
    public static let projectTypeIdentifier = "com.marihirano.video-editor.project"
    /// Name of the edits file inside the project package.
    public static let projectFileName = "project.json"
    /// Version written into project.json, bumped when the format changes.
    public static let projectFormatVersion = 1

    // MARK: Output canvas (the size of the exported video)
    public static let defaultOutputWidth = 1920
    public static let defaultOutputHeight = 1080
    public static let defaultOutputFPS = 60
    /// Shape of a new project's video, and the widescreen ratio (16:9) the other shapes are built from:
    /// square is 1:1, vertical is 9:16. Sizes (720p, 1080p, 4K) are the shorter side in every shape.
    public static let defaultVideoShape = VideoShape.wide
    public static let wideAspect = 16.0 / 9.0

    // MARK: Look
    /// Plain colour used when the background is "Color" (RGBA, 0–1).
    public static let defaultBackground = RGBAColor(r: 0.09, g: 0.09, b: 0.11, a: 1)
    /// Which background a new project starts with, and which built-in one.
    public static let defaultBackgroundKind = BackgroundKind.gradient
    public static let defaultWallpaper = 0
    public static let defaultGradient = 1   // Ocean (the blue one)

    /// Space around the video, as a percentage of the canvas's shorter side (its height in 16:9,
    /// its width in 9:16; same on all sides).
    public static let defaultPadding = 8.0
    public static let paddingRange = 0.0...25.0
    /// Rounded-corner size, in pixels on a canvas whose shorter side is 1080 (scales with the output size).
    public static let defaultCornerRadius = 14.0
    public static let cornerRadiusRange = 0.0...60.0
    /// Drop shadow. Blur and distance are in pixels on a 1080-tall canvas.
    public static let defaultShadowOpacity = 0.45
    public static let shadowOpacityRange = 0.0...1.0
    public static let defaultShadowBlur = 40.0
    public static let shadowBlurRange = 0.0...120.0
    public static let defaultShadowOffset = 16.0
    public static let shadowOffsetRange = 0.0...60.0
    /// Direction used when a gradient is picked from a swatch (degrees, 180 = top to bottom).
    public static let defaultGradientAngle = 135.0

    /// Built-in gradients (original colour pairs).
    public static let gradients: [GradientPreset] = [
        .init(name: "Sunrise", start: RGBAColor(hex: 0xF6D365), end: RGBAColor(hex: 0xFD8A6B), angle: 135),
        .init(name: "Ocean", start: RGBAColor(hex: 0x1E5AA8), end: RGBAColor(hex: 0x5FD3E8), angle: 135),
        .init(name: "Violet", start: RGBAColor(hex: 0x5B5BE0), end: RGBAColor(hex: 0x9B4FC7), angle: 135),
        .init(name: "Mint", start: RGBAColor(hex: 0x0F8F7E), end: RGBAColor(hex: 0x6EE59A), angle: 135),
        .init(name: "Slate", start: RGBAColor(hex: 0x1E2024), end: RGBAColor(hex: 0x4A4F58), angle: 135),
        .init(name: "Blush", start: RGBAColor(hex: 0xE8A0B4), end: RGBAColor(hex: 0xFBE3E8), angle: 135),
    ]

    /// Built-in wallpapers: soft blends of four colours, drawn by the shader (no image files).
    public static let wallpapers: [WallpaperPreset] = [
        .init(name: "Aurora", colors: [RGBAColor(hex: 0x0B1026), RGBAColor(hex: 0x3EE6B0), RGBAColor(hex: 0x7A5CFF), RGBAColor(hex: 0x2A7BFF)]),
        .init(name: "Dusk", colors: [RGBAColor(hex: 0x2B1B4E), RGBAColor(hex: 0xFF7E67), RGBAColor(hex: 0xC84B9B), RGBAColor(hex: 0x5B3FA8)]),
        .init(name: "Meadow", colors: [RGBAColor(hex: 0x0F3B2E), RGBAColor(hex: 0x7BD88F), RGBAColor(hex: 0xE8F5A3), RGBAColor(hex: 0x1F7A6B)]),
        .init(name: "Ember", colors: [RGBAColor(hex: 0x1A0F1F), RGBAColor(hex: 0xFF5F3D), RGBAColor(hex: 0xFFB347), RGBAColor(hex: 0xB8325A)]),
    ]
    /// The interface's accent blue (selected choices, tools that are on, the main button). A little
    /// deeper than the system blue so white text on it is easy to read.
    public static let accentColor = RGBAColor(hex: 0x0095A3)
    /// Colour of the app window behind the preview.
    public static let previewSurround = RGBAColor(r: 0.11, g: 0.11, b: 0.12, a: 1)

    // MARK: Preview
    public static let previewMaxFPS = 60

    // MARK: Timeline
    /// Speed-ups offered in the Speed menu (a custom value can also be typed in).
    public static let speedPresets: [Double] = [2, 4, 8]
    public static let customSpeedRange = 1.1...32.0
    /// Shortest clip a split can make, in seconds of finished video.
    public static let minimumClipSeconds = 0.1
    /// Height of each timeline track (clips on top, zooms below), in points.
    public static let timelineTrackHeight: Double = 40
    /// Gap drawn between clips on the timeline, in points.
    public static let timelineClipGap: Double = 4
    /// Timeline colours: clips (and the selected clip), the clip label (white), the blue edit line,
    /// the white playhead, and the (empty) zoom track.
    public static let timelineClipColor = RGBAColor(hex: 0xDE2A78)
    public static let timelineSelectedClipColor = RGBAColor(hex: 0xF57AA8)
    public static let timelineClipLabelColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    public static let timelineEditLineColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.3)   // subtle gray hover line
    public static let timelineEditTagColor = RGBAColor(hex: 0x3A3A3D)   // the hover time tag (solid, so the ruler doesn't show through)
    public static let timelinePlayheadColor = accentColor   // the accent teal
    public static let timelineZoomTrackColor = RGBAColor(hex: 0x14282C)
    /// How solid the clip and zoom bars' fill is (labels and the selection ring stay fully solid).
    public static let timelineBarOpacity = 0.45       // zoom bars
    public static let timelineClipOpacity = 0.38      // clip bars (the magenta)
    /// Lighter purple for the ring around the selected zoom (the selected clip's ring uses the selected-clip orange).
    public static let timelineSelectedZoomColor = RGBAColor(hex: 0x3CC8D6)
    /// Width of the ring around the selected clip or zoom, in points.
    public static let timelineSelectionRingWidth: Double = 1
    /// Zoom blocks on the zoom track.
    public static let timelineZoomColor = RGBAColor(hex: 0x007683)
    /// Width of the grab area at each end of a zoom block for resizing, in points.
    public static let timelineZoomEdgeGrab: Double = 7
    /// Time ruler above the tracks: its height, the steps it can count in (seconds), and the
    /// least room between two labels (points); the smallest step that leaves that room is used.
    public static let timelineRulerHeight: Double = 22
    public static let timelineRulerSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    public static let timelineRulerMinLabelSpacing: Double = 60
    /// Room left of the tracks for each track's small icon, in points.
    public static let timelineGutterWidth: Double = 23
    /// Space under the ruler before the clip track, and between the clip track and the zoom track, in points.
    public static let timelineRulerToTrackGap: Double = 4
    public static let timelineTrackGap: Double = 12
    /// How far the playhead and blue line reach below the zoom track, in points.
    public static let timelineLineOverhang: Double = 8

    // MARK: Zoom
    /// How far a new zoom goes (1.5 = 150%), and the range of the Amount slider.
    public static let defaultZoomScale = 1.5
    public static let zoomScaleRange = 1.1...4.0
    /// Clicking the empty zoom track adds a zoom this long: a share of the video's length,
    /// kept between the range's ends (seconds of finished video).
    public static let clickZoomFractionOfVideo = 0.10
    public static let clickZoomSecondsRange = 1.0...10.0
    /// Shortest zoom, in seconds of finished video.
    public static let minimumZoomSeconds = 0.3
    /// Easing presets: transition = seconds for the zoom-in (and again for the zoom-out),
    /// bounce = 0 (settles smoothly) to 1 (most overshoot).
    public static let zoomEasingPresets: [EasingPreset] = [
        .init(name: "Smooth", transition: 1.0, bounce: 0),
        .init(name: "Quick", transition: 0.6, bounce: 0),
        .init(name: "Gentle", transition: 1.6, bounce: 0),
        .init(name: "Bouncy", transition: 0.9, bounce: 0.5),
    ]
    public static let defaultZoomEasing = 0
    public static let zoomTransitionRange = 0.2...3.0
    /// The spring behind the easing. Damping at full bounce (1 = no overshoot; 0.5 ≈ 16% overshoot),
    /// and how settled the spring is when the transition ends (higher = faster start, longer tail).
    public static let springMinDamping = 0.5
    public static let springSettle = 6.0

    // MARK: Crop
    /// Smallest crop, as a fraction of the recording's width and height.
    public static let minimumCropFraction = 0.1

    /// Slider drags and handle drags closer together than this count as one undo step.
    public static let undoCoalesceSeconds = 0.6
    /// How many edits Undo remembers.
    public static let undoLimit = 200

    // MARK: Export
    /// Sizes offered for MP4, as the shorter side (1080 = 1920×1080, 1080×1080 or 1080×1920), and the frame rates offered.
    public static let mp4Heights = [720, 1080, 2160]
    public static let mp4FPSChoices = [30, 60]
    /// GIF: sizes (shorter side) up to 1080p; frame rates stay low because GIFs get big fast.
    public static let gifHeights = [480, 720, 1080]
    public static let gifFPSChoices = [10, 15, 20, 25]
    public static let defaultGIFHeight = 720
    public static let defaultGIFFPS = 15
    /// How many moments of the video are sampled to pick the GIF colours and estimate its size.
    public static let gifSampleCount = 8
    /// Strength of the dithering that hides colour banding in gradients (0 = off), in 0–255 colour steps.
    public static let gifDither = 7
    /// How many finished frames the GPU may work ahead of the encoder (speeds up export).
    public static let exportFramesInFlight = 4
    /// Video bitrate in bits per second per million output pixels. Screen content has
    /// sharp text, so this is generous: about 16 Mbit/s at 1080p.
    public static let exportBitsPerMegapixel: Double = 7_700_000
    /// Seconds between keyframes in the exported MP4.
    public static let exportKeyframeIntervalSeconds: Double = 2
    /// Try the Apple-silicon hardware encoder first; fall back to software only if it refuses.
    public static let exportRequireHardwareEncoder = true

    // MARK: Recording (phase 2, P1)
    /// Seconds counted down (3, 2, 1) before recording starts.
    public static let recordingCountdownSeconds = 3
    /// Frames per second the screen is captured at (fewer when nothing on screen changes).
    public static let recordingFPS = 60
    /// Recording bitrate: bits per second per megapixel of the video (HEVC, hardware encoder).
    /// A Retina 3024×1964 recording gets about 36 Mbit/s; screen content compresses well.
    public static let recordingBitsPerMegapixel = 6_000_000.0
    /// The video is written in pieces this long (seconds), so a crash keeps everything but the last piece.
    public static let recordingFragmentSeconds = 2.0
    /// How often the cursor is looked at (times per second). Positions are only kept when it moves.
    public static let cursorPollHz = 120.0
    /// A new cursor position is kept only after moving at least this far (video pixels).
    public static let cursorMinMovePixels = 0.5
    /// How often the cursor's shape (arrow, I-beam…) is checked (times per second).
    public static let cursorShapePollHz = 20.0
    /// The smallest area that can be recorded (points per side).
    public static let recordingMinAreaPoints = 64.0
    /// Folder (inside ~/Movies) where recordings and their projects are saved.
    public static let recordingsFolderName = "Video Editor"
    /// Hide desktop icons while recording, unless switched off.
    public static let defaultHideDesktopIcons = true
    /// The recording control sits this far above the bottom of the screen (above the Dock).
    public static let recordingControlBottomGap: Double = 24
    /// Recording an area: the control sits this far below the area (it includes the bar's own 4 pt margin).
    public static let recordingControlAreaGap: Double = 4
    /// Recording an area: the rest of its display is dimmed with black at this opacity (Mari's wireframe).
    public static let recordingAreaDimOpacity: Double = 0.45
    /// Recording a window: a muted magenta border around it (Claude's shade, for Mari to review).
    public static let recordingWindowBorderColor = RGBAColor(hex: 0xB8579A)
    public static let recordingWindowBorderWidth: Double = 5
    /// The border's inner corner radius. Big enough to sit outside macOS 26's rounded window corners, so no
    /// gap shows; the border also overlaps the window's edge by `recordingWindowBorderOverlap`.
    public static let recordingWindowBorderInnerRadius: Double = 22
    public static let recordingWindowBorderOverlap: Double = 1

    // MARK: Cursor (phase 2, P2) — drawn from the cursor log; all values Claude's calls, for Mari to review
    /// New recordings' cursor look.
    public static let defaultCursorStyle = CursorLook.Style.black
    /// Size: 1 = the pointer's size on screen while recording.
    public static let defaultCursorSize = 1.5
    public static let cursorSizeRange = 0.5...4.0
    /// Smoothing 0–1. At 1 the path is averaged over about ±`cursorMaxSmoothingSeconds` × 2 (a bell curve).
    public static let defaultCursorSmoothing = 0.5
    public static let cursorMaxSmoothingSeconds = 0.14
    /// Motion blur 0–1. At 1 each frame blurs the cursor over the last `cursorMaxBlurSeconds` of its movement
    /// (in finished-video seconds), so it only shows when the cursor moves fast.
    public static let defaultCursorMotionBlur = 0.5
    public static let cursorMaxBlurSeconds = 0.05
    /// The most copies of the cursor blended for one blurred frame.
    public static let cursorMaxBlurSamples = 24
    public static let defaultCursorClickEffect = CursorLook.ClickEffect.ripple
    public static let defaultCursorHideWhenIdle = true
    /// Hide when idle: fade out after this many seconds without moving or clicking, over `cursorFadeSeconds`;
    /// it fades back in over the same time, finishing as it starts to move.
    public static let cursorIdleSeconds = 2.0
    public static let cursorFadeSeconds = 0.3
    /// While a button is held the cursor shrinks to this size, easing over these times (seconds).
    public static let cursorPressScale = 0.82
    public static let cursorPressSeconds = 0.07
    public static let cursorReleaseSeconds = 0.15
    /// Click effects: how long one lasts (finished-video seconds), its size (radius, in screen points at cursor
    /// size 1, grows with the cursor size), and its colour. A faint dark edge keeps it visible on white.
    public static let clickEffectSeconds = 0.5
    public static let clickEffectRadiusPoints = 18.0
    public static let clickEffectColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    public static let clickEffectOpacity = 0.85
    public static let clickEffectEdgeOpacity = 0.28
    /// Colours of the cursor art: the dark and the light parts (swapped for the white style).
    public static let cursorDark = RGBAColor(hex: 0x111114)
    public static let cursorLight = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    /// The cursor's soft shadow strength (0–1).
    public static let cursorShadowOpacity = 0.35
    /// Dot style: radius (screen points at size 1) and fill; a light ring a fifth of the radius wide goes round it.
    public static let cursorDotRadiusPoints = 8.0
    public static let cursorDotFill = RGBAColor(r: 0, g: 0, b: 0, a: 0.45)
    /// Pixels per side of each cursor picture the app draws (bigger = sharper when the cursor is huge).
    public static let cursorArtCellPixels = 512

}

public struct GradientPreset: Sendable {
    public let name: String
    public let start: RGBAColor, end: RGBAColor
    public let angle: Double
}

public struct EasingPreset: Sendable {
    public let name: String
    public let transition: Double
    public let bounce: Double
}

public struct WallpaperPreset: Sendable {
    public let name: String
    /// Four colours, placed at the top-left, top-right, bottom-left and bottom-right.
    public let colors: [RGBAColor]
}

/// A colour with red, green, blue and alpha from 0 to 1.
public struct RGBAColor: Codable, Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 255) / 255, g: Double((hex >> 8) & 255) / 255,
                  b: Double(hex & 255) / 255, a: 1)
    }
    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}
