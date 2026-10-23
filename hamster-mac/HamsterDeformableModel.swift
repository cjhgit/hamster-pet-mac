import AppKit
import SceneKit
import simd
import Metal

/// The original simulation owns every pose and footfall. This mesh only adds volume.
@MainActor final class HamsterDeformableModel {
    typealias V = SIMD3<Float>
    let root = SCNNode()
    private let torso: Surface
    private let limbs: [Surface]
    private let legCreases: [Surface]
    private let paws: [Surface]
    private let limbCoat: SCNMaterial
    private let features: [Surface]
    private let rims: [Surface]
    private let earFolds: [Surface]
    private let mouth: [Surface]
    private let eyeHighlights: [SCNNode]
    private let tail: Surface
    private let heldFood = SCNNode()
    private let headFeatures = SCNNode()
    private var surfaces: [Surface] = []
    private var nodeRevision = 0
    var geometryRevision: Int { surfaces.reduce(nodeRevision) { $0 + $1.revision } }
    private var bodyGeneration: UInt32 = 0
    private(set) var landmarks: [V] = []
    private var frame = -1
    private let engine: UnsafeMutableRawPointer
    private var gpuBody: HamsterBodyGPU?
    private var movingParts: MovingPartsBatch?
    private struct Topology: Hashable { let rings, sides: Int; let capped, reversed: Bool }
    private var topologyCache: [Topology: [Int32]] = [:]
    private static let legCircle: [V] = (0..<24).map {
        let a = Float($0) / 24 * 2 * .pi
        return V(cos(a), sin(a), 0)
    }
    private static let legOutline: [Float] = (0...12).flatMap { j in
        // Fade only the buried root; exposed legs need a full cartoon rim.
        let t = min(1, Float(j) / 12 / 0.30)
        return Array(repeating: t * t * (3 - 2 * t), count: 24)
    } + [0, 1]
    private static let pawCircle: [SIMD2<Float>] = (0..<24).map {
        let a = Float($0) / 24 * 2 * .pi
        return .init(cos(a), sin(a))
    }
    private static let tubeCircle: [SIMD2<Float>] = (0..<10).map {
        let a = Float($0) / 10 * 2 * .pi
        return .init(cos(a), sin(a))
    }
    var bodyMeshingBackend: String { gpuBody == nil ? "CPU" : "Metal compute" }
    var bodyGPUSeconds: Double { gpuBody?.lastGPUSeconds ?? 0 }
    var bodyPositionsForInspection: [V] {
        if let mesh = gpuBody?.latest { return mesh.positionsForInspection() }
        guard let source = torso.node.geometry?.sources(for: .vertex).first else { return [] }
        return source.data.withUnsafeBytes { bytes in
            (0..<source.vectorCount).map { i in
                let at = source.dataOffset + i * source.dataStride
                return V(bytes.loadUnaligned(fromByteOffset: at, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: at + 4, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: at + 8, as: Float.self))
            }
        }
    }

    final class Surface {
        let node = SCNNode()
        private(set) var revision = 0
        private let hull = SCNNode()
        let materials: [SCNMaterial]
        var usesBatch = false
        private(set) var topologyRevision = 0
        private(set) var batchNormals: [V] = []
        var batchPoints: [V] { previousPoints }
        var batchIndices: [[Int32]] { cachedIndices }
        var batchOutline: Float { outline }
        func batchOutlineWeight(_ i: Int) -> Float {
            outline * (weightedOutline && outlineWeights.count == previousPoints.count ? outlineWeights[i] : 1)
        }
        func enableBatch() {
            usesBatch = true
            node.geometry = nil
            hull.removeFromParentNode()
        }
        var outlineWeights: [Float] = []
        var textureCoordinates: [SIMD2<Float>] = []
        private var cachedTextureCoordinates: [SIMD2<Float>] = []
        private let outline: Float
        private let weightedOutline: Bool
        private var cachedWeights: [Float] = []
        private var weightSource: SCNGeometrySource?
        private var previousPoints: [V] = []
        private var generatorInputs: [V] = []
        func inputsChanged(_ inputs: [V]) -> Bool {
            guard inputs != generatorInputs else { return false }
            generatorInputs = inputs
            return true
        }
        private var volumeIndices: [UInt32] = []
        private var volumeElement: SCNGeometryElement?
        private var cachedIndices: [[Int32]] = []
        private var elements: [SCNGeometryElement] = []
        init(name: String, materials: [SCNMaterial], ink: SCNMaterial, outline: Float = 0.55, silhouetteOnly: Bool = false, weightedOutline: Bool = false) {
            self.materials = materials
            self.outline = outline
            self.weightedOutline = weightedOutline
            node.name = name
            // Let the skin cover its own expanded outline at concave folds.
            // Other meshes keep their depth, including paws, ears and the wheel.
            if silhouetteOnly { node.renderingOrder = 101; hull.renderingOrder = 100 }
            if outline > 0 {
                hull.name = name + " outline"
                let m = ink.copy() as! SCNMaterial
                m.writesToDepthBuffer = !silhouetteOnly
                m.cullMode = .front
                // Expand in the GPU vertex stage. Both draws share positions,
                // normals and indices; no second expanded CPU mesh.
                let weight = weightedOutline ? " * _geometry.texcoords[0].x" : ""
                m.shaderModifiers = [.geometry: "#pragma body\n_geometry.position.xyz += _geometry.normal * \(outline)\(weight);"]
                hull.geometry = SCNGeometry()
                hull.geometry?.materials = materials.map { _ in m }
                node.addChildNode(hull)
            }
        }
        private func setGeometry(_ skin: SCNGeometry) {
            revision += 1
            skin.materials = materials
            node.geometry = skin
            guard outline > 0 else { return }
            let shell = SCNGeometry(sources: skin.sources, elements: skin.elements)
            shell.materials = hull.geometry!.materials
            let box = skin.boundingBox, padding = CGFloat(outline)
            shell.boundingBox = (min: .init(box.min.x - padding, box.min.y - padding, box.min.z - padding),
                                 max: .init(box.max.x + padding, box.max.y + padding, box.max.z + padding))
            hull.geometry = shell
        }

        func updateVolume(_ frame: HamsterBodyMesh) {
            guard let vertices = frame.vertices, let indices = frame.indices, frame.vertexCount > 0 else { return }
            let count = Int(frame.vertexCount), stride = MemoryLayout<HamsterBodyVertex>.stride
            let data = Data(bytes: vertices, count: count * stride)
            let nextIndices = Array(UnsafeBufferPointer(start: indices, count: Int(frame.indexCount)))
            if nextIndices != volumeIndices {
                volumeIndices = nextIndices
                volumeElement = SCNGeometryElement(indices: nextIndices, primitiveType: .triangles)
            }
            let sources = [
                SCNGeometrySource(data: data, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride),
                SCNGeometrySource(data: data, semantic: .normal, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride),
                SCNGeometrySource(data: data, semantic: .texcoord, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 24, dataStride: stride)]
            setGeometry(SCNGeometry(sources: sources, elements: [volumeElement!]))
        }

        func updateGPUVolume(_ mesh: HamsterBodyGPU.Mesh) {
            let sources = [
                SCNGeometrySource(buffer: mesh.vertices, vertexFormat: .float3, semantic: .vertex, vertexCount: mesh.vertexCount, dataOffset: 0, dataStride: 32),
                SCNGeometrySource(buffer: mesh.vertices, vertexFormat: .float3, semantic: .normal, vertexCount: mesh.vertexCount, dataOffset: 12, dataStride: 32),
                SCNGeometrySource(buffer: mesh.vertices, vertexFormat: .float2, semantic: .texcoord, vertexCount: mesh.vertexCount, dataOffset: 24, dataStride: 32)
            ]
            let element = SCNGeometryElement(buffer: mesh.indices, primitiveType: .triangles, primitiveCount: mesh.indexCount / 3, bytesPerIndex: 4)
            let skin = SCNGeometry(sources: sources, elements: [element])
            skin.boundingBox = mesh.bounds
            setGeometry(skin)
        }

        func update(_ points: [V], _ groups: [[Int32]]) {
            guard !points.isEmpty else { return }
            let sameTopology = cachedIndices == groups
            // Suppress numerical settling below 0.006 screen pixels even at
            // maximum zoom in the default window. Compare against the last
            // uploaded pose so real motion cannot accumulate unnoticed.
            let samePoints = previousPoints.count == points.count && zip(previousPoints, points).allSatisfy {
                simd_length_squared($0 - $1) <= 0.0005 * 0.0005
            }
            if sameTopology && samePoints && (!weightedOutline || cachedWeights == outlineWeights) && cachedTextureCoordinates == textureCoordinates { return }
            previousPoints = points
            if !sameTopology {
                cachedIndices = groups
                topologyRevision += 1
                if !usesBatch { elements = groups.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) } }
            }
            var normals = Array(repeating: V.zero, count: points.count)
            for indices in groups {
                for i in stride(from: 0, to: indices.count, by: 3) {
                    let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                    let n = simd_cross(points[b] - points[a], points[c] - points[a])
                    normals[a] += n; normals[b] += n; normals[c] += n
                }
            }
            for i in normals.indices {
                normals[i] = simd_length_squared(normals[i]) > 1e-10 ? simd_normalize(normals[i]) : V(0, 1, 0)
            }
            if usesBatch {
                batchNormals = normals
                cachedWeights = outlineWeights
                revision += 1
                return
            }
            func source(_ values: [V], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
                let data = values.withUnsafeBytes { Data($0) }
                return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<V>.stride)
            }
            var sources = [source(points, .vertex), source(normals, .normal)]
            if weightedOutline {
                if weightSource == nil || cachedWeights != outlineWeights {
                    cachedWeights = outlineWeights
                    let uv = points.indices.map { SIMD2<Float>(outlineWeights.count == points.count ? outlineWeights[$0] : 1, 0) }
                    let data = uv.withUnsafeBytes { Data($0) }
                    weightSource = SCNGeometrySource(data: data, semantic: .texcoord, vectorCount: points.count, usesFloatComponents: true,
                                                     componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride)
                }
                sources.append(weightSource!)
            } else if textureCoordinates.count == points.count {
                cachedTextureCoordinates = textureCoordinates
                let data = textureCoordinates.withUnsafeBytes { Data($0) }
                sources.append(SCNGeometrySource(data: data, semantic: .texcoord, vectorCount: points.count,
                                                usesFloatComponents: true, componentsPerVector: 2,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride))
            }
            setGeometry(SCNGeometry(sources: sources, elements: elements))
        }
    }

    /// Parts still have their original independent deforming skins. Grouping
    /// triangles by material avoids rebuilding and submitting dozens of tiny
    /// SceneKit geometries. One immutable vertex stream serves skin and hull.
    final class MovingPartsBatch {
        struct Vertex {
            var x, y, z, nx, ny, nz, outline, unused: Float
        }
        let node = SCNNode()
        private let hull = SCNNode()
        private let parts: [Surface]
        private var poseKey: [Int] = []
        private var layoutKey: [Int] = []
        private var elements: [SCNGeometryElement] = []
        private var materials: [SCNMaterial] = []
        private var hullElement: SCNGeometryElement?
        private var vertices: [Vertex] = []
        private let device: MTLDevice?
        private var vertexHeap: MTLHeap?
        init(parts: [Surface], ink: SCNMaterial, device: MTLDevice?) {
            self.parts = parts
            self.device = CommandLine.arguments.contains("--hamster-batch-data") ? nil : device
            if let device = self.device, device.supportsFamily(.apple1), !CommandLine.arguments.contains("--hamster-no-heap") {
                let descriptor = MTLHeapDescriptor()
                descriptor.size = 1024 * 1024
                descriptor.storageMode = .shared
                vertexHeap = device.makeHeap(descriptor: descriptor)
                vertexHeap?.label = "Immutable hamster limb frame outputs"
            }
            node.name = "Batched deforming limbs, paws and strokes"
            hull.name = "Batched deforming outlines"
            let material = ink.copy() as! SCNMaterial
            material.cullMode = .front
            material.shaderModifiers = [.geometry: "#pragma body\n_geometry.position.xyz += _geometry.normal * _geometry.texcoords[0].x;"]
            hull.geometry = SCNGeometry()
            hull.geometry?.materials = [material]
            node.addChildNode(hull)
        }
        func update() {
            let pose = parts.flatMap { [$0.revision, $0.node.isHidden ? 1 : 0] }
            guard pose != poseKey else { return }
            poseKey = pose
            let layout = parts.flatMap { [$0.topologyRevision, $0.batchPoints.count, $0.node.isHidden ? 1 : 0] }
            if layout != layoutKey {
                layoutKey = layout
                var grouped: [[Int32]] = [], outline: [Int32] = []
                var materialSlots: [ObjectIdentifier: Int] = [:]
                materials.removeAll(keepingCapacity: true)
                var offset: Int32 = 0
                for part in parts {
                    defer { offset += Int32(part.batchPoints.count) }
                    guard !part.node.isHidden else { continue }
                    for (i, indices) in part.batchIndices.enumerated() {
                        let material = part.materials[i % part.materials.count]
                        let key = ObjectIdentifier(material)
                        let slot: Int
                        if let existing = materialSlots[key] { slot = existing }
                        else { slot = grouped.count; materialSlots[key] = slot; grouped.append([]); materials.append(material) }
                        grouped[slot].append(contentsOf: indices.map { $0 + offset })
                        if part.batchOutline > 0 { outline.append(contentsOf: indices.map { $0 + offset }) }
                    }
                }
                elements = grouped.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
                hullElement = SCNGeometryElement(indices: outline, primitiveType: .triangles)
            }
            vertices.removeAll(keepingCapacity: true)
            var lo = V(repeating: .infinity), hi = V(repeating: -.infinity)
            for part in parts {
                for (i, point) in part.batchPoints.enumerated() {
                    let n = part.batchNormals[i]
                    vertices.append(Vertex(x: point.x, y: point.y, z: point.z, nx: n.x, ny: n.y, nz: n.z,
                                           outline: part.batchOutlineWeight(i), unused: 0))
                    lo = simd_min(lo, point); hi = simd_max(hi, point)
                }
            }
            guard !vertices.isEmpty, let hullElement else { return }
            let sources: [SCNGeometrySource]
            let bytes = vertices.count * MemoryLayout<Vertex>.stride
            if let buffer = vertexHeap?.makeBuffer(length: bytes, options: .storageModeShared) ?? device?.makeBuffer(length: bytes, options: .storageModeShared) {
                // A fresh immutable resource per pose: SceneKit and in-flight
                // draws retain it until safe to reclaim. Never overwrite a
                // previous pose. All three sources share this Metal allocation,
                // avoiding SceneKit's per-source Data-to-Metal uploads.
                buffer.label = "Hamster deforming limb vertices"
                vertices.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
                sources = [
                    SCNGeometrySource(buffer: buffer, vertexFormat: .float3, semantic: .vertex, vertexCount: vertices.count, dataOffset: 0, dataStride: 32),
                    SCNGeometrySource(buffer: buffer, vertexFormat: .float3, semantic: .normal, vertexCount: vertices.count, dataOffset: 12, dataStride: 32),
                    SCNGeometrySource(buffer: buffer, vertexFormat: .float2, semantic: .texcoord, vertexCount: vertices.count, dataOffset: 24, dataStride: 32)
                ]
            } else {
                let data = vertices.withUnsafeBytes { Data($0) }
                sources = [(SCNGeometrySource.Semantic.vertex, 0, 3), (.normal, 12, 3), (.texcoord, 24, 2)].map {
                    SCNGeometrySource(data: data, semantic: $0.0, vectorCount: vertices.count, usesFloatComponents: true,
                                      componentsPerVector: $0.2, bytesPerComponent: 4, dataOffset: $0.1, dataStride: 32)
                }
            }
            let geometry = SCNGeometry(sources: sources, elements: elements)
            geometry.materials = materials
            geometry.boundingBox = (.init(lo.x, lo.y, lo.z), .init(hi.x, hi.y, hi.z))
            node.geometry = geometry
            let shell = SCNGeometry(sources: sources, elements: [hullElement])
            shell.materials = hull.geometry!.materials
            // Pad for the limb and paw rims (up to 1.1 units).
            shell.boundingBox = (.init(lo.x - 1.3, lo.y - 1.3, lo.z - 1.3), .init(hi.x + 1.3, hi.y + 1.3, hi.z + 1.3))
            hull.geometry = shell
        }
    }

    init(engine: UnsafeMutableRawPointer, colors: [String: NSColor], device: MTLDevice?) {
        self.engine = engine
        var materialCache: [String: SCNMaterial] = [:]
        func mat(_ key: String, constant: Bool = false) -> SCNMaterial {
            let cacheKey = key + (constant ? ":constant" : ":lambert")
            if let material = materialCache[cacheKey] { return material }
            let m = SCNMaterial()
            m.diffuse.contents = colors[key] ?? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.10, alpha: 1)
            m.ambient.contents = m.diffuse.contents
            m.lightingModel = constant ? .constant : .lambert
            m.specular.contents = NSColor.black
            materialCache[cacheKey] = m
            return m
        }
        let bodyM = mat("bodyColor"), inkM = mat("ink", constant: true)
        let coat = bodyM.copy() as! SCNMaterial
        let texture = Self.coatTexture(body: colors["bodyColor"]!, cream: colors["snoutColor"]!)
        coat.diffuse.contents = texture
        coat.ambient.contents = texture
        coat.diffuse.magnificationFilter = .linear
        limbCoat = bodyM
        // Shade the small limbs as a continuation of the torso volume. Their
        // own narrow cones otherwise catch the lamp like separate bright cuffs.
        // Only the skin material changes normals; outline extrusion retains the
        // actual mesh normals and therefore its original silhouette.
        bodyM.shaderModifiers = [.geometry: """
        #pragma arguments
        float3 coatCenter;
        float3 coatAxis;
        float coatLength;
        #pragma body
        float3 delta = _geometry.position.xyz - coatCenter;
        float axial = dot(delta, coatAxis);
        float3 radial = delta - coatAxis * axial;
        float3 coatGradient = radial / 400.0 + coatAxis * axial / max(1.0, coatLength * coatLength);
        float3 coatNormal = length(coatGradient) > 0.00001 ? normalize(coatGradient) : _geometry.normal;
        _geometry.normal = normalize(mix(coatNormal, _geometry.normal, 0.12));
        """]
        torso = Surface(name: "Hamster deforming skin", materials: [coat], ink: inkM, outline: 1.30, silhouetteOnly: true)
        limbs = (0..<4).map { Surface(name: ["Right foreleg", "Left foreleg", "Right hindleg", "Left hindleg"][$0], materials: [bodyM], ink: inkM, outline: 1.10, weightedOutline: true) }
        legCreases = (0..<4).map { Surface(name: "Running flank crease \($0)", materials: [inkM], ink: inkM, outline: 0) }
        // Continue the body's coat all the way to the toes. A separate paw tint
        // reads as a mismatched patch under the cool night lighting.
        paws = (0..<4).map { Surface(name: "Deforming paw \($0)", materials: [bodyM], ink: inkM, outline: 1.00) }
        let earCoat = mat("earColor").copy() as! SCNMaterial
        let earTexture = Self.earTexture(base: colors["earColor"]!)
        earCoat.diffuse.contents = earTexture
        earCoat.ambient.contents = earTexture
        earCoat.diffuse.wrapS = .clamp
        earCoat.diffuse.magnificationFilter = .linear
        features = (0..<4).map { Surface(name: ["Right eye", "Left eye", "Right ear", "Left ear"][$0], materials: [$0 < 2 ? mat("eyeColor") : earCoat], ink: inkM, outline: 0) }
        rims = (0..<2).map { Surface(name: "Black ear rim \($0)", materials: [inkM], ink: inkM, outline: 0) }
        earFolds = (0..<2).map { Surface(name: "Inner ear fold \($0)", materials: [inkM], ink: inkM, outline: 0) }
        // A small constant-white sparkle rides each eye lens, giving the bead
        // eyes a catchlight; it scales with the eye so blinks hide it too.
        let sparkle = SCNMaterial()
        sparkle.diffuse.contents = NSColor(srgbRed: 0.78, green: 0.78, blue: 0.78, alpha: 1)
        sparkle.ambient.contents = sparkle.diffuse.contents
        sparkle.lightingModel = .constant
        sparkle.specular.contents = NSColor.black
        var highlights: [SCNNode] = []
        for index in 0..<2 {
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 14
            sphere.materials = [sparkle]
            let node = SCNNode(geometry: sphere)
            node.name = "Eye highlight \(index)"
            features[index].node.addChildNode(node)
            highlights.append(node)
        }
        eyeHighlights = highlights
        mouth = (0..<3).map { Surface(name: "Mouth stroke \($0)", materials: [inkM], ink: inkM, outline: 0) }
        tail = Surface(name: "Small flexible tail", materials: [mat("tailColor")], ink: inkM, outline: 0.85, weightedOutline: true)
        root.name = "Original hamster articulation"
        surfaces = [torso, tail] + limbs + legCreases + paws + features + rims + earFolds + mouth
        mouth[2].node.isHidden = true
        root.addChildNode(torso.node)
        let dynamicParts = [tail] + limbs + legCreases + paws + mouth
        if !ProcessInfo.processInfo.arguments.contains("--hamster-unbatched") {
            for mesh in dynamicParts { mesh.enableBatch() }
            let batch = MovingPartsBatch(parts: dynamicParts, ink: inkM, device: device)
            movingParts = batch
            root.addChildNode(batch.node)
        } else {
            for mesh in dynamicParts { root.addChildNode(mesh.node) }
        }
        headFeatures.name = "Rigid head features"
        root.addChildNode(headFeatures)
        for mesh in features + rims + earFolds { headFeatures.addChildNode(mesh.node) }
        let pellet = SCNSphere(radius: 3)
        pellet.segmentCount = 20
        pellet.materials = [mat("foodColor")]
        heldFood.geometry = pellet
        heldFood.name = "Food between original hands"
        root.addChildNode(heldFood)
        if !ProcessInfo.processInfo.arguments.contains("--hamster-cpu-body"), let device {
            do { gpuBody = try HamsterBodyGPU(device: device) }
            catch { NSLog("Hamster GPU body initialization failed: %@", String(describing: error)) }
        }
        update(force: true)
    }

    private func smooth(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
    private func setHidden(_ node: SCNNode, _ hidden: Bool) {
        guard node.isHidden != hidden else { return }
        node.isHidden = hidden
        nodeRevision += 1
    }
    private func setPosition(_ node: SCNNode, _ position: V) {
        guard simd_distance_squared(node.simdPosition, position) > 0.0005 * 0.0005 else { return }
        node.simdPosition = position
        nodeRevision += 1
    }
    private func point(_ index: Int) -> V {
        let p = HamsterEngineGetRigPoint(engine, Int32(index))
        return .init(Float(p.x), Float(p.y), Float(p.z))
    }
    private static func coatTexture(body: NSColor, cream: NSColor) -> NSImage {
        let image = NSImage(size: .init(width: 256, height: 2))
        image.lockFocus()
        let gradient = NSGradient(starting: body, ending: cream)!
        gradient.draw(in: NSRect(x: 0, y: 0, width: 256, height: 2), angle: 0)
        image.unlockFocus()
        return image
    }

    private static func earTexture(base: NSColor) -> NSImage {
        let pink = NSColor(srgbRed: 0.86, green: 0.58, blue: 0.55, alpha: 1)
        let image = NSImage(size: .init(width: 256, height: 2))
        image.lockFocus()
        NSGradient(colorsAndLocations:
            (pink.blended(withFraction: 0.26, of: .brown)!, 0),
            (pink, 0.22),
            (pink.blended(withFraction: 0.50, of: base)!, 0.36),
            (base.blended(withFraction: 0.24, of: .white)!, 0.50),
            (base, 0.72),
            (base.blended(withFraction: 0.16, of: .brown)!, 1))!
            .draw(in: NSRect(x: 0, y: 0, width: 256, height: 2), angle: 0)
        image.unlockFocus()
        return image
    }

    private func headPoint(_ p: V, state: HamsterSceneState, center: V) -> V {
        let a = Float(state.heading + state.headYaw), pitch = Float(state.headPitch)
        let x = cos(pitch) * p.x - sin(pitch) * p.y, y = sin(pitch) * p.x + cos(pitch) * p.y
        return center + .init(cos(a) * x + sin(a) * p.z, -y, sin(a) * x - cos(a) * p.z)
    }

    func update(force: Bool = false) {
        let current = Int(HamsterEngineGetFrameCount(engine))
        guard force || current != frame else { return }
        frame = current
        let state = HamsterEngineGetSceneState(engine)
        landmarks = (0..<24).map(point)
        if state.onWheel != 0 {
            // The 2D reference approximates a curved tread with two slopes. In a solid
            // wheel that lets toes enter the wall. Project only the contact points
            // onto the actual inner surface, retaining its phase and lifted feet.
            let angle = Float(-state.rotation * .pi / 180)
            let delta = V(27 - Float(state.x - 140), 105 - Float(210 - state.y), 0)
            let center = V(delta.x * cos(angle) + delta.y * sin(angle), -delta.x * sin(angle) + delta.y * cos(angle), 0)
            for leg in 0..<4 {
                let toe = 8 + leg * 5, wrist = toe - 1
                let radial = SIMD2<Float>(landmarks[toe].x - center.x, landmarks[toe].y - center.y)
                let distance = simd_length(radial)
                if distance > 95.6 {
                    let correction = radial * (95.6 / distance - 1)
                    landmarks[toe].x += correction.x; landmarks[toe].y += correction.y
                    landmarks[wrist].x += correction.x; landmarks[wrist].y += correction.y
                }
            }
        }
        let rear = landmarks[0], head = landmarks[2]
        if let gpuBody {
            do {
                if let mesh = try gpuBody.update(engine: engine) { torso.updateGPUVolume(mesh) }
            } catch {
                NSLog("Hamster GPU body failed, using CPU fallback: %@", String(describing: error))
                self.gpuBody = nil
            }
        }
        if gpuBody == nil {
            let volume = HamsterEngineBuildBodyMesh(engine)
            if force || volume.generation != bodyGeneration {
                torso.updateVolume(volume)
                bodyGeneration = volume.generation
            }
        }
        let running = state.onWheel != 0 ? smooth(Float((state.speed - 0.15) / 0.65)) : 0
        let torsoAxis = simd_normalize(landmarks[1] - rear)
        let torsoCenter = (landmarks[1] + rear) * 0.5
        limbCoat.setValue(NSValue(scnVector3: SCNVector3(torsoCenter)), forKey: "coatCenter")
        limbCoat.setValue(NSValue(scnVector3: SCNVector3(torsoAxis)), forKey: "coatAxis")
        limbCoat.setValue(simd_distance(landmarks[1], rear) * 0.5 + 20, forKey: "coatLength")
        let bodyDown = simd_normalize(simd_cross(V(sin(Float(state.heading)), 0, -cos(Float(state.heading))), torsoAxis))
        for leg in 0..<4 {
            let offset = 4 + leg * 5
            let p = Array(landmarks[offset..<(offset + 5)])
            // Bury the hindleg roots inside the tucked running belly. Wrist and
            // toe trajectories stay unchanged; the attachment must not form a
            // second, angular belly below the continuous torso skin.
            let attachment = p[0...2].map { point in
                let ventral = smooth(simd_dot(point - torsoCenter, bodyDown) / 8)
                return point - bodyDown * (leg >= 2 ? 3.5 * running * ventral : 0)
            }
            updateLeg(limbs[leg], crease: legCreases[leg], attachment: attachment, wrist: p[3], bodyCenter: torsoCenter, running: running)
            paw(paws[leg], wrist: p[3], toe: p[4])
        }
        // Ear rims and eye lenses only change shape when the original controls
        // change (e.g. blinking). Let the GPU transform their shared head frame
        // rather than rebuilding every vertex whenever the hamster turns.
        let featureAngle = Float(state.heading + state.headYaw)
        if simd_distance_squared(headFeatures.simdPosition, head) > 0.0005 * 0.0005 {
            headFeatures.simdPosition = head
            nodeRevision += 1
        }
        let orientation = simd_quatf(angle: -featureAngle, axis: V(0, 1, 0))
        if simd_length_squared(headFeatures.simdOrientation.vector - orientation.vector) > 1e-12 {
            headFeatures.simdOrientation = orientation
            nodeRevision += 1
        }
        for feature in 0..<4 {
            let count = Int(HamsterEngineGetRigFeatureCount(engine, Int32(feature)))
            let control = (0..<count).map { HamsterEngineGetRigFeatureLocalPoint(engine, Int32(feature), Int32($0)) }
            var contour: [V] = []
            func vec(_ p: HamsterRigPoint) -> V {
                return V(Float(p.x), Float(p.y), Float(p.z))
            }
            if let first = control.first {
                contour.append(vec(first))
                var i = 1
                while i < count {
                    if control[i].curve != 0 {
                        let start = contour.last!, handle = vec(control[i]), end = vec(control[(i + 1) % count])
                        for step in 1...8 { let t = Float(step) / 8; contour.append(start * ((1 - t) * (1 - t)) + handle * (2 * t * (1 - t)) + end * (t * t)) }
                        i += 2
                    } else { contour.append(vec(control[i])); i += 1 }
                }
            }
            if contour.count > 3 {
                if simd_distance(contour[0], contour.last!) < 0.001 { contour.removeLast() }
                if feature < 2 {
                    let center = contour.reduce(V.zero, +) / Float(contour.count)
                    var normal = simd_normalize(simd_cross(contour[1] - center, contour[2] - center))
                    if simd_dot(normal, center) < 0 { normal = -normal }
                    contour = contour.map { $0 + normal * 0.8 }
                }
                // Native eye/ear controls translate within the head as it nods.
                // Keep that translation on the node so a rigid ear and its
                // black rim don't rebuild their entire skin every frame.
                let center = contour.reduce(V.zero, +) / Float(contour.count)
                let local = contour.map { $0 - center }
                setPosition(features[feature].node, center)
                if feature < 2 {
                    lens(features[feature], contour: local, depth: 0.7)
                } else {
                    ear(features[feature], rim: rims[feature - 2], fold: earFolds[feature - 2], contour: local, center: center)
                }
                if feature < 2 {
                    // Catchlight: upper-outer point on the eye dome, sized by the
                    // eye itself so blinking shrinks it away naturally.
                    let radius = local.reduce(Float(0)) { $0 + simd_length($1) } / Float(local.count)
                    let side: Float = center.x >= 0 ? 1 : -1
                    var normal = V.zero
                    for i in local.indices { normal += simd_cross(local[i], local[(i + 1) % local.count]) }
                    normal = simd_length_squared(normal) > 1e-8 ? simd_normalize(normal) : V(0, 0, 1)
                    if simd_dot(normal, center) < 0 { normal = -normal }
                    let highlight = eyeHighlights[feature]
                    setHidden(highlight, state.eyeOpen < 0.3)
                    highlight.simdPosition = normal * 0.18 + V(side * radius * 0.30, radius * 0.32, 0)
                    highlight.simdScale = SIMD3<Float>(repeating: radius * 0.15)
                }
                if feature >= 2 {
                    setPosition(rims[feature - 2].node, center)
                    setPosition(earFolds[feature - 2].node, center)
                }
            }
        }
        let nose = headPoint(.init(35, 2, 0), state: state, center: head)
        let chin = headPoint(.init(33, 9, 0), state: state, center: head)
        let left = headPoint(.init(32, 1, -3), state: state, center: head)
        let right = headPoint(.init(32, 1, 3), state: state, center: head)
        tube(mouth[0], path: [left, nose, right], radius: 0.38)
        tube(mouth[1], path: [nose, chin], radius: 0.35)
        updateTail(rear: rear, bodyAxis: torsoAxis, bodyDown: bodyDown)
        setHidden(heldFood, state.eating == 0)
        if !heldFood.isHidden {
            let position = (landmarks[8] + landmarks[13]) * 0.5
            if simd_distance_squared(heldFood.simdPosition, position) > 0.0005 * 0.0005 {
                heldFood.simdPosition = position
                nodeRevision += 1
            }
        }
        movingParts?.update()
    }

    private func updateTail(rear: V, bodyAxis: V, bodyDown: V) {
        guard tail.inputsChanged([rear, bodyAxis, bodyDown]) else { return }
        // Anchor inside the rounded pelvis instead of extending the old 2D
        // tail marker, which can sit below the new volumetric rump.
        let root = rear - bodyAxis * 15 - bodyDown * 3
        let axis = simd_normalize(-bodyAxis - bodyDown * 0.35)
        let side = simd_normalize(simd_cross(bodyDown, bodyAxis))
        let up = simd_cross(axis, side)
        let rings = 18, sides = Self.pawCircle.count
        var vertices: [V] = []
        var outlineWeights: [Float] = []
        vertices.reserveCapacity((rings + 1) * sides)
        outlineWeights.reserveCapacity((rings + 1) * sides)
        for j in 0...rings {
            let t = Float(j) / Float(rings)
            // Close the buried root, then narrow steadily to a pointed tip.
            let center = root + axis * (10 * t) - bodyDown * (0.5 * sin(t * .pi))
            let radius = 2.4 * smooth(t / 0.14) * pow(1 - t, 0.95)
            // Taper the ink too, so extrusion cannot blunt the pointed end.
            let outline = smooth(t / 0.14) * min(1, (1 - t) / 0.28)
            for circle in Self.pawCircle {
                vertices.append(center + radius * (side * circle.x + up * circle.y))
                outlineWeights.append(outline)
            }
        }
        tail.outlineWeights = outlineWeights
        tail.update(vertices, [topology(rings: rings, sides: sides)])
    }

    private func updateLeg(_ mesh: Surface, crease: Surface, attachment input: [V], wrist: V, bodyCenter: V, running: Float) {
        guard mesh.inputsChanged(input + [wrist, bodyCenter, V(running, 0, 0)]) else { return }
        var p = input
        let center = (p[0] + p[1] + p[2]) / 3
        let axis = simd_normalize(wrist - center)
        if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), axis) < 0 { p.swapAt(1, 2) }
        let first = p[0] - center
        let projected = first - axis * simd_dot(first, axis)
        let u = simd_length_squared(projected) > 1e-8 ? simd_normalize(projected) : simd_normalize(simd_cross(axis, V(0, 0, 1)))
        let v = simd_cross(axis, u)
        let rings = 12, sides = 24
        var vertices: [V] = []
        vertices.reserveCapacity((rings + 1) * sides + 2)
        // Fit a smooth oval to the attachment triangle. Blending its corners
        // directly produced three flat fins, especially visible in night light.
        let radiusU = max(1.5, p.map { abs(simd_dot($0 - center, u)) }.max()!)
        let radiusV = max(1.5, p.map { abs(simd_dot($0 - center, v)) }.max()!)
        let inward = bodyCenter - center
        let buriedRoot = center + inward * min(1, 10 / max(0.001, simd_length(inward)))
        let radial = Self.legCircle.map { u * $0.x + v * $0.y }
        for j in 0...rings {
            // Broad, stretching flanks are part of the running silhouette. A
            // concave cone here leaves the torso reading as an isolated oval.
            let t = Float(j) / Float(rings), weight = pow(1 - t, 1.6 - 0.6 * running)
            for i in 0..<sides {
                let circle = Self.legCircle[i], ring = radial[i]
                let oval = u * (circle.x * radiusU) + v * (circle.y * radiusV)
                vertices.append(buriedRoot + (wrist - buriedRoot) * t + oval * weight + ring * (1.15 * (1 - weight)))
            }
        }
        capVertices(&vertices, sides: sides, rings: rings)
        mesh.outlineWeights = Self.legOutline
        mesh.update(vertices, [topology(rings: rings, sides: sides, capped: true)])
        // Restore the reference's fine front-edge stroke on the actual deforming
        // skin. It is a spatial curve, so the body naturally occludes its root.
        setHidden(crease.node, running < 0.001)
        if !crease.node.isHidden {
            let path = (0...rings).map { j -> V in
                let t = Float(j) / Float(rings), point = vertices[j * sides]
                let radial = point - (buriedRoot + (wrist - buriedRoot) * t)
                let outward = simd_length_squared(radial) > 1e-8 ? simd_normalize(radial) : u
                return point + outward * 0.08
            }
            tube(crease, path: path, radius: 0.45 * running)
        }
    }

    private func paw(_ mesh: Surface, wrist: V, toe: V) {
        guard mesh.inputsChanged([wrist, toe]) else { return }
        let direction = toe - wrist
        let axis = simd_length_squared(direction) > 1e-8 ? simd_normalize(direction) : V(1, 0, 0)
        let width = simd_normalize(abs(axis.y) < 0.9 ? simd_cross(axis, V(0, 1, 0)) : simd_cross(axis, V(0, 0, 1)))
        let thickness = simd_cross(axis, width)
        let rings = 18, sides = Self.pawCircle.count
        var vertices: [V] = []
        vertices.reserveCapacity((rings + 1) * sides)
        for j in 0...rings {
            // Latitude sampling keeps enough rings at the rounded tips.
            let angle = Float(j) / Float(rings) * .pi
            let t = (1 - cos(angle)) * 0.5
            let roundEnd = sin(angle)
            let arch = sin(t * .pi) * 0.35
            let center = wrist + direction * t + V(0, arch, 0)
            // A narrow wrist, soft palm and flattened, rounded toes all deform together.
            let palm = 0.9 + 0.25 * smooth(t * 2)
            for i in 0..<sides {
                let a = Self.pawCircle[i]
                vertices.append(center + roundEnd * (width * (a.x * palm) + thickness * (a.y * 0.78)))
            }
        }
        mesh.update(vertices, [topology(rings: rings, sides: sides)])
    }

    private func tube(_ mesh: Surface, path: [V], radius: Float, flat: Float = 1, closed: Bool = false) {
        guard path.count > 1 else { return }
        guard mesh.inputsChanged(path + [V(radius, flat, closed ? 1 : 0)]) else { return }
        let sides = 10, count = path.count
        var vertices: [V] = []
        vertices.reserveCapacity(count * sides + (closed ? 0 : 2))
        for i in path.indices {
            let prev = path[max(0, i - 1)], next = path[min(count - 1, i + 1)]
            let tangent = simd_length_squared(next - prev) > 1e-8 ? simd_normalize(next - prev) : V(1, 0, 0)
            let u = simd_normalize(abs(tangent.y) < 0.9 ? simd_cross(tangent, V(0, 1, 0)) : simd_cross(tangent, V(0, 0, 1)))
            let v = simd_cross(tangent, u)
            for k in 0..<sides {
                let a = Self.tubeCircle[k]
                vertices.append(path[i] + radius * (u * a.x + v * a.y * flat))
            }
        }
        if !closed { capVertices(&vertices, sides: sides, rings: count - 1) }
        mesh.update(vertices, [topology(rings: count - 1, sides: sides, capped: !closed)])
    }

    private func ear(_ mesh: Surface, rim: Surface, fold: Surface, contour: [V], center: V) {
        guard mesh.inputsChanged(contour) else { return }
        var polygonNormal = V.zero
        for i in contour.indices { polygonNormal += simd_cross(contour[i], contour[(i + 1) % contour.count]) }
        polygonNormal = simd_normalize(polygonNormal)
        let outward = V(0.8, 0, center.z < 0 ? -1 : 1)
        let normal = simd_dot(polygonNormal, outward) >= 0 ? polygonNormal : -polygonNormal
        // Cross-section travels from the recessed inner bowl, over a rolled
        // lip, and back across the curved outer shell: one closed ear volume.
        let profile: [(Float, Float)] = [
            (0, -0.9), (0.18, -1.1), (0.36, -0.8), (0.54, -0.1),
            (0.70, 1.0), (0.83, 2.0), (0.93, 2.65), (0.98, 2.6),
            (1, 2.1), (0.99, 1.5), (0.92, 0.8), (0.78, -0.3),
            (0.58, -1.4), (0.32, -2.1), (0, -2.3)
        ]
        func position(_ p: V, radius: Float, depth: Float) -> V {
            // Upper ear curls more than the root; the bowl sits slightly low.
            let flare = 1 + 0.18 * radius * tanh(p.y / 4)
            let down = V(0, -0.7 * (1 - radius), 0)
            return p * radius + normal * (depth * flare) + down
        }
        var vertices: [V] = []
        let foldEnd = max(2, Int(Float(contour.count - 1) * 0.78))
        func foldRadius(_ t: Float) -> Float { 0.66 + 0.34 * pow(abs(2 * t - 1), 3) }
        mesh.textureCoordinates = []
        for (j, section) in profile.enumerated() {
            for (i, p) in contour.enumerated() {
                let t = min(1, Float(i) / Float(foldEnd))
                // Raise a crescent of cartilage along the upper/front ear.
                // Its inner edge returns to the outer lip at both ends,
                // leaving the lower bowl open rather than drawing an oval.
                let distance = (section.0 - foldRadius(t) - 0.07) / 0.13
                let curl: Float = j < 8 && i <= foldEnd ? 1.25 * sin(t * .pi) * exp(-distance * distance) : 0
                vertices.append(position(p, radius: section.0, depth: section.1 + curl))
                let uv = Float(j) / Float(profile.count - 1)
                mesh.textureCoordinates.append(.init(j < 8 ? uv + curl * 0.055 : uv, 0.5))
            }
        }
        mesh.update(vertices, [topology(rings: profile.count - 1, sides: contour.count,
                                       reversed: simd_dot(polygonNormal, normal) > 0)])
        let edge = contour.map { position($0, radius: 1, depth: 2.1) }
        tube(rim, path: edge + [edge[0]], radius: 0.42, closed: true)
        // Follow the actual sculpted surface, so the cartoon crease remains
        // attached when seen from the side and is occluded from behind.
        let crease = (0...foldEnd).map { i -> V in
            let radius = foldRadius(Float(i) / Float(foldEnd))
            let band = (0..<8).first { profile[$0 + 1].0 >= radius } ?? 7
            let fraction = (radius - profile[band].0) / (profile[band + 1].0 - profile[band].0)
            return vertices[band * contour.count + i] * (1 - fraction)
                + vertices[(band + 1) * contour.count + i] * fraction + normal * 0.13
        }
        tube(fold, path: crease, radius: 0.30)
    }

    private func lens(_ mesh: Surface, contour: [V], depth: Float) {
        guard mesh.inputsChanged(contour + [V(depth, 0, 0)]) else { return }
        let center = contour.reduce(V.zero, +) / Float(contour.count)
        var normal = V.zero
        for i in contour.indices { normal += simd_cross(contour[i] - center, contour[(i + 1) % contour.count] - center) }
        normal = simd_length_squared(normal) > 1e-8 ? simd_normalize(normal) : V(0, 0, 1)
        let sides = contour.count, rings = 10
        var vertices: [V] = []
        vertices.reserveCapacity((rings + 1) * sides)
        for j in 0...rings {
            let t = Float(j) / Float(rings) * .pi
            let r = sin(t), d = cos(t) * depth * 0.5
            for p in contour { vertices.append(center + (p - center) * r + normal * d) }
        }
        mesh.update(vertices, [topology(rings: rings, sides: sides, reversed: true)])
    }
    private func topology(rings: Int, sides: Int, capped: Bool = false, reversed: Bool = false) -> [Int32] {
        let key = Topology(rings: rings, sides: sides, capped: capped, reversed: reversed)
        if let indices = topologyCache[key] { return indices }
        var indices: [Int32] = []
        indices.reserveCapacity((rings + (capped ? 1 : 0)) * sides * 6)
        for j in 0..<rings { for i in 0..<sides {
            let a = Int32(j * sides + i), b = Int32(j * sides + (i + 1) % sides), step = Int32(sides)
            indices.append(contentsOf: [a, b, a + step, b, b + step, a + step])
        } }
        if capped {
            for (cap, row) in [0, rings].enumerated() {
                let center = Int32((rings + 1) * sides + cap)
                for i in 0..<sides {
                    let a = Int32(row * sides + i), b = Int32(row * sides + (i + 1) % sides)
                    indices.append(contentsOf: cap == 0 ? [center, b, a] : [center, a, b])
                }
            }
        }
        if reversed { for i in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(i + 1, i + 2) } }
        topologyCache[key] = indices
        return indices
    }
    private func capVertices(_ vertices: inout [V], sides: Int, rings: Int) {
        for row in [0, rings] {
            let center = vertices[(row * sides)..<((row + 1) * sides)].reduce(V.zero, +) / Float(sides)
            vertices.append(center)
        }
    }
}
