import AppKit
import MetalKit

/// No display link: the existing 30 Hz simulation requests one GPU frame at a time.
final class HamsterMetalView: MTKView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class HamsterMetalRenderer: NSObject, MTKViewDelegate {
    let view: HamsterMetalView
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stencilPipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let parity: MTLDepthStencilState
    private let union: MTLDepthStencilState
    private let mask: MTLDepthStencilState
    private let cover: MTLDepthStencilState
    private let maskedCover: MTLDepthStencilState
    private let clear: MTLDepthStencilState
    private let solid: MTLDepthStencilState
    private let inFlight = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var bufferIndex = 0
    private let engine: UnsafeMutableRawPointer
    var night = false
    private(set) var submittedFrames = 0
    private(set) var failed = false

    init?(engine: UnsafeMutableRawPointer) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.engine = engine
        self.device = device
        self.queue = queue
        let metalView = HamsterMetalView(frame: .zero, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .stencil8
        metalView.sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        metalView.clearStencil = 0
        metalView.layer?.isOpaque = false
        metalView.layer?.masksToBounds = true
        (metalView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view = metalView
        func stencil(_ operation: MTLStencilOperation, read: UInt32 = 0xff, write: UInt32,
                     compare: MTLCompareFunction = .always) -> MTLDepthStencilState? {
            let face = MTLStencilDescriptor()
            face.stencilCompareFunction = compare
            face.depthStencilPassOperation = operation
            face.readMask = read
            face.writeMask = write
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.frontFaceStencil = face
            descriptor.backFaceStencil = face
            return device.makeDepthStencilState(descriptor: descriptor)
        }
        guard let parity = stencil(.invert, write: 1), let union = stencil(.replace, write: 1),
              let mask = stencil(.invert, write: 0x80),
              let cover = stencil(.zero, read: 1, write: 1, compare: .equal),
              let maskedCover = stencil(.zero, read: 0x81, write: 1, compare: .equal),
              let clear = stencil(.zero, write: 1), let solid = stencil(.keep, write: 0) else { return nil }
        self.parity = parity; self.union = union; self.mask = mask
        self.cover = cover; self.maskedCover = maskedCover; self.clear = clear; self.solid = solid
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
            descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
            descriptor.stencilAttachmentPixelFormat = .stencil8
            descriptor.rasterSampleCount = metalView.sampleCount
            descriptor.colorAttachments[0].writeMask = []
            stencilPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "sceneColor")
            let color = descriptor.colorAttachments[0]!
            color.writeMask = .all
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            colorPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Metal renderer unavailable: %@", String(describing: error))
            return nil
        }
        super.init()
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !failed, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let frame = HamsterEngineBuildMetalFrame(engine, night ? 1 : 0)
        let bytes = Int(frame.vertexCount) * MemoryLayout<HamsterVertex>.stride
        let index = bufferIndex
        if buffers[index] == nil || buffers[index]!.length < bytes {
            buffers[index] = device.makeBuffer(length: max((bytes + 65_535) / 65_536 * 65_536, 262_144), options: .storageModeShared)
        }
        guard let buffer = buffers[index], let vertices = frame.vertices else { inFlight.signal(); return }
        memcpy(buffer.contents(), vertices, bytes)
        guard encode(frame, buffer: buffer, pass: pass, command: command) else { inFlight.signal(); return }
        bufferIndex = (index + 1) % buffers.count
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            if completed.status == .error {
                DispatchQueue.main.async { self?.failed = true }
            }
        }
        command.present(drawable)
        command.commit()
        submittedFrames += 1
    }

    private func encode(_ frame: HamsterMetalFrame, buffer: MTLBuffer, pass: MTLRenderPassDescriptor,
                        command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass), let commands = frame.commands else { return false }
        encoder.label = "Hamster vector coverage and color"
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var lighting = SIMD4<Float>(night ? 1 : 0, 0, 0, 0)
        encoder.setFragmentBytes(&lighting, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        var masked = false
        for index in 0..<Int(frame.commandCount) {
            let draw = commands[index]
            if draw.kind == 2 || draw.kind == 3 {
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(mask)
                encoder.setStencilReferenceValue(0x80)
                encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                masked = draw.kind == 2
                continue
            }
            if draw.kind != 4 {
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(draw.kind == 0 ? parity : union)
                encoder.setStencilReferenceValue(1)
                encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
            }
            encoder.setRenderPipelineState(colorPipeline)
            encoder.setDepthStencilState(draw.kind == 4 ? solid : (masked ? maskedCover : cover))
            encoder.setStencilReferenceValue(masked ? 0x81 : 1)
            var color = SIMD4<Float>(draw.red, draw.green, draw.blue, draw.alpha)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.coverVertex), vertexCount: 6)
            if masked {
                // Clear parity outside the mask too, before the next shape.
                encoder.setRenderPipelineState(stencilPipeline)
                encoder.setDepthStencilState(clear)
                encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.coverVertex), vertexCount: 6)
            }
        }
        encoder.endEncoding()
        return true
    }

    func releaseDrawables() {
        view.releaseDrawables()
        buffers = [nil, nil, nil]
    }

    /// Synchronous readback is exclusively for screenshots and rendering verification.
    /// The interactive renderer never waits for GPU completion or reads pixels back.
    func snapshot(size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        targetDescriptor.usage = [.renderTarget]
        targetDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: targetDescriptor) else { return nil }
        let attachment = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        attachment.textureType = view.sampleCount > 1 ? .type2DMultisample : .type2D
        attachment.sampleCount = view.sampleCount
        attachment.storageMode = .private
        attachment.usage = [.renderTarget]
        guard let multisample = device.makeTexture(descriptor: attachment) else { return nil }
        attachment.pixelFormat = .stencil8
        guard let stencil = device.makeTexture(descriptor: attachment), let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = view.sampleCount > 1 ? multisample : target
        pass.colorAttachments[0].resolveTexture = view.sampleCount > 1 ? target : nil
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = view.sampleCount > 1 ? .multisampleResolve : .store
        pass.stencilAttachment.texture = stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 0
        let frame = HamsterEngineBuildMetalFrame(engine, night ? 1 : 0)
        guard let vertices = frame.vertices,
              let buffer = device.makeBuffer(bytes: vertices, length: Int(frame.vertexCount) * MemoryLayout<HamsterVertex>.stride, options: .storageModeShared),
              encode(frame, buffer: buffer, pass: pass, command: command) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 stage; };
    vertex Vertex sceneVertex(uint id [[vertex_id]], device const packed_float2 *points [[buffer(0)]]) {
        float2 p = float2(points[id]);
        return {float4((p.x + 1) / 282 * 2 - 1, 1 - (p.y + 1) / 212 * 2, 0, 1), p};
    }
    fragment float4 sceneColor(Vertex input [[stage_in]], constant float4 &color [[buffer(0)]],
                               constant float4 &lighting [[buffer(1)]]) {
        float3 rgb = color.rgb;
        if (lighting.x > 0) {
            float strength = 0.55 * saturate(1 - distance(input.stage, float2(259, 40)) / 32);
            float3 glow = float3(1, 0.70, 0.35) * strength;
            // This affine color transform commutes with source-over blending.
            rgb = rgb * float3(0.90, 0.92, 0.96) * (1 - glow) + glow;
        }
        return float4(rgb * color.a, color.a);
    }
    """
}
