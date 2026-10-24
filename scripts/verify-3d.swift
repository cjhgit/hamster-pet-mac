import AppKit
import SceneKit
import simd
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
        func save(_ name: String, size: CGSize = .init(width: 1200, height: 900)) throws {
            let image = renderer.snapshot(size: size)
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
        precondition(renderer.interactionTarget(at: renderer.project(.init(27, 105, -4))) == .wheel, "Hub must be hittable")
        let bottleBottom = SCNVector3(-109, 74.5, 42)
        func hover(_ world: SCNVector3, cursor: NSCursor) {
            let p = view.convert(renderer.view.convert(renderer.project(world), to: nil), from: nil)
            let movement = event(.mouseMoved, p)
            view.cursorUpdate(with: movement)
            precondition(NSCursor.current == cursor,
                         "Cursor entry mismatch: yaw \(renderer.yaw), pitch \(renderer.pitch), target \(String(describing: renderer.interactionTarget(at: renderer.project(world))))")
            view.mouseMoved(with: movement)
            precondition(NSCursor.current == cursor, "Hover cursor must match the visible interaction target")
        }
        hover(.init(27, 105, -4), cursor: .pointingHand)
        for preset in [0, 1, 3] {
            renderer.preset(preset)
            precondition(renderer.interactionTarget(at: renderer.project(bottleBottom)) == .water,
                         "Bottle cap must be hittable at preset \(preset)")
            hover(bottleBottom, cursor: .pointingHand)
        }
        renderer.preset(0)
        renderer.magnify(0.1)
        renderer.pan(dx: 10, dy: 8)
        hover(bottleBottom, cursor: .pointingHand)
        renderer.preset(0)
        hover(.init(-97, 52.5, 42), cursor: .pointingHand)
        hover(.init(-109, 142.5, 42), cursor: .arrow)
        precondition(renderer.interactionTarget(at: renderer.project(.init(-109, 142.5, 42))) == nil,
                     "The upper bottle must not trigger drinking")
        precondition(renderer.interactionTarget(at: renderer.project(.init(-97, 52.5, 42))) == .water,
                     "Drinking nozzle must be hittable")
        func clickBottle() {
            let projected = renderer.project(bottleBottom)
            let p = view.convert(renderer.view.convert(projected, to: nil), from: nil)
            view.mouseDown(with: event(.leftMouseDown, p))
            view.mouseUp(with: event(.leftMouseUp, p))
        }
        HamsterTestConfigureScenario(0, 0)
        renderer.update(night: false)
        let pauseMenu = view.makeSettingsMenu()
        pauseMenu.performActionForItem(at: pauseMenu.index(of: pauseMenu.item(withTitle: "暂停播放")!))
        let waterBeforePause = HamsterEngineGetSceneStateForTest().waterLevel
        hover(bottleBottom, cursor: .arrow)
        clickBottle()
        precondition(HamsterEngineGetSceneStateForTest().waterLevel == waterBeforePause,
                     "Paused clicks must not request drinking")
        let resumeMenu = view.makeSettingsMenu()
        resumeMenu.performActionForItem(at: resumeMenu.index(of: resumeMenu.item(withTitle: "继续播放")!))
        for scenario: Int32 in [0, 2, 6] {
            HamsterTestConfigureScenario(scenario, 0)
            renderer.update(night: false)
            let food = HamsterTestFoodCount()
            clickBottle()
            let state = HamsterEngineGetSceneStateForTest()
            precondition(state.waterLevel == 0 && state.sleeping == 0 && state.onWheel == 0,
                         "Bottle click must wake the hamster and guide it off the wheel")
            for _ in 0..<900 {
                HamsterTestStep()
                if HamsterEngineGetSceneStateForTest().waterLevel > 0 { break }
            }
            precondition(HamsterEngineGetSceneStateForTest().waterLevel > 0,
                         "Hamster must reach the bottle and finish drinking from scenario \(scenario)")
            precondition(HamsterTestFoodCount() == food && HamsterTestDragging() == 0,
                         "Bottle clicks must not feed or drag food")
        }
        print("PASS: bottle/wheel hover cursors after orbit/zoom/pan, pause guard, idle/sleep/wheel to completed drinking")
        HamsterTestClearFood()
        let cushionEdge = SCNVector3(116, 0.9, 70)
        func assertLimbsAboveFloor() {
            let vertices = renderer.hamsterGroundVertices
            precondition(!vertices.isEmpty)
            let bottom = vertices.map { renderer.hamster.convertPosition(SCNVector3($0), to: nil).y }.min()!
            precondition(bottom >= 0.499,
                         "Visible limbs and outlines must never pass through the floor, including during sleep entry: \(bottom)")
        }
        func clickCushion() {
            let p = view.convert(renderer.view.convert(renderer.project(cushionEdge), to: nil), from: nil)
            view.mouseDown(with: event(.leftMouseDown, p))
            view.mouseUp(with: event(.leftMouseUp, p))
        }
        HamsterTestConfigureScenario(0, 0)
        renderer.update(night: false)
        for preset in [0, 1, 3, 4] {
            renderer.preset(preset)
            precondition(renderer.interactionTarget(at: renderer.project(cushionEdge)) == .cushion,
                         "Cushion must be hittable at preset \(preset)")
            hover(cushionEdge, cursor: .pointingHand)
        }
        renderer.preset(0)
        // Thin, edge-on cushions still need a comfortable screen-space target.
        HamsterTestConfigureScenario(0, 0)
        renderer.update(night: false)
        renderer.preset(0)
        let cushionAbove = renderer.project(.init(116, 0.9, 70))
        let paddedPoint = NSPoint(x: cushionAbove.x, y: cushionAbove.y + 10)
        precondition(renderer.interactionTarget(at: paddedPoint) == .cushion,
                     "Clicking above the thin cushion must use the expanded target")
        let cushionPause = view.makeSettingsMenu()
        cushionPause.performActionForItem(at: cushionPause.index(of: cushionPause.item(withTitle: "暂停播放")!))
        hover(cushionEdge, cursor: .arrow)
        clickCushion()
        for _ in 0..<150 { HamsterTestStep() }
        precondition(HamsterEngineGetSceneStateForTest().sleeping == 0, "Paused cushion click must do nothing")
        let cushionResume = view.makeSettingsMenu()
        cushionResume.performActionForItem(at: cushionResume.index(of: cushionResume.item(withTitle: "继续播放")!))
        for scenario: Int32 in [0, 1, 2, 3, 4, 5, 6] {
            HamsterTestConfigureScenario(scenario, 0)
            renderer.update(night: false)
            clickCushion()
            var preparingFrames = 0
            for _ in 0..<1800 {
                HamsterTestStep()
                renderer.update(night: false)
                let state = HamsterEngineGetSceneStateForTest()
                if state.onWheel == 0 { assertLimbsAboveFloor() }
                if state.preparingSleep != 0 { preparingFrames += 1 }
                if state.sleeping != 0 { break }
            }
            precondition(preparingFrames > 0, "Verify the transition before the sleeping flag is set")
            let asleep = HamsterEngineGetSceneStateForTest()
            print("CUSHION", scenario, asleep.x, asleep.sleeping, asleep.onWheel)
            precondition(asleep.sleeping != 0 && asleep.onWheel == 0 && abs(asleep.x - 220) < 25,
                         "Hamster must walk to the cushion and sleep from scenario \(scenario)")
            // Hovering the bed must not immediately undo the user's sleep request.
            hover(cushionEdge, cursor: .pointingHand)
            for frame in 0..<150 {
                HamsterTestStep()
                renderer.update(night: false)
                assertLimbsAboveFloor()
                if frame % 30 == 0 {
                    let skin = renderer.hamsterBodyVertices
                    precondition(!skin.isEmpty)
                    let bottom = skin.map { renderer.hamster.convertPosition(SCNVector3($0), to: nil).y }.min()!
                    let gap = bottom - 0.5
                    precondition(gap >= -0.15 && gap <= 1.5,
                                 "Sleeping belly must touch the floor, allowing intersection with the cushion: gap \(gap)")
                }
            }
            precondition(HamsterEngineGetSceneStateForTest().sleeping != 0)
            precondition(abs(HamsterEngineGetSceneStateForTest().headPitch) < 0.01,
                         "The sleeping head must lie level instead of pitching nose-down")
            for (leg, vertices) in renderer.hamsterPawVertices.enumerated() {
                let exposed = vertices.filter { p in
                    HamsterTestSkinDistance(.init(x: Double(p.x), y: Double(p.y), z: Double(p.z), curve: 0)) > 0.15
                }.count
                precondition(exposed >= 3, "Curled paw \(leg) must remain visible outside the coat")
                let bones = renderer.hamsterRestingBones[leg]
                let offset = 4 + leg * 5
                let root = renderer.hamsterLandmarks[offset..<(offset + 3)].reduce(SIMD3<Float>.zero, +) / 3
                precondition(simd_distance(root, bones[0]) < 0.001, "Shoulder/hip must remain attached to the original body")
                let skinConnection = renderer.hamsterLimbVertices[leg].prefix(96).contains { p in
                    HamsterTestSkinDistance(.init(x: Double(p.x), y: Double(p.y), z: Double(p.z), curve: 0)) < -0.5
                }
                precondition(skinConnection, "Upper-limb muscle must overlap the body skin, with no detached root")
                precondition(abs(simd_distance(bones[0], bones[1]) - (leg < 2 ? 10 : 13)) < 0.01
                             && abs(simd_distance(bones[1], bones[2]) - (leg < 2 ? 9 : 13)) < 0.01,
                             "Folding must rotate fixed-length bones, not relocate the limb")
                let heading = Float(HamsterEngineGetSceneStateForTest().heading)
                let forward = SIMD3<Float>(cos(heading), 0, sin(heading))
                let foot = simd_normalize(bones[3] - bones[2])
                precondition(simd_dot(foot, forward) > 0.99, "Toes must point forward along the body, not backward")
                let lowest = vertices.map { p in
                    renderer.hamster.convertPosition(SCNVector3(p), to: nil).y
                }.min()!
                precondition(lowest >= 0.499 && lowest <= 1.8,
                             "Resting paw \(leg) must lie on the floor beside the body: \(lowest)")
                let silhouette = renderer.hamsterLimbSilhouettes[leg]
                for i in stride(from: 0, to: silhouette.count, by: 8) {
                    let p = silhouette[i]
                    precondition(HamsterTestHiddenByBodyFromAbove(.init(x: Double(p.x), y: Double(p.y), z: Double(p.z), curve: 0)) != 0,
                                 "Sleeping limb \(leg) and its outline must be occluded by the body from above: \(p)")
                }
            }
            precondition(HamsterTestFoodCount() == 0 && HamsterTestDragging() == 0)
            renderer.update(night: false)
            if scenario == 2 {
                renderer.preset(1); try save("cushion-sleep")
                renderer.inspectHamster(yaw: 0, pitch: 0.08, zoom: 2.1); try save("cushion-sleep-front")
                renderer.inspectHamster(yaw: .pi / 2, pitch: 0.08, zoom: 2.1); try save("cushion-sleep-side")
                renderer.inspectHamster(yaw: 0, pitch: .pi / 2 - 0.015, zoom: 2.1); try save("cushion-sleep-top")
                renderer.preset(0)
                try save("cushion-sleep-window-size", size: .init(width: 371, height: 280))
            }
            clickBottle()
            for _ in 0..<900 {
                HamsterTestStep()
                if HamsterEngineGetSceneStateForTest().waterLevel > 0 { break }
            }
            precondition(HamsterEngineGetSceneStateForTest().waterLevel > 0,
                         "A new drink request must cancel cushion sleep")
        }
        print("PASS: cushion hit testing, hand cursor, pause guard, seven activities to sleep, hover persistence and wake to drink")
        for heading in [0.0, Double.pi / 2, Double.pi] {
            for location in [65.0, 220.0] {
                HamsterTestConfigureScenario(6, heading)
                HamsterTestSetGroundPosition(location)
                for _ in 0..<30 {
                    HamsterTestStep()
                    renderer.update(night: false)
                    let bottom = renderer.hamsterBodyVertices.map {
                        renderer.hamster.convertPosition(SCNVector3($0), to: nil).y
                    }.min()!
                    assertLimbsAboveFloor()
                    let gap = bottom - 0.5
                    precondition(gap >= -0.15 && gap <= 1.5,
                                 "Sleeping belly must stay in contact at heading \(heading): gap \(gap)")
                }
                if heading == 0 && location == 65 {
                    renderer.inspectHamster(yaw: -0.4, pitch: 0.12, zoom: 2.1); try save("floor-sleep")
                    renderer.inspectHamster(yaw: 0, pitch: 0.08, zoom: 2.1); try save("floor-sleep-front")
                    renderer.preset(0)
                }
            }
        }
        renderer.preset(0)
        print("PASS: belly rests on floor under/beside cushion; limbs and outlines stay above floor on every entry frame")
        HamsterTestClearFood()
        for scenario: Int32 in [0, 1, 2] {
            HamsterTestConfigureScenario(scenario, 0)
            renderer.update(night: false)
            renderer.preset(0)
            let localCenter = (renderer.hamsterLandmarks[0] + renderer.hamsterLandmarks[1]) * 0.5
            let body = renderer.hamster.convertPosition(SCNVector3(localCenter), to: nil)
            precondition(renderer.interactionTarget(at: renderer.project(body)) == .hamster,
                         "Visible body must be clickable, including on the wheel")
            if scenario == 0 {
                for preset in [1, 3, 4] {
                    renderer.preset(preset)
                    hover(body, cursor: .pointingHand)
                }
                renderer.preset(0)
                let obstruction = SCNNode(geometry: SCNBox(width: 15, height: 15, length: 5, chamferRadius: 0))
                obstruction.simdPosition = SIMD3<Float>(body) - renderer.camera.simdWorldFront * 70
                obstruction.simdOrientation = renderer.camera.simdWorldOrientation
                renderer.scene.rootNode.addChildNode(obstruction)
                // SceneKit tessellates newly added primitive geometry lazily.
                _ = renderer.snapshot(size: .init(width: 32, height: 32))
                hover(body, cursor: .arrow)
                precondition(renderer.interactionTarget(at: renderer.project(body)) == nil,
                             "Occluded bodies must not be clickable")
                obstruction.removeFromParentNode()
                _ = renderer.snapshot(size: .init(width: 32, height: 32))
            }
            hover(body, cursor: .pointingHand)
            let p = view.convert(renderer.view.convert(renderer.project(body), to: nil), from: nil)
            let food = HamsterTestFoodCount()
            // A camera drag over the body must not turn into a pet.
            view.mouseDown(with: event(.leftMouseDown, p))
            view.mouseDragged(with: event(.leftMouseDragged, .init(x: p.x + 12, y: p.y)))
            view.mouseUp(with: event(.leftMouseUp, p))
            precondition(HamsterEngineGetSceneStateForTest().petting == 0)
            renderer.preset(0)
            func pet() {
                renderer.update(night: false)
                let center = (renderer.hamsterLandmarks[0] + renderer.hamsterLandmarks[1]) * 0.5
                let world = renderer.hamster.convertPosition(SCNVector3(center), to: nil)
                let current = view.convert(renderer.view.convert(renderer.project(world), to: nil), from: nil)
                view.mouseDown(with: event(.leftMouseDown, current))
                view.mouseUp(with: event(.leftMouseUp, current))
            }
            if scenario == 0 {
                let pause = view.makeSettingsMenu()
                pause.performActionForItem(at: pause.index(of: pause.item(withTitle: "暂停播放")!))
                hover(body, cursor: .arrow)
                pet()
                precondition(HamsterEngineGetSceneStateForTest().petting == 0, "Paused clicks must not pet")
                let resume = view.makeSettingsMenu()
                resume.performActionForItem(at: resume.index(of: resume.item(withTitle: "继续播放")!))
            }
            if scenario == 2 { precondition(HamsterEngineGetSceneStateForTest().onWheel != 0) }
            let beforePet = HamsterEngineGetSceneStateForTest()
            pet()
            precondition(HamsterEngineGetSceneStateForTest().petting == 1,
                         "Petting must begin with braking, not a frozen pose")
            var brakingFrames = 0
            var firstMovement = 0.0, lastMovement = 0.0
            var earlyCadence = 0.0, lateCadence = 0.0
            for frame in 0..<180 {
                let previous = HamsterEngineGetSceneStateForTest()
                HamsterTestStep()
                renderer.update(night: false)
                let braking = HamsterEngineGetSceneStateForTest()
                let movement = hypot(braking.x - previous.x, braking.y - previous.y)
                precondition(movement < 10, "Braking must not teleport the hamster")
                if frame == 0 {
                    firstMovement = movement
                    if scenario == 1 { precondition(movement > 0.1, "Walking must retain its initial momentum") }
                    if scenario == 2 {
                        precondition(braking.legPhase != previous.legPhase && braking.speed > 0 && braking.speed < beforePet.speed,
                                     "Running must decelerate, not stop on the first frame")
                    }
                }
                if frame < 5 { earlyCadence += abs(braking.legPhase - previous.legPhase) }
                if frame >= 20 && frame < 25 { lateCadence += abs(braking.legPhase - previous.legPhase) }
                brakingFrames += 1
                lastMovement = movement
                if braking.petting == 2 { break }
            }
            let state = HamsterEngineGetSceneStateForTest()
            precondition(brakingFrames > 10 && state.petting == 2 && state.moving == 0 && state.eyeOpen < 0.2,
                         "The hamster must settle its steps before relaxing")
            if scenario != 0 { precondition(lastMovement < firstMovement * 0.2, "Momentum must decay before holding") }
            if scenario == 2 { precondition(lateCadence < earlyCadence * 0.4 && state.speed < 0.001) }
            let pose = renderer.hamsterLandmarks, position = renderer.hamster.simdPosition
            for frame in 0..<60 {
                HamsterTestStep()
                renderer.update(night: false)
                let held = HamsterEngineGetSceneStateForTest()
                precondition(held.petting != 0 && held.x == state.x && held.y == state.y && held.legPhase == state.legPhase)
                precondition(renderer.hamsterLandmarks == pose && renderer.hamster.simdPosition == position,
                             "Petting must hold the whole pose, including wheel gait and depth")
                if frame == 0 {
                    for index in 0..<2 {
                        precondition(renderer.hamster.childNode(withName: "Eye highlight \(index)", recursively: true)!.isHidden,
                                     "Squinting must hide highlights outside the closed eyes")
                    }
                    renderer.inspectHamster(yaw: 0, pitch: 0.15)
                    try save("petting-\(scenario)")
                    renderer.preset(0)
                }
            }
            pet()
            for _ in 0..<60 { HamsterTestStep() }
            precondition(HamsterEngineGetSceneStateForTest().petting != 0, "Repeated petting must extend the hold")
            for _ in 0..<32 { HamsterTestStep() }
            precondition(HamsterEngineGetSceneStateForTest().petting == 0, "Activity must resume after petting")
            precondition(HamsterTestFoodCount() == food && HamsterTestDragging() == 0, "Petting must not feed")
            if scenario == 2 {
                precondition(HamsterEngineGetSceneStateForTest().legPhase != state.legPhase,
                             "Wheel gait must resume after petting ends")
            }
        }
        print("PASS: petting hover/click, continuous walk/wheel braking, planted relaxed poses, repeat extension and recovery")
        let settings = view.makeSettingsMenu()
        precondition(settings.item(withTitle: "3D 视角")?.submenu?.items.count == 7)
        settings.performActionForItem(at: 3)
        precondition(prefs.bool(forKey: "hamster.darkMode"))
        view.makeSettingsMenu().performActionForItem(at: 3)
        precondition(!prefs.bool(forKey: "hamster.darkMode"))
        print("PASS: camera presets, projection after rotation, zoom limits and interactions")
        // Toggle while paused: changing representation must not advance the
        // simulation, and all original controls remain usable.
        let skeletonPause = view.makeSettingsMenu()
        skeletonPause.performActionForItem(at: skeletonPause.index(of: skeletonPause.item(withTitle: "暂停播放")!))
        let beforeSkeleton = renderer.hamsterLandmarks
        let skeletonMenu = view.makeSettingsMenu()
        skeletonMenu.performActionForItem(at: skeletonMenu.index(of: skeletonMenu.item(withTitle: "骨骼模式")!))
        precondition(renderer.showsSkeleton && prefs.bool(forKey: "hamster.skeletonMode"))
        precondition(renderer.hamsterLandmarks == beforeSkeleton)
        precondition(view.makeSettingsMenu().item(withTitle: "骨骼模式")?.state == .on)
        let skinRoot = renderer.hamster.childNode(withName: "Hamster skin", recursively: true)!
        let skeletonRoot = renderer.hamster.childNode(withName: "Hamster pose skeleton", recursively: true)!
        precondition(skinRoot.isHidden && !skeletonRoot.isHidden)
        let skeletonResume = view.makeSettingsMenu()
        skeletonResume.performActionForItem(at: skeletonResume.index(of: skeletonResume.item(withTitle: "继续播放")!))
        for scenario: Int32 in [0, 2, 6] {
            HamsterTestConfigureScenario(scenario, 0)
            for _ in 0..<16 { HamsterTestStep(); renderer.update(night: false) }
            let segments = renderer.hamsterSkeletonSegments
            precondition(simd_distance(segments[0][0], renderer.hamsterLandmarks[0]) < 0.0001)
            for (leg, chain) in renderer.hamsterRestingBones.enumerated() {
                for i in 0..<3 {
                    let segment = segments[2 + leg * 3 + i]
                    precondition(simd_distance(segment[0], chain[i]) < 0.0001 &&
                                 simd_distance(segment[1], chain[i + 1]) < 0.0001,
                                 "Skeleton must use the same sleeping IK as the skin")
                }
            }
            for (i, segment) in segments.enumerated() {
                let rod = skeletonRoot.childNode(withName: "Pose bone \(i)", recursively: false)!
                let a = rod.simdConvertPosition(.init(0, -0.5, 0), to: skeletonRoot)
                let b = rod.simdConvertPosition(.init(0, 0.5, 0), to: skeletonRoot)
                precondition(simd_distance(a, segment[0]) < 0.001 && simd_distance(b, segment[1]) < 0.001)
            }
            renderer.preset(6)
            try save("skeleton-\(scenario)")
        }
        let restoreSkin = view.makeSettingsMenu()
        restoreSkin.performActionForItem(at: restoreSkin.index(of: restoreSkin.item(withTitle: "骨骼模式")!))
        precondition(!skinRoot.isHidden && skeletonRoot.isHidden && !prefs.bool(forKey: "hamster.skeletonMode"))
        print("PASS: skeleton menu, paused toggle, original walk/wheel/sleep pose synchronization and skin restoration")
        HamsterTestConfigureScenario(0, 0)
        renderer.update(night: false)
        renderer.inspectHamster(yaw: 0.65, pitch: 0.15)
        let earRoots = (0..<2).map { renderer.hamster.childNode(withName: "Ear root \($0)", recursively: true)! }
        let names = ["Right ear", "Left ear"]
        for i in 0..<2 {
            for name in [names[i], "Black ear rim \(i)", "Inner ear fold \(i)"] {
                precondition(renderer.hamster.childNode(withName: name, recursively: true)?.parent === earRoots[i],
                             "Ear skin, outline and cartilage must share one anchored joint")
            }
        }
        try save("ears-rest")
        var peakAngle: Float = 0
        var asymmetric = false
        var savedFlick = false
        for _ in 0..<240 {
            HamsterTestStep()
            renderer.update(night: false)
            for ear in earRoots { peakAngle = max(peakAngle, ear.simdOrientation.angle) }
            asymmetric = asymmetric || simd_length(earRoots[0].simdOrientation.vector - earRoots[1].simdOrientation.vector) > 0.03
            // Ear bones use the same pivot as the complete rendered ear.
            let base = 2 + (renderer.hamsterRestingBones.isEmpty ? 8 : 12) + 4
            for i in 0..<2 {
                let root = earRoots[i].simdConvertPosition(.zero, to: renderer.hamster)
                precondition(simd_distance(root, renderer.hamsterSkeletonSegments[base + i * 2][1]) < 0.001)
            }
            if peakAngle > 0.15 && !savedFlick {
                try save("ears-flick")
                savedFlick = true
            }
        }
        precondition(peakAngle > 0.15 && asymmetric, "Awake ears must flick independently")
        let frozen = earRoots.map { $0.simdOrientation.vector }
        for _ in 0..<5 { renderer.update(night: false) }
        precondition(earRoots.map { $0.simdOrientation.vector } == frozen,
                     "Rendering without stepping must not advance ear animation")
        HamsterTestConfigureScenario(6, 0)
        for _ in 0..<180 { HamsterTestStep(); renderer.update(night: false) }
        precondition(earRoots.allSatisfy { $0.simdOrientation.angle < 0.001 }, "Sleeping ears must settle quietly")
        print("PASS: anchored ear skin/rim/fold, independent flicks, shared skeleton joints, frame-based pause and quiet sleep")
        print("Screenshots: \(output.path)")
    }
}
