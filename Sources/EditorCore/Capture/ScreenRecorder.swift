import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// What to record.
public enum CaptureTarget: Equatable, Sendable {
    /// A whole display.
    case display(CGDirectDisplayID)
    /// One window, on its own (other windows in front of it don't show).
    case window(CGWindowID)
    /// Part of a display, in that display's own points (top-left origin).
    case area(CGDirectDisplayID, CGRect)
}

/// Records the screen with ScreenCaptureKit into a QuickTime movie, without the system cursor
/// (P2 draws its own from the cursor log). No sound. Pausing drops the frames in between, so the
/// file is one continuous take. The movie is written in short pieces, so a crash keeps the take.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    public enum RecorderError: LocalizedError {
        case targetGone, noFrames, writerFailed(String)
        public var errorDescription: String? {
            switch self {
            case .targetGone: return "The display or window to record isn't available any more."
            case .noFrames: return "Nothing was recorded."
            case .writerFailed(let why): return "The recording couldn't be saved. \(why)"
            }
        }
    }

    public let fileURL: URL
    /// Called (on a background queue) if the recording stops by itself, e.g. the recorded window closed.
    public var onUnexpectedStop: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "video-editor.capture")
    private let lock = NSLock()
    private var clockStorage = CaptureClock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart: CMTime?
    private var lastFrameTime: CMTime?
    private var framesWritten = 0
    private var stopping = false

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Host time now, on the same clock ScreenCaptureKit stamps frames with.
    public static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// The recording's clock (thread-safe copy).
    public var clock: CaptureClock { lock.withLock { clockStorage } }

    /// Seconds of video for a host time (nil before the first frame and while paused). Used for the cursor log.
    public func videoTime(atHost t: Double) -> Double? { clock.videoTime(t) }

    // MARK: Setting up

    /// Finds the target, works out the video's size and where it sits on screen, and gets the stream ready.
    /// `excludingWindowsOf` hides this app's own windows (the recording controls); `hideDesktopIcons` hides
    /// Finder's desktop icons from the video (Finder itself isn't changed).
    public func prepare(target: CaptureTarget, hideDesktopIcons: Bool, excludingWindowsOf pid: pid_t,
                        name: String) async throws -> (geometry: CaptureGeometry, info: CaptureInfo) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        let kind: CaptureInfo.Kind
        var sourceRect: CGRect?
        var frame: CGRect

        func displayFilter(_ id: CGDirectDisplayID) throws -> (SCDisplay, SCContentFilter) {
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.targetGone }
            let hidden = content.windows.filter { w in
                guard let app = w.owningApplication else { return false }
                if app.processID == pid { return true }
                return hideDesktopIcons && app.bundleIdentifier == "com.apple.finder" && w.windowLayer < 0
            }
            return (d, SCContentFilter(display: d, excludingWindows: hidden))
        }

        switch target {
        case .display(let id):
            let (d, f) = try displayFilter(id)
            filter = f; kind = .display; frame = d.frame
        case .area(let id, let local):
            let (d, f) = try displayFilter(id)
            filter = f; kind = .area
            let scale = Double(f.pointPixelScale)
            let displayLocal = CGRect(origin: .zero, size: d.frame.size)
            let r = CaptureGeometry.clampArea(local, to: displayLocal, scale: scale, minimumPoints: Settings.recordingMinAreaPoints)
            sourceRect = r
            frame = CaptureGeometry.globalRect(r, onDisplayAt: d.frame)
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.targetGone }
            filter = SCContentFilter(desktopIndependentWindow: w); kind = .window; frame = w.frame
        }

        let scale = Double(filter.pointPixelScale)
        let geometry = CaptureGeometry(frame: frame, scale: scale)
        let size = geometry.pixelSize

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Settings.recordingFPS))
        config.showsCursor = false                       // P2 draws the cursor from the log
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        config.capturesAudio = false
        if kind == .window { config.ignoreShadowsSingleWindow = true }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try makeWriter(width: size.width, height: size.height)

        let info = CaptureInfo(kind: kind, width: size.width, height: size.height, scale: scale, frame: frame, name: name)
        return (geometry, info)
    }

    private func makeWriter(width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: fileURL)
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: Settings.recordingFragmentSeconds, preferredTimescale: 600)
        let settings = Self.videoSettings(width: width, height: height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("The video encoder refused the settings.") }
        writer.add(input)
        self.writer = writer; self.input = input; self.adaptor = adaptor
    }


    /// Encoder settings for a recording: HEVC on the hardware encoder at the capture's own size.
    public static func videoSettings(width: Int, height: Int) -> [String: Any] {
        let megapixels = Double(width * height) / 1_000_000
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(megapixels * Settings.recordingBitsPerMegapixel),
                AVVideoExpectedSourceFrameRateKey: Settings.recordingFPS,
                AVVideoMaxKeyFrameIntervalDurationKey: Settings.recordingFragmentSeconds,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    // MARK: Recording

    public func start() async throws {
        guard let stream, let writer else { throw RecorderError.targetGone }
        guard writer.startWriting() else { throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "") }
        try await stream.startCapture()
    }

    public func pause() { let now = Self.hostNow(); lock.withLock { clockStorage.pause(at: now) } }

    public func resume() { let now = Self.hostNow(); lock.withLock { clockStorage.resume(at: now) } }

    /// Stops and finishes the file. Returns the length of the recording in seconds.
    public func stop() async throws -> Double {
        let now = Self.hostNow()
        queue.sync { stopping = true }
        try? await stream?.stopCapture()
        stream = nil
        return try await finishWriting(endHost: now)
    }

    /// Stops without keeping anything (cancelled before or during the countdown, or after an error).
    public func discard() async {
        queue.sync { stopping = true }
        try? await stream?.stopCapture()
        stream = nil
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func finishWriting(endHost: Double) async throws -> Double {
        guard let writer, let input else { throw RecorderError.noFrames }
        let (start, last, frames, clock) = queue.sync { (sessionStart, lastFrameTime, framesWritten, self.clock) }
        guard let start, frames > 0 else { writer.cancelWriting(); throw RecorderError.noFrames }
        let duration = clock.elapsed(endHost)
        var end = CMTimeAdd(start, CMTime(seconds: duration, preferredTimescale: 600))
        if let last, CMTimeCompare(end, last) <= 0 { end = CMTimeAdd(last, CMTime(value: 1, timescale: CMTimeScale(Settings.recordingFPS))) }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed { throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "") }
        return CMTimeSubtract(end, start).seconds
    }

    // MARK: Frames (on `queue`)

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopping, sampleBuffer.isValid,
              let pixels = sampleBuffer.imageBuffer, Self.isCompleteFrame(sampleBuffer),
              let writer, writer.status == .writing, let input, let adaptor else { return }
        let pts = sampleBuffer.presentationTimeStamp
        let clock: CaptureClock = lock.withLock {
            clockStorage.begin(at: pts.seconds)
            return clockStorage
        }
        if clock.isPaused { return }
        if sessionStart == nil { writer.startSession(atSourceTime: pts); sessionStart = pts }
        let shifted = CMTimeSubtract(pts, CMTime(seconds: clock.pausedTotal, preferredTimescale: pts.timescale))
        if let last = lastFrameTime, CMTimeCompare(shifted, last) <= 0 { return }
        guard input.isReadyForMoreMediaData else { return }   // drop a frame rather than stall the stream
        if adaptor.append(pixels, withPresentationTime: shifted) {
            lastFrameTime = shifted; framesWritten += 1
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopping else { return }
        onUnexpectedStop?(error)
    }

    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

/// Screen recording permission (System Settings › Privacy & Security › Screen & System Audio Recording).
public enum ScreenRecordingPermission {
    /// True if the app may record the screen. Doesn't ask.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system's own request the first time; later it just answers. Returns whether it's allowed now.
    @discardableResult public static func request() -> Bool { CGRequestScreenCaptureAccess() }
    /// The page in System Settings where the app can be switched on.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
