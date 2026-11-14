import Foundation
import Metal

/// The GPU and the compiled shaders, created once and shared by preview and export.
public final class MetalContext: @unchecked Sendable {
    public static let shared: MetalContext? = try? MetalContext()

    public let device: MTLDevice
    let framePipeline: MTLRenderPipelineState
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    public enum ContextError: Error { case noGPU }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ContextError.noGPU }
        self.device = device
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "frameFragment")
        desc.colorAttachments[0].pixelFormat = Self.pixelFormat
        framePipeline = try device.makeRenderPipelineState(descriptor: desc)
    }

    private let atlasLock = NSLock()
    private var atlas: MTLTexture?

    /// The cursor pictures (`CursorArt`) as one mipmapped texture, drawn the first time a cursor is shown.
    public var cursorAtlas: MTLTexture? {
        atlasLock.lock(); defer { atlasLock.unlock() }
        if let atlas { return atlas }
        let art = CursorArt.atlas()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: art.width, height: art.height, mipmapped: true)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d), let queue = device.makeCommandQueue() else { return nil }
        art.bytes.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, art.width, art.height), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: art.width * 4)
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
        }
        atlas = t
        return t
    }
}
