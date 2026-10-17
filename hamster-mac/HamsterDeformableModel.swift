import AppKit
import SceneKit
import simd

/// The original simulation owns every pose and footfall. This mesh only adds volume.
@MainActor final class HamsterDeformableModel {
    typealias V = SIMD3<Float>
    let root = SCNNode()
    private let torso: Surface
    private let limbs: [Surface]
    private let legCreases: [Surface]
    private let paws: [Surface]
    private let features: [Surface]
    private let rims: [Surface]
    private let mouth: [Surface]
    private let tail: Surface
    private let heldFood = SCNNode()
    private var bodyGeneration: UInt32 = 0
    private(set) var landmarks: [V] = []
    private var frame = -1
    private let engine: UnsafeMutableRawPointer

    final class Surface {
        let node = SCNNode()
        private let hull = SCNNode()
        private let materials: [SCNMaterial]
        var textureCoordinates: [CGPoint] = []
        var outlineWeights: [Float] = []
        private let outline: Float
        private var cachedIndices: [[Int32]] = []
        private var elements: [SCNGeometryElement] = []
        init(name: String, materials: [SCNMaterial], ink: SCNMaterial, outline: Float = 0.55, silhouetteOnly: Bool = false) {
            self.materials = materials
            self.outline = outline
            node.name = name
            // Let the skin cover its own expanded outline at concave folds.
            // Other meshes keep their depth, including paws, ears and the wheel.
            if silhouetteOnly { node.renderingOrder = 101; hull.renderingOrder = 100 }
            if outline > 0 {
                hull.name = name + " outline"
                let m = ink.copy() as! SCNMaterial
                m.writesToDepthBuffer = !silhouetteOnly
                m.cullMode = .front
                hull.geometry = SCNGeometry()
                hull.geometry?.materials = materials.map { _ in m }
                node.addChildNode(hull)
            }
        }
        func updateVolume(_ frame: HamsterBodyMesh) {
            guard let vertices = frame.vertices, frame.vertexCount > 0 else { return }
            let count = Int(frame.vertexCount), stride = MemoryLayout<HamsterBodyVertex>.stride
            let data = Data(bytes: vertices, count: count * stride)
            func geometry(_ data: Data) -> SCNGeometry {
                let sources = [
                    SCNGeometrySource(data: data, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                      componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride),
                    SCNGeometrySource(data: data, semantic: .normal, vectorCount: count, usesFloatComponents: true,
                                      componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride),
                    SCNGeometrySource(data: data, semantic: .texcoord, vectorCount: count, usesFloatComponents: true,
                                      componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 24, dataStride: stride)]
                let indices = (0..<count).map(UInt32.init)
                return SCNGeometry(sources: sources, elements: [.init(indices: indices, primitiveType: .triangles)])
            }
            let skin = geometry(data)
            skin.materials = materials
            node.geometry = skin
            if outline > 0 {
                var expanded = Array(UnsafeBufferPointer(start: vertices, count: count))
                for i in expanded.indices {
                    expanded[i].x += expanded[i].nx * outline
                    expanded[i].y += expanded[i].ny * outline
                    expanded[i].z += expanded[i].nz * outline
                }
                let shellData = expanded.withUnsafeBytes { Data($0) }
                let shell = geometry(shellData)
                shell.materials = hull.geometry!.materials
                hull.geometry = shell
            }
        }

        func update(_ points: [V], _ groups: [[Int32]]) {
            guard !points.isEmpty else { return }
            if cachedIndices != groups {
                cachedIndices = groups
                elements = groups.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
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
            func geometry(_ p: [V]) -> SCNGeometry {
                var sources: [SCNGeometrySource] = [.init(vertices: p.map { .init($0.x, $0.y, $0.z) }),
                                                     .init(normals: normals.map { .init($0.x, $0.y, $0.z) })]
                if textureCoordinates.count == p.count { sources.append(.init(textureCoordinates: textureCoordinates)) }
                return SCNGeometry(sources: sources, elements: elements)
            }
            let skin = geometry(points)
            skin.materials = materials
            node.geometry = skin
            if outline > 0 {
                let m = hull.geometry!.materials
                let expanded = points.indices.map { i in points[i] + normals[i] * outline * (outlineWeights.count == points.count ? outlineWeights[i] : 1) }
                let shell = geometry(expanded)
                shell.materials = m
                hull.geometry = shell
            }
        }
    }

    init(engine: UnsafeMutableRawPointer, colors: [String: NSColor]) {
        self.engine = engine
        func mat(_ key: String, constant: Bool = false) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = colors[key] ?? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.10, alpha: 1)
            m.ambient.contents = m.diffuse.contents
            m.lightingModel = constant ? .constant : .lambert
            m.specular.contents = NSColor.black
            return m
        }
        let bodyM = mat("bodyColor"), inkM = mat("ink", constant: true)
        let coat = bodyM.copy() as! SCNMaterial
        let texture = Self.coatTexture(body: colors["bodyColor"]!, cream: colors["snoutColor"]!)
        coat.diffuse.contents = texture
        coat.ambient.contents = texture
        coat.diffuse.magnificationFilter = .linear
        torso = Surface(name: "Hamster deforming skin", materials: [coat], ink: inkM, outline: 1.30, silhouetteOnly: true)
        limbs = (0..<4).map { Surface(name: ["Right foreleg", "Left foreleg", "Right hindleg", "Left hindleg"][$0], materials: [bodyM], ink: inkM, outline: 0.45) }
        legCreases = (0..<4).map { Surface(name: "Running flank crease \($0)", materials: [inkM], ink: inkM, outline: 0) }
        paws = (0..<4).map { Surface(name: "Deforming paw \($0)", materials: [mat("feetColor")], ink: inkM, outline: 1.25) }
        features = (0..<4).map { Surface(name: ["Right eye", "Left eye", "Right ear", "Left ear"][$0], materials: [mat($0 < 2 ? "eyeColor" : "earColor")], ink: inkM, outline: 0) }
        rims = (0..<2).map { Surface(name: "Black ear rim \($0)", materials: [inkM], ink: inkM, outline: 0) }
        mouth = (0..<3).map { Surface(name: "Mouth stroke \($0)", materials: [inkM], ink: inkM, outline: 0) }
        tail = Surface(name: "Small flexible tail", materials: [mat("tailColor")], ink: inkM, outline: 0.45)
        root.name = "Original hamster articulation"
        for mesh in [torso, tail] + limbs + legCreases + paws + features + rims + mouth { root.addChildNode(mesh.node) }
        let pellet = SCNSphere(radius: 3)
        pellet.segmentCount = 20
        pellet.materials = [mat("foodColor")]
        heldFood.geometry = pellet
        heldFood.name = "Food between original hands"
        root.addChildNode(heldFood)
        update(force: true)
    }

    private func smooth(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
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
        let volume = HamsterEngineBuildBodyMesh(engine)
        if force || volume.generation != bodyGeneration {
            torso.updateVolume(volume)
            bodyGeneration = volume.generation
        }
        let running = state.onWheel != 0 ? smooth(Float((state.speed - 0.15) / 0.65)) : 0
        let torsoAxis = simd_normalize(landmarks[1] - rear)
        let torsoCenter = (landmarks[1] + rear) * 0.5
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
            updateLeg(limbs[leg], crease: legCreases[leg], attachment: attachment, wrist: p[3], running: running)
            paw(paws[leg], wrist: p[3], toe: p[4])
        }
        for feature in 0..<4 {
            let count = Int(HamsterEngineGetRigFeatureCount(engine, Int32(feature)))
            let control = (0..<count).map { HamsterEngineGetRigFeaturePoint(engine, Int32(feature), Int32($0)) }
            var contour: [V] = []
            func vec(_ p: HamsterRigPoint) -> V { .init(Float(p.x), Float(p.y), Float(p.z)) }
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
                    if simd_dot(normal, center - head) < 0 { normal = -normal }
                    contour = contour.map { $0 + normal * 0.8 }
                }
                lens(features[feature], contour: contour, depth: feature < 2 ? 0.7 : 1.5)
                if feature >= 2 { tube(rims[feature - 2], path: contour + [contour[0]], radius: 0.48, closed: true) }
            }
        }
        let nose = headPoint(.init(35, 2, 0), state: state, center: head)
        let chin = headPoint(.init(33, 9, 0), state: state, center: head)
        let left = headPoint(.init(32, 1, -3), state: state, center: head)
        let right = headPoint(.init(32, 1, 3), state: state, center: head)
        tube(mouth[0], path: [left, nose, right], radius: 0.38)
        tube(mouth[1], path: [nose, chin], radius: 0.35)
        mouth[2].node.isHidden = true
        let t = landmarks[3], tailDirection = simd_normalize(t - rear)
        tube(tail, path: [t - tailDirection * 1.5, t, t + tailDirection * 3.5], radius: 2.2, flat: 0.7)
        heldFood.isHidden = state.eating == 0
        heldFood.simdPosition = (landmarks[8] + landmarks[13]) * 0.5
    }

    private func updateLeg(_ mesh: Surface, crease: Surface, attachment input: [V], wrist: V, running: Float) {
        var p = input
        let center = (p[0] + p[1] + p[2]) / 3
        let axis = simd_normalize(wrist - center)
        if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), axis) < 0 { p.swapAt(1, 2) }
        let first = p[0] - center
        let projected = first - axis * simd_dot(first, axis)
        let u = simd_length_squared(projected) > 1e-8 ? simd_normalize(projected) : simd_normalize(simd_cross(axis, V(0, 0, 1)))
        let v = simd_cross(axis, u)
        let rings = 12, sides = 24
        var vertices: [V] = [], indices: [Int32] = []
        for j in 0...rings {
            // Broad, stretching flanks are part of the running silhouette. A
            // concave cone here leaves the torso reading as an isolated oval.
            let t = Float(j) / Float(rings), weight = pow(1 - t, 1.6 - 0.6 * running)
            for i in 0..<sides {
                let a = Float(i) / Float(sides) * 2 * .pi
                var q = V.zero
                var total: Float = 0
                for k in 0..<3 {
                    let weight = pow(max(0, cos(a - Float(k) * 2 * .pi / 3)), 2)
                    q += p[k] * weight
                    total += weight
                }
                q /= max(0.001, total)
                let ring = u * cos(a) + v * sin(a)
                vertices.append(center + (wrist - center) * t + (q - center) * weight + ring * (1.15 * (1 - weight)))
            }
        }
        connect(rings: rings, sides: sides, indices: &indices)
        cap(&vertices, &indices, sides: sides, rings: rings)
        mesh.outlineWeights = (0...rings).flatMap { j in Array(repeating: smooth((Float(j) / Float(rings) - 0.35) / 0.65), count: sides) } + [0, 1]
        mesh.update(vertices, [indices])
        // Restore the reference's fine front-edge stroke on the actual deforming
        // skin. It is a spatial curve, so the body naturally occludes its root.
        crease.node.isHidden = running < 0.001
        if !crease.node.isHidden {
            let path = (0...rings).map { j -> V in
                let t = Float(j) / Float(rings), point = vertices[j * sides]
                let radial = point - (center + (wrist - center) * t)
                let outward = simd_length_squared(radial) > 1e-8 ? simd_normalize(radial) : u
                return point + outward * 0.08
            }
            tube(crease, path: path, radius: 0.45 * running)
        }
    }

    private func paw(_ mesh: Surface, wrist: V, toe: V) {
        let direction = toe - wrist
        let axis = simd_length_squared(direction) > 1e-8 ? simd_normalize(direction) : V(1, 0, 0)
        let width = simd_normalize(abs(axis.y) < 0.9 ? simd_cross(axis, V(0, 1, 0)) : simd_cross(axis, V(0, 0, 1)))
        let thickness = simd_cross(axis, width)
        let rings = 14, sides = 12
        var vertices: [V] = [], indices: [Int32] = []
        for j in 0...rings {
            let t = Float(j) / Float(rings)
            let roundEnd = sqrt(max(0, 1 - pow(2 * t - 1, 2)))
            let arch = sin(t * .pi) * 0.35
            let center = wrist + direction * t + V(0, arch, 0)
            // A narrow wrist, soft palm and flattened, rounded toes all deform together.
            let palm = 0.9 + 0.25 * smooth(t * 2)
            for i in 0..<sides {
                let a = Float(i) / Float(sides) * 2 * .pi
                vertices.append(center + roundEnd * (width * (cos(a) * palm) + thickness * (sin(a) * 0.78)))
            }
        }
        connect(rings: rings, sides: sides, indices: &indices)
        mesh.update(vertices, [indices])
    }

    private func tube(_ mesh: Surface, path: [V], radius: Float, flat: Float = 1, closed: Bool = false) {
        guard path.count > 1 else { return }
        let sides = 10, count = path.count
        var vertices: [V] = [], indices: [Int32] = []
        for i in path.indices {
            let prev = path[max(0, i - 1)], next = path[min(count - 1, i + 1)]
            let tangent = simd_length_squared(next - prev) > 1e-8 ? simd_normalize(next - prev) : V(1, 0, 0)
            let u = simd_normalize(abs(tangent.y) < 0.9 ? simd_cross(tangent, V(0, 1, 0)) : simd_cross(tangent, V(0, 0, 1)))
            let v = simd_cross(tangent, u)
            for k in 0..<sides {
                let a = Float(k) / Float(sides) * 2 * .pi
                vertices.append(path[i] + radius * (u * cos(a) + v * sin(a) * flat))
            }
        }
        connect(rings: count - 1, sides: sides, indices: &indices)
        if !closed { cap(&vertices, &indices, sides: sides, rings: count - 1) }
        mesh.update(vertices, [indices])
    }

    private func lens(_ mesh: Surface, contour: [V], depth: Float) {
        let center = contour.reduce(V.zero, +) / Float(contour.count)
        var normal = V.zero
        for i in contour.indices { normal += simd_cross(contour[i] - center, contour[(i + 1) % contour.count] - center) }
        normal = simd_length_squared(normal) > 1e-8 ? simd_normalize(normal) : V(0, 0, 1)
        let sides = contour.count, rings = 10
        var vertices: [V] = [], indices: [Int32] = []
        for j in 0...rings {
            let t = Float(j) / Float(rings) * .pi
            let r = sin(t), d = cos(t) * depth * 0.5
            for p in contour { vertices.append(center + (p - center) * r + normal * d) }
        }
        connect(rings: rings, sides: sides, indices: &indices)
        for i in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(i + 1, i + 2) }
        mesh.update(vertices, [indices])
    }
    private func connect(rings: Int, sides: Int, indices: inout [Int32]) {
        for j in 0..<rings { for i in 0..<sides {
            let a = Int32(j * sides + i), b = Int32(j * sides + (i + 1) % sides), step = Int32(sides)
            indices += [a, b, a + step, b, b + step, a + step]
        } }
    }
    private func cap(_ vertices: inout [V], _ indices: inout [Int32], sides: Int, rings: Int) {
        for (row, reverse) in [(0, true), (rings, false)] {
            let center = vertices[(row * sides)..<((row + 1) * sides)].reduce(V.zero, +) / Float(sides)
            let index = Int32(vertices.count)
            vertices.append(center)
            for i in 0..<sides {
                let a = Int32(row * sides + i), b = Int32(row * sides + (i + 1) % sides)
                indices += reverse ? [index, b, a] : [index, a, b]
            }
        }
    }
}
