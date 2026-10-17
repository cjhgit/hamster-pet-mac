import AppKit
import MetalKit
import SceneKit

/// SceneKit owns the real 3D scene; MetalKit presents only explicitly requested
/// frames. There is no SceneKit display link competing with the simulation.
@MainActor final class Hamster3DRenderView: MTKView, MTKViewDelegate {
    let renderer: SCNRenderer
    private let queue: MTLCommandQueue?
    private let inFlight = DispatchSemaphore(value: 3)
    private var lastDrawableSize = CGSize.zero
    private var needsRendering = true
    private(set) var submittedFrames = 0
    private(set) var offscreenFrames = 0
    private(set) var failed = false
    override var isFlipped: Bool { false }

    var scene: SCNScene? {
        get { renderer.scene }
        set { renderer.scene = newValue }
    }
    var pointOfView: SCNNode? {
        get { renderer.pointOfView }
        set { renderer.pointOfView = newValue }
    }
    var backgroundColor: NSColor = .white {
        didSet {
            let rgb = backgroundColor.usingColorSpace(.extendedSRGB)!
            // Render-target clear values are linear when using an sRGB target.
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            clearColor = MTLClearColorMake(linear(rgb.redComponent), linear(rgb.greenComponent), linear(rgb.blueComponent), rgb.alphaComponent)
        }
    }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        renderer = SCNRenderer(device: device, options: nil)
        queue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = false
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        sampleCount = device?.supportsTextureSampleCount(4) == true ? 4 : 1
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColorMake(1, 1, 1, 1)
        clearDepth = 1
        layer?.isOpaque = false
        layer?.masksToBounds = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size != lastDrawableSize else { return }
        lastDrawableSize = size
        invalidateFrame()
    }
    func invalidateFrame() { needsRendering = true; needsDisplay = true }
    func discardDrawables() { releaseDrawables(); needsRendering = true }
    func presentFrame() {
        needsRendering = true
        guard window?.isVisible == true, !NSApp.isHidden else { needsDisplay = true; return }
        needsDisplay = false
        draw()
    }
    func draw(in view: MTKView) {
        guard needsRendering, !failed,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let command = queue?.makeCommandBuffer() else { inFlight.signal(); return }
        command.label = "Hamster 3D presentation"
        SCNTransaction.flush()
        renderer.render(atTime: ProcessInfo.processInfo.systemUptime, viewport: .init(origin: .zero, size: drawableSize),
                        commandBuffer: command, passDescriptor: pass)
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            if completed.status == .error {
                NSLog("Hamster 3D rendering failed: %@", completed.error?.localizedDescription ?? "Unknown Metal error")
                DispatchQueue.main.async { self?.failed = true }
            }
        }
        command.present(drawable)
        command.commit()
        needsRendering = false
        submittedFrames += 1
    }

    /// The same renderer and pixel/depth formats as interactive presentation.
    /// GPU readback is limited to this explicit inspection/screenshot path.
    func image(size: CGSize) -> NSImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let device, let command = queue?.makeCommandBuffer() else { return nil }
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
        target.storageMode = .private
        target.usage = .renderTarget
        guard let resolved = device.makeTexture(descriptor: target) else { return nil }
        target.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        target.sampleCount = sampleCount
        guard let color = sampleCount > 1 ? device.makeTexture(descriptor: target) : resolved else { return nil }
        target.pixelFormat = depthStencilPixelFormat
        guard let depth = device.makeTexture(descriptor: target) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = sampleCount > 1 ? resolved : nil
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = sampleCount > 1 ? .multisampleResolve : .store
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        SCNTransaction.flush()
        renderer.render(atTime: 0, viewport: .init(origin: .zero, size: size), commandBuffer: command, passDescriptor: pass)
        let row = (width * 4 + 255) / 256 * 256
        guard let bytes = device.makeBuffer(length: row * height, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolved, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: width, height: height, depth: 1), to: bytes, destinationOffset: 0,
                  destinationBytesPerRow: row, destinationBytesPerImage: row * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let data = Data(bytes: bytes.contents(), count: row * height)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                                  space: space, bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        offscreenFrames += 1
        return NSImage(cgImage: image, size: size)
    }
}
