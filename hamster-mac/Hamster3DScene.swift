import AppKit
import SceneKit
import simd
import Metal
import MetalKit

/// All visible objects are closed, shaded meshes in world space. No sprites or billboards.
/// Units match the original 280 × 210 scene; +Y is up and the hamster faces +Z locally.
@MainActor final class Hamster3DScene {
    let scene = SCNScene()
    let view = Hamster3DRenderView()
    let camera = SCNNode()
    let hamster = SCNNode()
    private var model: HamsterDeformableModel!
    private let wheel = SCNNode()
    private let lamp = SCNNode()
    private let bulbLight = SCNNode()
    private let ambient = SCNNode()
    private let keyLight = SCNNode()
    private var foods: [SCNNode] = []
    private var palette: [String: NSColor] = [:]
    private struct MaterialKey: Hashable { let rgba: SIMD4<Double>; let unlit: Bool; let cull: Int }
    private var materialCache: [MaterialKey: SCNMaterial] = [:]
    private let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.08, alpha: 1)
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0
    private(set) var zoom: Float = 1
    private var target = SIMD3<Float>(0, 105, 0)
    private var night: Bool?
    private var follow = false
    private var hamsterDepth: Float = 42
    private var lastPoseFrame: Int?
    private let engine: UnsafeMutableRawPointer

    init(engine: UnsafeMutableRawPointer) {
        self.engine = engine
        for name in ["bgColor", "bodyColor", "earColor", "snoutColor", "eyeColor", "feetColor", "tailColor", "waterColor", "foodColor", "wheelColor", "wheelOuterColor", "wheelCenterColor", "wheelSpokeColor"] {
            let hex = name.withCString { HamsterEngineGetSceneColor(engine, $0) }
            palette[name] = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                    green: CGFloat((hex >> 8) & 255) / 255,
                                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        scene.background.contents = color("bgColor")
        view.scene = scene
        view.backgroundColor = color("bgColor")
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        camera.name = "Orbit camera"
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 2500
        camera.camera?.wantsHDR = false
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        ambient.name = "Ambient fill"
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 780
        scene.rootNode.addChildNode(ambient)
        keyLight.name = "Daylight"
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 520
        keyLight.eulerAngles = SCNVector3(-0.7, -0.5, 0)
        scene.rootNode.addChildNode(keyLight)
        buildHabitat()
        buildWheel()
        buildBottle()
        buildLamp()
        buildHamster()
        update(night: false)
        yaw = -0.18
        pitch = 0.08
        updateCamera()
    }

    private func color(_ key: String) -> NSColor { palette[key] ?? .white }
    private func material(_ color: NSColor, unlit: Bool = false, cull: SCNCullMode = .back) -> SCNMaterial {
        let rgb = color.usingColorSpace(.extendedSRGB)!
        let key = MaterialKey(rgba: .init(rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent), unlit: unlit, cull: cull.rawValue)
        if let existing = materialCache[key] { return existing }
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = unlit ? .constant : .lambert
        m.ambient.contents = color
        m.specular.contents = NSColor.black
        m.roughness.contents = 0.95
        m.cullMode = cull
        materialCache[key] = m
        return m
    }

    private func flattenGeometry(in parent: SCNNode, excluding: [SCNNode] = []) {
        guard !CommandLine.arguments.contains("--hamster-unflattened") else { return }
        func hasOutline(_ node: SCNNode) -> Bool {
            node.geometry?.materials.contains(where: { $0.cullMode == .front }) == true || node.childNodes.contains(where: hasOutline)
        }
        // SceneKit's flattening changes inverted-hull ordering when an outline
        // and its covered skin share the combined geometry. Keep those solid
        // objects intact, and batch only ordinary back-face-culled geometry.
        let children = parent.childNodes.filter { child in
            child.light == nil && !excluding.contains(where: { $0 === child }) && !hasOutline(child)
        }
        guard children.count > 1 else { return }
        let group = SCNNode()
        // Use an identity temporary root: bake only local child transforms,
        // retaining the parent's animation and independently controlled lights.
        for child in children { group.addChildNode(child) }
        let flattened = group.flattenedClone()
        flattened.name = "\(parent.name ?? "Scene") combined static geometry"
        parent.addChildNode(flattened)
    }

    @discardableResult private func mesh(_ geometry: SCNGeometry, color: NSColor, name: String,
                                         parent: SCNNode, at position: SCNVector3 = SCNVector3Zero,
                                         outline: Float = 0) -> SCNNode {
        geometry.materials = [material(color)]
        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = position
        parent.addChildNode(node)
        if outline > 0 {
            // Inverted hull: real back-facing geometry, so silhouettes work at every camera angle.
            let hullGeometry = geometry.copy() as! SCNGeometry
            let hullMaterial = material(ink, unlit: true, cull: .front)
            hullGeometry.materials = [hullMaterial]
            let hull = SCNNode(geometry: hullGeometry)
            hull.name = "\(name) · outline"
            hull.scale = SCNVector3(1 + outline, 1 + outline, 1 + outline)
            node.addChildNode(hull)
        }
        return node
    }

    @discardableResult private func ellipsoid(_ radii: SCNVector3, color: NSColor, name: String,
                                               parent: SCNNode, at position: SCNVector3,
                                               outline: Float = 0.04) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 40
        let node = mesh(sphere, color: color, name: name, parent: parent, at: position, outline: outline)
        node.scale = radii
        return node
    }

    @discardableResult private func rod(_ from: SCNVector3, _ to: SCNVector3, radius: CGFloat,
                                       color: NSColor, name: String, parent: SCNNode) -> SCNNode {
        let a = SIMD3<Float>(Float(from.x), Float(from.y), Float(from.z))
        let b = SIMD3<Float>(Float(to.x), Float(to.y), Float(to.z))
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(simd_length(b - a)))
        cylinder.radialSegmentCount = 16
        let node = mesh(cylinder, color: color, name: name, parent: parent)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
        return node
    }

    private func box(_ size: SCNVector3, radius: CGFloat, color: NSColor, name: String,
                     parent: SCNNode, at: SCNVector3, outline: Float = 0.02) -> SCNNode {
        mesh(SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: radius),
             color: color, name: name, parent: parent, at: at, outline: outline)
    }

    private func buildHabitat() {
        let root = SCNNode()
        root.name = "Habitat"
        scene.rootNode.addChildNode(root)
        _ = box(SCNVector3(282, 3, 138), radius: 1.5, color: ink, name: "Habitat base rim", parent: root, at: SCNVector3(0, -2, 0), outline: 0)
        _ = box(SCNVector3(278, 1, 134), radius: 0.4, color: color("bgColor"), name: "Habitat floor", parent: root, at: SCNVector3(0, 0, 0), outline: 0)
        // A closed, extruded rounded frame preserves the original silhouette.
        let framePath = NSBezierPath(roundedRect: .init(x: -141, y: -1, width: 282, height: 212), xRadius: 5, yRadius: 5)
        let inner = NSBezierPath(roundedRect: .init(x: -139, y: 1, width: 278, height: 208), xRadius: 4, yRadius: 4)
        framePath.append(inner.reversed)
        let frameGeometry = SCNShape(path: framePath, extrusionDepth: 1.8)
        frameGeometry.chamferRadius = 0.2
        _ = mesh(frameGeometry, color: ink, name: "Rounded habitat rear frame", parent: root, at: .init(0, 0, -64))
        flattenGeometry(in: root)
    }

    private func ring(radius: CGFloat, tube: CGFloat, color: NSColor, name: String, z: CGFloat, parent: SCNNode) {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: tube)
        torus.ringSegmentCount = 160
        torus.pipeSegmentCount = 16
        let node = mesh(torus, color: color, name: name, parent: parent, at: SCNVector3(0, 0, z))
        node.eulerAngles.x = .pi / 2
    }

    /// Closed strip of the cylinder wall between two radii, spanning an angle
    /// range: shared by the wooden planks and their dark barrel liner.
    private func curvedStrip(innerRadius: Float, outerRadius: Float, startAngle: Float, endAngle: Float,
                             zFront: Float, zBack: Float, segments: Int) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        let profile: [(Float, Float)] = [(innerRadius, zBack), (innerRadius, zFront), (outerRadius, zFront), (outerRadius, zBack), (innerRadius, zBack)]
        for j in 0..<profile.count {
            for i in 0...segments {
                let a = startAngle + (endAngle - startAngle) * Float(i) / Float(segments)
                let (r, z) = profile[j]
                vertices.append(SCNVector3(r * cos(a), r * sin(a), z))
                let sign: Float = j < 2 ? -1 : 1
                normals.append(SCNVector3(sign * cos(a), sign * sin(a), 0))
                if j < profile.count - 1 && i < segments {
                    let k = Int32(j * (segments + 1) + i), stride = Int32(segments + 1)
                    indices += [k, k + 1, k + stride, k + 1, k + stride + 1, k + stride]
                }
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Barrel-style running surface: an even ring of wooden planks like an old
    /// water bucket; the narrow gaps between planks read as the joint lines.
    private func buildWoodenTread(parent: SCNNode) {
        let plankWood = NSColor(srgbRed: 0.82, green: 0.64, blue: 0.43, alpha: 1)
        let seamWood = NSColor(srgbRed: 0.33, green: 0.24, blue: 0.16, alpha: 1)
        let planks = 18, gap: Float = 1.8 * .pi / 180
        let span = 2 * .pi / Float(planks) - gap
        for i in 0..<planks {
            let start = Float(i) * 2 * .pi / Float(planks) + gap / 2
            // Deterministic per-plank shading keeps the joints readable without
            // changing the texture between launches.
            let shade: CGFloat = 1 - CGFloat((i * 37) % 7) / 7 * 0.07
            let wood = plankWood.blended(withFraction: 1 - shade, of: seamWood) ?? plankWood
            let geo = curvedStrip(innerRadius: 97.3, outerRadius: 100.2, startAngle: start, endAngle: start + span,
                                  zFront: 26, zBack: -26, segments: 6)
            geo.firstMaterial = material(wood).copy() as? SCNMaterial
            geo.firstMaterial?.isDoubleSided = true
            let node = SCNNode(geometry: geo)
            node.name = "Wheel plank \(i)"
            parent.addChildNode(node)
        }
    }

    private func buildWheel() {
        let support = SCNNode()
        support.name = "Wheel stand"
        support.position = SCNVector3(27, 105, -24)
        scene.rootNode.addChildNode(support)
        // A thick wooden post carries the wheel, matching the barrel-style tread.
        rod(SCNVector3(0, -103, -26), SCNVector3(0, 0, -26), radius: 3.2, color: NSColor(srgbRed: 0.60, green: 0.44, blue: 0.28, alpha: 1), name: "Wheel rear support", parent: support)
        rod(SCNVector3(-24, -103, -26), SCNVector3(24, -103, -26), radius: 2, color: ink, name: "Wheel stand foot", parent: support)
        support.addChildNode(wheel)
        wheel.name = "Running wheel"
        buildWoodenTread(parent: wheel)
        for z: CGFloat in [-26, 26] {
            ring(radius: 100, tube: 3, color: ink, name: "Wheel rim border", z: z, parent: wheel)
            ring(radius: 100, tube: 1.85, color: color("wheelOuterColor"), name: "Red wheel rim", z: z + (z > 0 ? 1.6 : -1.6), parent: wheel)
        }
        // The front stays open so the hamster stays in view; the rear cross brace
        // carries the tread with proper wooden-spoke thickness.
        for angle: Float in [0, 2.0944, 4.1888] {
            rod(SCNVector3(0, 0, -26), SCNVector3(98 * cos(angle), 98 * sin(angle), -26), radius: 1.8, color: color("wheelSpokeColor"), name: "Rear spoke", parent: wheel)
        }
        // A single hub on the rear side, moved in front of the post so the post
        // no longer cuts across it from the front view.
        let hub = SCNCylinder(radius: 8, height: 5)
        let hubNode = mesh(hub, color: color("wheelCenterColor"), name: "wheelHub", parent: support, at: SCNVector3(0, 0, -22), outline: 0.13)
        hubNode.eulerAngles.x = .pi / 2
        flattenGeometry(in: wheel)
        flattenGeometry(in: support, excluding: [wheel])
    }

    private func buildBottle() {
        let bottle = SCNNode()
        bottle.name = "Water bottle"
        bottle.position = SCNVector3(-109, 142.5, 42)
        scene.rootNode.addChildNode(bottle)
        _ = box(SCNVector3(52, 125, 27), radius: 5, color: color("waterColor"), name: "Bottle solid shell", parent: bottle, at: .init(0, 0, 0), outline: 0.035)
        // A narrow glass edge remains readable without making the original blue bottle metallic.
        _ = box(SCNVector3(46, 118, 0.7), radius: 3, color: color("waterColor").blended(withFraction: 0.25, of: .white)!, name: "Bottle front glass", parent: bottle, at: .init(0, 0, 13.7), outline: 0)
        _ = box(SCNVector3(26, 12.5, 23), radius: 0.8, color: .darkGray, name: "Bottle cap", parent: bottle, at: .init(0, -68, 0), outline: 0.065)
        rod(SCNVector3(0, -73, 0), SCNVector3(12, -90, 0), radius: 3.8, color: ink, name: "Drinking nozzle outline", parent: bottle)
        rod(SCNVector3(0, -73, 0), SCNVector3(12, -90, 0), radius: 2.5, color: .lightGray, name: "Metal drinking nozzle", parent: bottle)
        ellipsoid(.init(3.1, 3.1, 3.1), color: .gray, name: "Drinking ball", parent: bottle, at: .init(12, -90, 0), outline: 0)
        // Rear fastening clips make the bottle complete from behind as well.
        for y: CGFloat in [-42, 42] {
            _ = box(.init(57, 3, 3), radius: 1, color: ink, name: "Bottle rear clip", parent: bottle, at: .init(0, y, -15), outline: 0)
        }
        flattenGeometry(in: bottle)
    }

    private func buildLamp() {
        lamp.name = "Pendant lamp"
        lamp.position = .init(119, 178, 0)
        scene.rootNode.addChildNode(lamp)
        rod(.init(0, 5, 0), .init(0, 32, 0), radius: 0.45, color: ink, name: "Lamp cord", parent: lamp)
        let shade = SCNCone(topRadius: 4.5, bottomRadius: 11, height: 8)
        _ = mesh(shade, color: NSColor(srgbRed: 0.35, green: 0.30, blue: 0.23, alpha: 1), name: "Lamp shade", parent: lamp, outline: 0.06)
        let lip = SCNTorus(ringRadius: 10.5, pipeRadius: 0.5)
        _ = mesh(lip, color: NSColor(srgbRed: 0.71, green: 0.55, blue: 0.32, alpha: 1), name: "Lamp lip", parent: lamp, at: .init(0, -4, 0))
        let bulb = ellipsoid(.init(4, 3.2, 4), color: NSColor(srgbRed: 1, green: 0.86, blue: 0.56, alpha: 1), name: "Lamp bulb", parent: lamp, at: .init(0, -5, 0), outline: 0)
        bulb.geometry?.firstMaterial = bulb.geometry?.firstMaterial?.copy() as? SCNMaterial
        bulb.geometry?.firstMaterial?.emission.contents = NSColor(srgbRed: 1, green: 0.65, blue: 0.20, alpha: 1)
        bulbLight.name = "Warm bulb light"
        bulbLight.light = SCNLight()
        bulbLight.light?.type = .omni
        bulbLight.light?.color = NSColor(srgbRed: 1, green: 0.75, blue: 0.42, alpha: 1)
        bulbLight.light?.intensity = 1000
        bulbLight.light?.attenuationStartDistance = 5
        bulbLight.light?.attenuationEndDistance = 300
        bulbLight.position = .init(0, -10, 0)
        lamp.addChildNode(bulbLight)
        flattenGeometry(in: lamp)
    }

    private func buildHamster() {
        hamster.name = "Hamster"
        scene.rootNode.addChildNode(hamster)
        model = HamsterDeformableModel(engine: engine, colors: palette, device: view.device)
        hamster.addChildNode(model.root)
    }

    func update(night: Bool) {
        let state = HamsterEngineGetSceneState(engine)
        var changed = false
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        let x = Float(state.x) - 140
        // Pose, heading, wheel banking and footfalls come directly from the original engine.
        let poseFrame = Int(HamsterEngineGetFrameCount(engine))
        if lastPoseFrame != poseFrame {
            hamsterDepth += ((state.onWheel != 0 ? -24 : 42) - hamsterDepth) * 0.18
            lastPoseFrame = poseFrame
        }
        let position = SCNVector3(CGFloat(x), 210 - state.y, CGFloat(hamsterDepth))
        if simd_distance_squared(hamster.simdPosition, SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))) > 0.0005 * 0.0005 {
            hamster.position = position
            changed = true
        }
        let rotation = CGFloat(-state.rotation * .pi / 180)
        if abs(hamster.eulerAngles.z - rotation) > 0.000005 {
            hamster.eulerAngles.z = rotation
            changed = true
        }
        let revision = model.geometryRevision
        model.update()
        changed = changed || revision != model.geometryRevision
        let wheelAngle = CGFloat(-state.wheelAngle)
        if abs(wheel.eulerAngles.z - wheelAngle) > 0.000005 {
            wheel.eulerAngles.z = wheelAngle
            changed = true
        }
        let count = HamsterEngineGetSceneFoodCount(engine)
        while foods.count < count {
            foods.append(ellipsoid(.init(1, 1, 1), color: color("foodColor"), name: "Food pellet", parent: scene.rootNode, at: .init(0, 0, 0), outline: 0.12))
            changed = true
        }
        for (i, node) in foods.enumerated() {
            guard i < count else {
                if !node.isHidden { node.isHidden = true; changed = true }
                continue
            }
            let food = HamsterEngineGetSceneFood(engine, Int32(i))
            let hidden = food.visible == 0
            if node.isHidden != hidden { node.isHidden = hidden; changed = true }
            if !hidden {
                let p = SCNVector3(food.x - 140, 210 - food.y, 42), scale = SCNVector3(food.radius, food.radius, food.radius)
                if node.position.x != p.x || node.position.y != p.y || node.position.z != p.z { node.position = p; changed = true }
                if node.scale.x != scale.x { node.scale = scale; changed = true }
            }
        }
        if self.night != night {
            self.night = night
            scene.background.contents = night ? NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 1) : color("bgColor")
            view.backgroundColor = scene.background.contents as? NSColor ?? .white
            lamp.isHidden = !night
            ambient.light?.intensity = night ? 430 : 850
            ambient.light?.color = night ? NSColor(srgbRed: 0.70, green: 0.78, blue: 0.95, alpha: 1) : .white
            keyLight.light?.intensity = night ? 180 : 150
            changed = true
        }
        if follow && simd_distance_squared(target, focusPoint) > 0.0005 * 0.0005 { target = focusPoint; updateCamera() }
        SCNTransaction.commit()
        if changed { view.presentFrame() }
    }

    private var focusPoint: SIMD3<Float> {
        let center = model.landmarks.count > 2 ? (model.landmarks[0] + model.landmarks[2]) * 0.5 : SIMD3<Float>(0, 0, 0)
        let p = hamster.convertPosition(.init(center.x, center.y, center.z), to: nil)
        return .init(Float(p.x), Float(p.y), Float(p.z))
    }

    var hamsterLandmarks: [SIMD3<Float>] { model.landmarks }
    var hamsterBodyVertices: [SIMD3<Float>] { model.bodyPositionsForInspection }
    var bodyMeshingBackend: String { model.bodyMeshingBackend }
    var bodyGPUSeconds: Double { model.bodyGPUSeconds }
    var inspectionCenter: SIMD3<Float> { focusPoint }
    func inspectHamster(yaw: Float = 0, pitch: Float = 0, zoom: Float = 2.1) {
        follow = true
        self.yaw = yaw
        self.pitch = pitch
        self.zoom = zoom
        target = focusPoint
        updateCamera()
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        yaw -= Float(dx) * 0.009
        pitch = max(-Float.pi / 2 + 0.015, min(Float.pi / 2 - 0.015, pitch + Float(dy) * 0.009))
        updateCamera()
    }
    func magnify(_ delta: CGFloat) {
        zoom = max(0.45, min(4.5, zoom * exp(Float(delta))))
        updateCamera()
    }
    func pan(dx: CGFloat, dy: CGFloat) {
        let scale = Float(212 / max(1, view.bounds.height)) / zoom
        target += camera.simdWorldRight * Float(-dx) * scale + camera.simdWorldUp * Float(dy) * scale
        follow = false
        updateCamera()
    }
    func preset(_ index: Int) {
        follow = index == 6
        target = follow ? focusPoint : .init(0, 105, 0)
        zoom = follow ? 2.1 : 1
        switch index {
        case 1: yaw = -.pi / 4; pitch = 0.25
        case 2: yaw = .pi / 2; pitch = 0.08
        case 3: yaw = .pi; pitch = 0.08
        case 4: yaw = 0; pitch = .pi / 2 - 0.015
        case 5: yaw = -.pi / 2; pitch = 0.08
        case 6: yaw = 0.3; pitch = 0.12
        default: yaw = 0; pitch = 0
        }
        updateCamera()
    }
    private func updateCamera() {
        let distance: Float = 650
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.simdPosition = target + distance * SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        camera.look(at: .init(CGFloat(target.x), CGFloat(target.y), CGFloat(target.z)), up: .init(0, 1, 0), localFront: .init(0, 0, -1))
        let aspect = max(0.1, view.bounds.width / max(1, view.bounds.height))
        camera.camera?.orthographicScale = Double(max(218, 290 / aspect) * 0.5 / CGFloat(zoom))
        SCNTransaction.commit()
        view.invalidateFrame()
    }
    func resize(_ frame: NSRect) {
        guard view.frame != frame else { return }
        view.frame = frame
        updateCamera()
    }

    /// Ray/plane projection keeps feeding attached to world coordinates after orbiting.
    func stagePoint(_ point: NSPoint) -> NSPoint? {
        let halfHeight = Float(camera.camera?.orthographicScale ?? 109)
        let width = Float(max(1, view.bounds.width)), height = Float(max(1, view.bounds.height))
        let right = camera.simdWorldRight, up = camera.simdWorldUp
        let horizontal = (Float(point.x) / width - 0.5) * 2 * halfHeight * width / height
        let vertical = (Float(point.y) / height - 0.5) * 2 * halfHeight
        let origin = camera.simdPosition + right * horizontal + up * vertical
        let direction = camera.simdWorldFront
        if abs(direction.z) < 0.12 {
            guard abs(direction.y) > 0.0001 else { return nil }
            let floorDistance = (3 - origin.y) / direction.y
            guard floorDistance > 0 else { return nil }
            let floorHit = origin + direction * floorDistance
            guard abs(floorHit.z) <= 67 else { return nil }
            return .init(x: CGFloat(floorHit.x + 140), y: 207)
        }
        let distance = (42 - origin.z) / direction.z
        guard distance > 0 else { return nil }
        let hit = origin + direction * distance
        return NSPoint(x: CGFloat(hit.x + 140), y: CGFloat(210 - hit.y))
    }

    func project(_ worldPoint: SCNVector3) -> NSPoint {
        let point = SIMD3<Float>(Float(worldPoint.x), Float(worldPoint.y), Float(worldPoint.z))
        let delta = point - camera.simdPosition
        let halfHeight = Float(camera.camera?.orthographicScale ?? 109)
        let width = Float(max(1, view.bounds.width)), height = Float(max(1, view.bounds.height))
        let x = (simd_dot(delta, camera.simdWorldRight) / (2 * halfHeight * width / height) + 0.5) * width
        let y = (simd_dot(delta, camera.simdWorldUp) / (2 * halfHeight) + 0.5) * height
        return NSPoint(x: CGFloat(x), y: CGFloat(y))
    }

    func hitsWheel(_ point: NSPoint) -> Bool {
        let halfHeight = Float(camera.camera?.orthographicScale ?? 109)
        let width = Float(max(1, view.bounds.width)), height = Float(max(1, view.bounds.height))
        let x = (Float(point.x) / width - 0.5) * 2 * halfHeight * width / height
        let y = (Float(point.y) / height - 0.5) * 2 * halfHeight
        let origin = camera.simdPosition + camera.simdWorldRight * x + camera.simdWorldUp * y
        let end = origin + camera.simdWorldFront * Float(camera.camera?.zFar ?? 2500)
        let hits = scene.rootNode.hitTestWithSegment(from: .init(origin.x, origin.y, origin.z), to: .init(end.x, end.y, end.z),
                                                    options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue,
                                                              SCNHitTestOption.ignoreHiddenNodes.rawValue: true])
        return hits.first.map { hit in
            var node: SCNNode? = hit.node
            while let current = node {
                if current.name == "wheelHub" { return true }
                node = current.parent
            }
            return false
        } ?? false
    }

    func snapshot(size: CGSize) -> NSImage {
        if let image = view.image(size: size) { return image }
        preconditionFailure("Unable to render 3D inspection image")
    }

}
