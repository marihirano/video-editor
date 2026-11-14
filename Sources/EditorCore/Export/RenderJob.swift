import AVFoundation
import Metal

/// Hands out the source frame to show at a given moment while reading a video forward:
/// the latest frame at or before that moment.
final class FrameFeeder {
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?

    init(output: AVAssetReaderTrackOutput) {
        self.output = output
        current = output.copyNextSampleBuffer()
        next = output.copyNextSampleBuffer()
    }

    var hasFrames: Bool { current != nil }

    func frame(atSource time: Double, tolerance: Double) -> CVImageBuffer? {
        while let candidate = next, candidate.presentationTimeStamp.seconds <= time + tolerance {
            current = candidate
            next = output.copyNextSampleBuffer()
        }
        return current?.imageBuffer
    }
}

/// What both exports share: the project at its final size, a way to read source frames,
/// and a way to draw one finished frame into a pixel buffer with the preview's renderer.
final class RenderJob {
    let project: Project
    let info: VideoInfo
    let asset: AVAsset
    let track: AVAssetTrack
    let renderer: FrameRenderer
    let timeMap: TimeMap

    init(project: Project, info: VideoInfo, asset: AVAsset, track: AVAssetTrack) throws {
        guard let context = MetalContext.shared else { throw Exporter.ExportError.noGPU }
        self.project = project; self.info = info; self.asset = asset; self.track = track
        renderer = FrameRenderer(context: context)
        timeMap = TimeMap(project: project, sourceDuration: info.duration)
    }

    var fps: Double { Double(project.output.fps) }
    var frameCount: Int { max(1, Int((timeMap.outputDuration * fps).rounded())) }

    func makeReader(timeRange: CMTimeRange? = nil) throws -> (AVAssetReader, FrameFeeder) {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Exporter.ExportError.cannotRead(error.localizedDescription) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: VideoInfo.decodeSettings)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        if let timeRange { reader.timeRange = timeRange }
        guard reader.startReading() else { throw Exporter.ExportError.cannotRead(reader.error?.localizedDescription ?? "") }
        return (reader, FrameFeeder(output: out))
    }

    func sourceTime(forOutput t: Double) -> Double { info.start + timeMap.sourceTime(forOutput: t) }

    /// Draws the frame for `outputTime` into `buffer` and starts the GPU. Wait on the returned command buffer.
    func render(frame: CVImageBuffer, outputTime: Double, into buffer: CVPixelBuffer) throws -> MTLCommandBuffer {
        guard let (target, targetRef) = renderer.texture(for: buffer, asTarget: true),
              let cb = renderer.makeCommandBuffer() else { throw Exporter.ExportError.cannotWrite("Couldn't prepare a frame.") }
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let uniforms = FrameLayout.uniforms(project: project, sourceSize: size, outputTime: outputTime, timeMap: timeMap)
        let cursor = FrameLayout.cursorUniforms(project: project, outputTime: outputTime, timeMap: timeMap)
        renderer.encode(frame: frame, uniforms: uniforms, cursor: cursor,
                        backgroundImagePath: project.style.kind == .image ? project.style.imagePath : nil,
                        into: target, commandBuffer: cb)
        cb.addCompletedHandler { _ in _ = targetRef }
        cb.commit()
        return cb
    }
}
