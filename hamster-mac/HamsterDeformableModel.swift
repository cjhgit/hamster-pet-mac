import AppKit
import SceneKit
import simd
import Metal

/// The original simulation owns every pose and footfall. This mesh only adds volume.
@MainActor final class HamsterDeformableModel {
    typealias V = SIMD3<Float>
    let root = SCNNode()
    private let skinRoot = SCNNode()
    private let skeletonRoot = SCNNode()
    private var boneNodes: [(rod: SCNNode, joint: SCNNode)] = []
    private(set) var skeletonSegments: [[V]] = []
    private var skeletonJointFlags: [Bool] = []
    var showsSkeleton = false {
        didSet {
            skinRoot.isHidden = showsSkeleton
            skeletonRoot.isHidden = !showsSkeleton
            if showsSkeleton { updateSkeletonGeometry() }
            nodeRevision += 1
        }
    }
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
    private let earPivots = [SCNNode(), SCNNode()]
    private var earActivity: Float = 1
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

    private var bodyContactCache: (generation: UInt32, rotation: Float, height: Float)?

    private func bodyContactHeight(rotation: Float) -> Float {
        let generation = HamsterEngineBuildBodyField(engine).generation
        if let cached = bodyContactCache, cached.generation == generation, cached.rotation == rotation { return cached.height }
        let height = Float(HamsterEngineGetBodyContactHeight(engine, Double(rotation)))
        bodyContactCache = (generation, rotation, height)
        return height
    }

    private(set) var groundedOriginHeight: Float = 0
    private var lastGroundLift: Float = -1
    private var sleepTuck: Float = 0

    /// Authored CPU vertices and normal-expanded outlines, matching the submitted
    /// limb buffers. Exposed for frame-by-frame ground-contact verification.
    private var restingPaws: [[V]] = []
    private(set) var restingBones: [[V]] = []
    var pawVerticesForInspection: [[V]] { restingPaws.isEmpty ? paws.map { $0.batchPoints } : restingPaws }
    var limbVerticesForInspection: [[V]] { limbs.map { $0.batchPoints } }
    var limbSilhouettesForInspection: [[V]] {
        limbs.map { surface in
            surface.batchPoints.enumerated().flatMap { i, p in
                [p, p + surface.batchNormals[i] * surface.batchOutlineWeight(i)]
            }
        }
    }

    var groundVerticesForInspection: [V] {
        ([tail] + limbs + legCreases + paws + mouth).filter { !$0.node.isHidden }.flatMap { surface in
            surface.batchPoints.enumerated().flatMap { i, p in
                [p, p + surface.batchNormals[i] * surface.batchOutlineWeight(i)]
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
        private var authoredPoints: [V] = []
        private var contactPlane: SIMD4<Float>?
        func setContactPlane(_ plane: SIMD4<Float>?) {
            guard plane != contactPlane else { return }
            contactPlane = plane
            if !authoredPoints.isEmpty { update(authoredPoints, cachedIndices) }
        }
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

        func update(_ input: [V], _ groups: [[Int32]]) {
            guard !input.isEmpty else { return }
            authoredPoints = input
            let points: [V]
            if let plane = contactPlane {
                let up = V(plane.x, plane.y, plane.z)
                points = input.enumerated().map { i, p in
                    // Reserve the actual outline width too, so its displaced
                    // vertices cannot cross the floor between animation frames.
                    p + up * max(0, plane.w + batchOutlineWeight(i) - simd_dot(p, up))
                }
            } else { points = input }
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
            batchNormals = normals
            if usesBatch {
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
        paws = (0..<4).map { Surface(name: "Deforming paw \($0)", materials: [bodyM], ink: inkM, outline: 1.00, weightedOutline: true) }
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
        var allSurfaces = [torso, tail]
        allSurfaces += limbs
        allSurfaces += legCreases
        allSurfaces += paws
        allSurfaces += features
        allSurfaces += rims
        allSurfaces += earFolds
        allSurfaces += mouth
        surfaces = allSurfaces
        mouth[2].node.isHidden = true
        skinRoot.name = "Hamster skin"
        skeletonRoot.name = "Hamster pose skeleton"
        skeletonRoot.isHidden = true
        root.addChildNode(skinRoot)
        root.addChildNode(skeletonRoot)
        skinRoot.addChildNode(torso.node)
        var dynamicParts = [tail]
        dynamicParts += limbs
        dynamicParts += legCreases
        dynamicParts += paws
        dynamicParts += mouth
        if !ProcessInfo.processInfo.arguments.contains("--hamster-unbatched") {
            for mesh in dynamicParts { mesh.enableBatch() }
            let batch = MovingPartsBatch(parts: dynamicParts, ink: inkM, device: device)
            movingParts = batch
            skinRoot.addChildNode(batch.node)
        } else {
            for mesh in dynamicParts { skinRoot.addChildNode(mesh.node) }
        }
        headFeatures.name = "Rigid head features"
        skinRoot.addChildNode(headFeatures)
        for mesh in features.prefix(2) { headFeatures.addChildNode(mesh.node) }
        for i in 0..<2 {
            earPivots[i].name = "Ear root \(i)"
            headFeatures.addChildNode(earPivots[i])
            for mesh in [features[i + 2], rims[i], earFolds[i]] {
                earPivots[i].addChildNode(mesh.node)
            }
        }
        let pellet = SCNSphere(radius: 3)
        pellet.segmentCount = 20
        pellet.materials = [mat("foodColor")]
        heldFood.geometry = pellet
        heldFood.name = "Food between original hands"
        skinRoot.addChildNode(heldFood)
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

    /// Driven by simulation frames, never wall time: pause and single-step
    /// apply equally to skin, ear rims and the debugging skeleton.
    private func earOrientation(index: Int, state: HamsterSceneState) -> simd_quatf {
        let time = Float(frame) / 30
        let offset: Float = index == 0 ? 1.1 : 3.4
        let period: Float = index == 0 ? 6.2 : 7.7
        let phase = (time + offset).truncatingRemainder(dividingBy: period)
        func flick(_ start: Float, _ duration: Float) -> Float {
            let t = (phase - start) / duration
            guard t > 0 && t < 1 else { return 0 }
            let envelope = sin(t * .pi)
            return envelope * envelope * sin(t * 2 * .pi)
        }
        let twitch = 0.48 * flick(0, 0.46) + 0.18 * flick(0.64, 0.3)
        let stride = state.moving != 0 ? sin(Float(state.legPhase) + offset) * 0.045 * Float(min(1, abs(state.speed))) : 0
        let angle = earActivity * (twitch + stride + 0.025 * sin(time * 0.8 + offset))
        let side: Float = index == 0 ? 1 : -1
        let tilt = simd_quatf(angle: angle, axis: simd_normalize(V(side * 0.45, 0, 1)))
        let turn = simd_quatf(angle: angle * side * 0.35, axis: V(0, 1, 0))
        return tilt * turn
    }

    func update(force: Bool = false, groundLift: Float = 0) {
        let current = Int(HamsterEngineGetFrameCount(engine))
        guard force || current != frame || groundLift != lastGroundLift else { return }
        let elapsedFrames = max(0, current - frame)
        frame = current
        lastGroundLift = groundLift
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
        let resting = state.sleeping != 0 || state.preparingSleep != 0
        let rotation = Float(-state.rotation * .pi / 180)
        groundedOriginHeight = Float(210 - state.y) + groundLift
        if resting && state.onWheel == 0 {
            // The body rests on the floor itself. The cushion is decorative and
            // may intersect the sleeping body; it never adds a vertical offset.
            groundedOriginHeight = 0.5 - bodyContactHeight(rotation: rotation) + 0.55
        }
        let contactPlane: SIMD4<Float>? = state.onWheel == 0
            ? .init(sin(rotation), cos(rotation), 0, 0.5 - groundedOriginHeight) : nil
        for surface in [tail] + limbs + legCreases + paws + mouth { surface.setContactPlane(contactPlane) }
        let tuckTarget: Float = resting ? 1 : 0
        let tuckStep = Float(elapsedFrames) / 8
        sleepTuck += max(-tuckStep, min(tuckStep, tuckTarget - sleepTuck))
        let tuck = smooth(sleepTuck)
        let side = V(sin(Float(state.heading)), 0, -cos(Float(state.heading)))
        restingPaws = []; restingBones = []
        // These controls also drive the skin below. No second simulation or
        // skeleton-only IK is allowed: debugging must expose the rendered pose.
        skeletonSegments = [[rear, landmarks[1]], [landmarks[1], head]]
        skeletonJointFlags = [true, true]
        var shoulderConnections: [[V]] = []
        let forward = simd_normalize(V(cos(Float(state.heading)), 0, sin(Float(state.heading))))
        for leg in 0..<4 {
            let offset = 4 + leg * 5
            let p = Array(landmarks[offset..<(offset + 5)])
            let attachment = p[0...2].map { point in
                let ventral = smooth(simd_dot(point - torsoCenter, bodyDown) / 8)
                return point - bodyDown * (leg >= 2 ? 3.5 * running * ventral : 0)
            }
            shoulderConnections.append([leg < 2 ? landmarks[1] : rear, attachment.reduce(V.zero, +) / 3])
            setHidden(paws[leg].node, tuck > 0)
            if tuck > 0 {
                let front = leg < 2
                // Keep the original shoulder/hip attachment, not a relocated
                // triangle on the floor. Rotate a fixed-length two-bone chain.
                let root = attachment.reduce(V.zero, +) / 3
                let sign: Float = simd_dot(root - torsoCenter, side) >= 0 ? 1 : -1
                var ankle = root + forward * (front ? 6 : -4) + side * (sign * (front ? 3 : 4))
                ankle.y = 0.5 - groundedOriginHeight + 1.85
                let bend = front ? -forward + V(0, 0.15, 0) : forward + side * (sign * 0.1)
                let solved = foldedJoint(root: root, target: ankle, bend: bend,
                                         upper: front ? 10 : 13, lower: front ? 9 : 13)
                ankle = solved.ankle
                let joint = solved.joint
                let toe = ankle + forward * (front ? 3 : 12)
                let posedAnkle = p[3] + (ankle - p[3]) * tuck
                let posedToe = p[4] + (toe - p[4]) * tuck
                let straightJoint = root + (p[3] - root) * 0.5
                let posedJoint = straightJoint + (joint - straightJoint) * tuck
                restingBones.append([root, posedJoint, posedAnkle, posedToe])
                appendSkeletonChain([root, posedJoint, posedAnkle, posedToe])
                restingPaws.append(updateRestingLeg(limbs[leg], attachment: attachment,
                    joint: posedJoint, ankle: posedAnkle, toe: posedToe,
                    bodyCenter: torsoCenter, side: side, front: front))
                setHidden(legCreases[leg].node, true)
            } else {
                // The original gait has attachment, wrist and toe controls;
                // do not invent an elbow with a separate animation here.
                appendSkeletonChain([attachment.reduce(V.zero, +) / 3, p[3], p[4]])
                updateLeg(limbs[leg], crease: legCreases[leg], attachment: attachment,
                          wrist: p[3], bodyCenter: torsoCenter, running: running, tucked: 0)
                paw(paws[leg], wrist: p[3], toe: p[4], tucked: 0)
            }
        }
        for connection in shoulderConnections { appendSkeletonChain(connection) }
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
        let earTarget: Float = resting ? 0 : state.petting != 0 ? 0.25 : 1
        earActivity += (earTarget - earActivity) * min(1, Float(elapsedFrames) / 8)
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
                if feature < 2 { setPosition(features[feature].node, center) }
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
                    let index = feature - 2
                    let bottom = contour.map(\.y).min()!, top = contour.map(\.y).max()!
                    let base = contour.filter { $0.y <= bottom + (top - bottom) * 0.22 }
                    let root = base.reduce(V.zero, +) / Float(base.count)
                    let tip = contour.max { $0.y < $1.y }!
                    let pivot = earPivots[index]
                    setPosition(pivot, root)
                    let earRotation = earOrientation(index: index, state: state)
                    if simd_length_squared(pivot.simdOrientation.vector - earRotation.vector) > 1e-12 {
                        pivot.simdOrientation = earRotation
                        nodeRevision += 1
                    }
                    // Rotate the complete ear around its buried base, keeping
                    // cartilage, black rim and inner fold attached together.
                    for mesh in [features[feature], rims[index], earFolds[index]] {
                        setPosition(mesh.node, center - root)
                    }
                    let posedRoot = head + orientation.act(root)
                    let posedTip = head + orientation.act(root + earRotation.act(tip - root))
                    appendSkeletonChain([head, posedRoot, posedTip])
                }
            }
        }
        // Keep the short mouth seam against the rounded muzzle instead of
        // extending below the skin and reading as a protruding lower jaw.
        let nose = headPoint(.init(35, 2, 0), state: state, center: head)
        let chin = headPoint(.init(33, 5.9, 0), state: state, center: head)
        let left = headPoint(.init(32, 1, -3), state: state, center: head)
        let right = headPoint(.init(32, 1, 3), state: state, center: head)
        tube(mouth[0], path: [left, nose, right], radius: 0.38)
        tube(mouth[1], path: [nose, chin], radius: 0.35)
        // Skull guides follow exactly the same rigid head transform as the
        // muzzle. Their shape is a guide, rather than an independent head rig.
        for vertical in [false, true] {
            let ring = (0...12).map { i -> V in
                let angle = Float(i) / 12 * 2 * .pi
                let local = vertical ? V(10 + 22 * cos(angle), 13 * sin(angle), 0)
                                     : V(10 + 22 * cos(angle), 0, 13 * sin(angle))
                return headPoint(local, state: state, center: head)
            }
            appendSkeletonChain(ring, joints: false)
        }
        updateTail(rear: rear, bodyAxis: torsoAxis, bodyDown: bodyDown)
        if showsSkeleton { updateSkeletonGeometry() }
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

    private func appendSkeletonChain(_ points: [V], joints: Bool = true) {
        for i in 1..<points.count {
            skeletonSegments.append([points[i - 1], points[i]])
            skeletonJointFlags.append(joints)
        }
    }

    private func updateSkeletonGeometry() {
        while boneNodes.count < skeletonSegments.count {
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.61, alpha: 1)
            let cylinder = SCNCylinder(radius: 1.05, height: 1)
            cylinder.radialSegmentCount = 8
            cylinder.materials = [material]
            let rod = SCNNode(geometry: cylinder)
            rod.name = "Pose bone \(boneNodes.count)"
            let jointMaterial = SCNMaterial()
            jointMaterial.diffuse.contents = NSColor(calibratedRed: 0.86, green: 0.36, blue: 0.12, alpha: 1)
            let sphere = SCNSphere(radius: 1.65)
            sphere.segmentCount = 8
            sphere.materials = [jointMaterial]
            let joint = SCNNode(geometry: sphere)
            joint.name = "Pose joint \(boneNodes.count)"
            skeletonRoot.addChildNode(rod)
            skeletonRoot.addChildNode(joint)
            boneNodes.append((rod, joint))
        }
        for (i, nodes) in boneNodes.enumerated() {
            let active = i < skeletonSegments.count
            nodes.rod.isHidden = !active
            nodes.joint.isHidden = !active || !skeletonJointFlags[i]
            guard active else { continue }
            let a = skeletonSegments[i][0], b = skeletonSegments[i][1]
            let length = simd_distance(a, b)
            nodes.rod.simdPosition = (a + b) * 0.5
            nodes.rod.simdScale = V(skeletonJointFlags[i] ? 1 : 0.6, max(0.001, length), skeletonJointFlags[i] ? 1 : 0.6)
            nodes.rod.simdOrientation = length > 0.0001
                ? simd_quatf(from: V(0, 1, 0), to: (b - a) / length) : simd_quatf()
            nodes.joint.simdPosition = b
        }
        nodeRevision += 1
    }

    private func updateTail(rear: V, bodyAxis: V, bodyDown: V) {

        // Anchor inside the rounded pelvis instead of extending the old 2D
        // tail marker, which can sit below the new volumetric rump.
        let root = rear - bodyAxis * 15 - bodyDown * 3
        let axis = simd_normalize(-bodyAxis - bodyDown * 0.35)
        appendSkeletonChain([rear, root], joints: false)
        appendSkeletonChain((0...4).map { i in
            let t = Float(i) / 4
            return root + axis * (10 * t) - bodyDown * (0.5 * sin(t * .pi))
        }, joints: false)
        guard tail.inputsChanged([rear, bodyAxis, bodyDown]) else { return }
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

    private func foldedJoint(root: V, target: V, bend: V, upper: Float, lower: Float) -> (joint: V, ankle: V) {
        let delta = target - root
        let distance = max(0.001, simd_length(delta))
        let direction = delta / distance
        let reach = min(upper + lower - 0.01, max(abs(upper - lower) + 0.01, distance))
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let height = sqrt(max(0, upper * upper - along * along))
        let projected = bend - direction * simd_dot(bend, direction)
        let pole = simd_normalize(projected)
        return (root + direction * along + pole * height, root + direction * reach)
    }

    /// One continuous skin from the buried muscle root through elbow/knee,
    /// wrist/ankle and toes. No separate caps or detached oval at the wrist.
    private func updateRestingLeg(_ mesh: Surface, attachment: [V], joint: V, ankle: V, toe: V,
                                  bodyCenter: V, side: V, front: Bool) -> [V] {
        let ringsPerBone = 12, sides = 24, rings = ringsPerBone * 3
        let pawStart = ringsPerBone * 2 * sides
        if mesh.inputsChanged(attachment + [joint, ankle, toe, bodyCenter]) {
            let root = attachment.reduce(V.zero, +) / 3
            let inward = bodyCenter - root
            let buriedRoot = root + inward * min(1, 8 / max(0.001, simd_length(inward)))
            let knots = [buriedRoot, joint, ankle, toe]
            let rootRadius = max(front ? 6 : 9, attachment.map { simd_distance($0, root) }.max()! * 0.7)
            let jointRadius: Float = front ? 2.8 : 4.2
            func curve(_ segment: Int, _ t: Float) -> V {
                let p0 = knots[max(0, segment - 1)], p1 = knots[segment]
                let p2 = knots[segment + 1], p3 = knots[min(3, segment + 2)]
                let t2 = t * t, t3 = t2 * t
                let start = p1 * 2 + (p2 - p0) * t
                let mid = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let end = (-p0 + p1 * 3 - p2 * 3 + p3) * t3
                return (start + mid + end) * 0.5
            }
            var points: [V] = [], weights: [Float] = []
            for j in 0...rings {
                let segment = min(2, j / ringsPerBone)
                let t = Float(j - segment * ringsPerBone) / Float(ringsPerBone)
                let center = curve(segment, t)
                let tangent = simd_normalize(curve(segment, min(1, t + 0.01)) - curve(segment, max(0, t - 0.01)))
                let projected = side - tangent * simd_dot(side, tangent)
                let u = simd_normalize(projected), v = simd_normalize(simd_cross(tangent, u))
                var width: Float, thickness: Float
                if segment == 0 {
                    width = rootRadius + (jointRadius - rootRadius) * smooth(t)
                    thickness = width
                } else if segment == 1 {
                    width = jointRadius + (1.5 - jointRadius) * smooth(t)
                    thickness = width
                } else {
                    let end = sqrt(max(0.0001, 1 - t * t))
                    width = (1.5 + 0.2 * sin(t * .pi)) * end
                    thickness = (1.5 - 0.75 * smooth(t / 0.4)) * end
                }
                for i in 0..<sides {
                    let a = Float(i) * 2 * .pi / Float(sides)
                    points.append(center + u * (cos(a) * width) + v * (sin(a) * thickness))
                    weights.append(smooth(Float(j) / Float(ringsPerBone) / 0.4))
                }
            }
            capVertices(&points, sides: sides, rings: rings)
            weights += [0, 1]
            mesh.outlineWeights = weights
            mesh.update(points, [topology(rings: rings, sides: sides, capped: true)])
        }
        return Array(mesh.batchPoints[pawStart..<min(mesh.batchPoints.count, (rings + 1) * sides)])
    }

    private func updateLeg(_ mesh: Surface, crease: Surface, attachment input: [V], wrist: V, bodyCenter: V, running: Float, tucked: Float) {
        guard mesh.inputsChanged(input + [wrist, bodyCenter, V(running, tucked, 0)]) else { return }
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
        var inward = bodyCenter - center
        // A resting leg is laid along the ground, including its buried root.
        // Pulling that root upward made the exposed forearm a standing strut.
        inward.y *= 1 - tucked
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

    private func paw(_ mesh: Surface, wrist: V, toe: V, tucked: Float) {
        guard mesh.inputsChanged([wrist, toe, V(tucked, 0, 0)]) else { return }
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
            let arch = sin(t * .pi) * (0.35 - 0.27 * tucked)
            let center = wrist + direction * t + V(0, arch, 0)
            // A narrow wrist, soft palm and flattened, rounded toes all deform together.
            let palm = 0.9 + 0.25 * smooth(t * 2) + 0.25 * tucked
            for i in 0..<sides {
                let a = Self.pawCircle[i]
                vertices.append(center + roundEnd * (width * (a.x * palm) + thickness * (a.y * 0.78)))
            }
        }
        mesh.outlineWeights = Array(repeating: 1, count: vertices.count)
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
