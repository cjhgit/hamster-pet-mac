import AppKit
import SceneKit
import Darwin

@main struct Verify3D {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: "/private/tmp/hamster-3d", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "hamster.3d.test.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let view = HamsterView(frame: .init(x: 0, y: 0, width: 900, height: 677), seed: 11042, preferences: prefs)
        let window = HamsterWindow(preferences: prefs)
        window.contentView = view
        window.setContentSize(.init(width: 900, height: 677))
        let renderer = view.scene3D!
        func save(_ name: String) throws {
            let image = renderer.snapshot(size: .init(width: 1200, height: 900))
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        // The repeated tread pattern must remain unambiguous at full speed,
        // and the shared rigid wheel transform must follow the engine angle.
        HamsterTestConfigureScenario(2, 0)
        let wheel = renderer.scene.rootNode.childNode(withName: "Running wheel", recursively: true)!
        var previousWheelAngle = HamsterEngineGetSceneStateForTest().wheelAngle
        var maximumWheelStep = 0.0
        for _ in 0..<300 {
            HamsterTestStep()
            renderer.update(night: false)
            let angle = HamsterEngineGetSceneStateForTest().wheelAngle
            let step = abs(angle - previousWheelAngle)
            maximumWheelStep = max(maximumWheelStep, step)
            precondition(step < .pi / Double(Hamster3DScene.wheelTreadPanelCount),
                         "Tread joints alias at full speed, making the rim appear out of sync")
            let spokeEnd = wheel.convertPosition(.init(98, 0, -26), to: wheel.parent!)
            precondition(abs(Double(spokeEnd.x) - 98 * cos(angle)) < 0.002
                         && abs(Double(spokeEnd.y) + 98 * sin(angle)) < 0.002,
                         "Rigid wheel rotation diverges from the simulation")
            previousWheelAngle = angle
        }
        precondition(maximumWheelStep > 0.3, "Wheel synchronization check must reach full speed")
        print("PASS: rigid wheel follows engine angle; tread stays below aliasing limit at full speed")
        // Capture a stable standing pose, and every side of the same actual scene.
        for _ in 0..<40 { HamsterTestStep() }
        HamsterTestSet3DPose(0)
        renderer.update(night: false)
        print("STATE", HamsterEngineGetSceneStateForTest())
        for (index, name) in ["front", "perspective", "right", "back", "top", "left", "closeup"].enumerated() {
            renderer.preset(index)
            try save(name)
        }
        renderer.preset(6)
        let surroundings = renderer.scene.rootNode.childNodes.filter { $0 !== renderer.hamster && $0.camera == nil && $0.light == nil }
        let visibility = surroundings.map(\.isHidden)
        surroundings.forEach { $0.isHidden = true }
        for i in 0..<8 {
            renderer.orbit(dx: 87.2665, dy: 0)
            try save("hamster-\(i)")
        }
        for (node, hidden) in zip(surroundings, visibility) { node.isHidden = hidden }
        for pose in [1, 2] {
            HamsterTestSet3DPose(Int32(pose))
            renderer.update(night: false)
            renderer.preset(6)
            try save(pose == 1 ? "eating" : "cleaning")
        }
        HamsterTestSet3DPose(0)
        renderer.update(night: false)
        renderer.preset(1)
        renderer.update(night: true)
        try save("night")
        // Inspect the limb roots and rounded paws under directional night light.
        for pose in [0, 1, 2] {
            HamsterTestSet3DPose(Int32(pose))
            renderer.update(night: true)
            renderer.preset(6)
            try save("night-paws-\(pose)")
        }
        HamsterTestSet3DPose(0)
        renderer.update(night: false)
        var meshes = 0
        renderer.scene.rootNode.enumerateChildNodes { node, _ in
            if let geo = node.geometry {
                meshes += 1
                let b = geo.boundingBox
                precondition(b.max.x > b.min.x && b.max.y > b.min.y && b.max.z > b.min.z, "Flat object: \(node.name ?? "?")")
                _ = geo
            }
        }
        // Batching changes the number of SceneKit objects, not the solid
        // contents. Check each semantic object and articulated feature instead
        // of requiring redundant draw nodes.
        for name in ["Habitat", "Wheel stand", "Running wheel", "Water bottle", "Pendant lamp", "Hamster"] {
            let node = renderer.scene.rootNode.childNode(withName: name, recursively: true)!
            // SCNNode reports an empty aggregate box for hidden objects (the
            // daytime lamp). Individual geometry boxes were checked above.
            var solids = node.geometry == nil ? 0 : 1
            node.enumerateChildNodes { child, _ in if child.geometry != nil { solids += 1 } }
            precondition(solids > 0, "Missing solid object: \(name)")
        }
        for name in ["Hamster deforming skin", "Right eye", "Left eye", "Right ear", "Left ear", "Black ear rim 0", "Black ear rim 1"] {
            let geometry = renderer.hamster.childNode(withName: name, recursively: true)!.geometry!
            precondition(geometry.sources(for: .vertex).first!.vectorCount > 20)
            precondition(geometry.elements.contains { $0.primitiveCount > 0 })
        }
        if !CommandLine.arguments.contains("--hamster-unbatched") {
            let batch = renderer.hamster.childNode(withName: "Batched deforming limbs, paws and strokes", recursively: true)!
            let geometry = batch.geometry!
            precondition(geometry.sources(for: .vertex).first!.vectorCount > 1500)
            precondition(geometry.materials.count >= 3 && geometry.elements.count >= 3)
            precondition(batch.childNodes.first!.geometry!.sources(for: .vertex).first!.vectorCount == geometry.sources(for: .vertex).first!.vectorCount)
        }
        print("PASS: \(meshes) volumetric meshes, all six scene views and eight hamster orbit views rendered")
        renderer.preset(0)
        let projected = renderer.project(.init(20, 80, 42))
        let unprojected = renderer.stagePoint(.init(x: projected.x, y: projected.y))!
        precondition(abs(unprojected.x - 160) < 0.02 && abs(unprojected.y - 130) < 0.02)
        let yaw = renderer.yaw
        func event(_ type: NSEvent.EventType, _ p: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags,
                              timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = HamsterTestFoodCount()
        view.mouseDown(with: event(.leftMouseDown, .init(x: 450, y: 300)))
        view.mouseDragged(with: event(.leftMouseDragged, .init(x: 520, y: 350)))
        view.mouseUp(with: event(.leftMouseUp, .init(x: 520, y: 350)))
        precondition(renderer.yaw != yaw && HamsterTestFoodCount() == before, "Orbit must not feed")
        renderer.preset(0)
        let feed = view.convert(renderer.view.convert(.init(x: projected.x, y: projected.y), to: nil), from: nil)
        view.mouseDown(with: event(.leftMouseDown, feed))
        view.mouseUp(with: event(.leftMouseUp, feed))
        precondition(HamsterTestFoodCount() == before + 1)
        view.mouseDown(with: event(.leftMouseDown, feed, flags: .command))
        precondition(HamsterTestDragging() == 1)
        view.mouseDragged(with: event(.leftMouseDragged, .init(x: feed.x + 20, y: feed.y - 15), flags: .command))
        HamsterTestStep()
        view.mouseUp(with: event(.leftMouseUp, .init(x: feed.x + 20, y: feed.y - 15), flags: .command))
        precondition(HamsterTestDragging() == 0)
        print("PASS: real NSView drag orbits without feeding; clicks feed and Command-drag moves food")
        for index in [1, 3, 6] {
            renderer.preset(index)
            let projected = renderer.project(.init(20, 80, 42))
            let p = renderer.stagePoint(.init(x: projected.x, y: projected.y))!
            precondition(abs(p.x - 160) < 0.05 && abs(p.y - 130) < 0.05, "Projection at preset \(index): \(p)")
        }
        renderer.preset(4)
        let floorPixel = renderer.project(.init(20, 3, 0))
        let floorPoint = renderer.stagePoint(floorPixel)!
        precondition(abs(floorPoint.x - 160) < 0.05 && floorPoint.y == 207)
        renderer.preset(1)
        renderer.magnify(100)
        precondition(renderer.zoom == 4.5)
        renderer.magnify(-100)
        precondition(renderer.zoom == 0.45)
        renderer.preset(0)
        renderer.update(night: false)
        precondition(renderer.hitsWheel(renderer.project(.init(27, 105, -4))), "Hub must be hittable")
        let settings = view.makeSettingsMenu()
        precondition(settings.item(withTitle: "3D 视角")?.submenu?.items.count == 7)
        settings.performActionForItem(at: 3)
        precondition(prefs.bool(forKey: "hamster.darkMode"))
        view.makeSettingsMenu().performActionForItem(at: 3)
        precondition(!prefs.bool(forKey: "hamster.darkMode"))
        print("PASS: camera presets, projection after rotation, zoom limits and interactions")
        print("Screenshots: \(output.path)")
    }
}
