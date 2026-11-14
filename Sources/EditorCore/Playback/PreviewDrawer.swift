import MetalKit

/// Draws the preview: each screen refresh it takes the current video frame and runs it
/// through the shared FrameRenderer into the on-screen view.
@MainActor
public final class PreviewDrawer: NSObject, MTKViewDelegate {
    private let renderer: FrameRenderer
    private let playback: PlaybackController
    /// Read every frame, so edits show up immediately.
    public var project: Project?
    /// What to leave out while editing on the preview (crop handles, aiming a zoom).
    /// While playing, aiming a zoom shows the real zoom.
    public var mode: LayoutMode = .normal
    /// How many preview frames showed real video (used by the debug snapshot).
    public private(set) var videoFramesDrawn = 0

    public init(renderer: FrameRenderer, playback: PlaybackController) {
        self.renderer = renderer
        self.playback = playback
    }

    public func configure(_ view: MTKView) {
        view.device = renderer.context.device
        view.colorPixelFormat = MetalContext.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = Settings.previewMaxFPS
        view.delegate = self
    }

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = renderer.makeCommandBuffer() else { return }
        if let project, let frame = playback.frameForDisplay() {
            let size = CGSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer))
            // Animations (zoom) follow the playback clock, not the frame's own time: a 30 fps recording
            // would otherwise move the zoom in uneven steps on a 60 Hz screen. Export does the same (frame n / fps).
            let clock = playback.isPlaying && playback.displayClock.isFinite ? playback.displayClock : frame.time
            let outputTime = playback.timeMap?.outputTime(forSource: clock) ?? clock
            let m: LayoutMode = (mode == .withoutZoom && playback.isPlaying) ? .normal : mode
            let u = FrameLayout.uniforms(project: project, sourceSize: size, outputTime: outputTime,
                                         timeMap: playback.timeMap, mode: m)
            let cursor = FrameLayout.cursorUniforms(project: project, outputTime: outputTime, timeMap: playback.timeMap)
            renderer.encode(frame: frame.buffer, uniforms: u, cursor: cursor, backgroundImagePath: project.style.kind == .image ? project.style.imagePath : nil, into: drawable.texture, commandBuffer: cb)
            videoFramesDrawn += 1
        } else {
            renderer.encodeClear(Settings.previewSurround, into: drawable.texture, commandBuffer: cb)
        }
        cb.present(drawable)
        cb.commit()
    }
}
