import AppKit
import SceneKit
import Darwin

@main struct Benchmark3D {
    @MainActor static func pump(_ seconds: Double) {
        let stop = Timer(timeInterval: seconds, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        RunLoop.main.add(stop, forMode: .common); NSApp.run(); stop.invalidate()
    }
    static func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "current"
        let sampleSeconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 15 : 15
        precondition(sampleSeconds >= 6 && sampleSeconds <= 120)
        let filterIndex = CommandLine.arguments.firstIndex(of: "--scenario")
        let scenarioFilter = filterIndex.map { index -> String in
            precondition(index + 1 < CommandLine.arguments.count, "--scenario needs a scenario name")
            let value = CommandLine.arguments[index + 1]
            precondition(["idle", "walk-turn", "wheel-day", "wheel-night", "sleep"].contains(value), "Unknown scenario")
            return value
        }
        var records: [[String: Any]] = []
        let suite = "hamster.perf.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let window = HamsterWindow(preferences: prefs)
        window.setContentSize(.init(width: 742, height: 558)); window.level = .floating; window.center()
        // Keep the workload visible without mouse movement/dragging changing
        // the deterministic scenario or stealing focus from the user's work.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = HamsterView(frame: .init(origin: .zero, size: .init(width: 742, height: 558)), seed: 11042, preferences: prefs)
        window.contentView = view; window.orderFrontRegardless()
        var walkChecks = 0, activeWalkChecks = 0
        func measure(_ name: String, _ seconds: Double, running: Bool? = nil) {
            let start = ProcessInfo.processInfo.systemUptime, c = cpu(), f = view.simulationFrames
            let firstRender = view.scene3D!.view.submittedFrames
            let previousChecks = walkChecks, previousActive = activeWalkChecks
            pump(seconds)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let backend = view.scene3D!.bodyMeshingBackend
            let renderFPS = Double(view.scene3D!.view.submittedFrames - firstRender) / elapsed
            precondition(backend == (CommandLine.arguments.contains("--hamster-cpu-body") ? "CPU" : "Metal compute"), "Unexpected meshing fallback")
            func elements(_ node: SCNNode) -> Int {
                guard !node.isHidden else { return 0 }
                return (node.geometry?.elements.filter { $0.primitiveCount > 0 }.count ?? 0) + node.childNodes.reduce(0) { $0 + elements($1) }
            }
            let record: [String: Any] = ["name": name, "cpuPercent": (cpu()-c)/elapsed*100, "fps": Double(view.simulationFrames-f)/elapsed,
                                       "seconds": elapsed, "renderFPS": renderFPS, "bodyBackend": backend, "visibleGeometryElements": elements(view.scene3D!.scene.rootNode),
                                       "batched": !CommandLine.arguments.contains("--hamster-unbatched") && !CommandLine.arguments.contains("--legacy-baseline"),
                                       "flattened": !CommandLine.arguments.contains("--hamster-unflattened") && !CommandLine.arguments.contains("--legacy-baseline"),
                                       "movementChecks": walkChecks - previousChecks, "activeMovementChecks": activeWalkChecks - previousActive]
            let fps = Double(view.simulationFrames-f)/elapsed
            print(record)
            let shouldRun = running ?? (!view.isPlaybackPaused && window.isVisible && !NSApp.isHidden)
            precondition(shouldRun ? (29...31).contains(fps) : fps == 0, "Simulation FPS changed in \(name): \(fps)")
            if ["walk-turn", "wheel-day", "wheel-night"].contains(name) {
                precondition((29...31).contains(renderFPS), "Rendering must remain at 30 FPS in \(name): \(renderFPS)")
            }
            if name == "walk-turn" {
                precondition(walkChecks - previousChecks > 30 && Double(activeWalkChecks - previousActive) / Double(walkChecks - previousChecks) > 0.75,
                             "Walking benchmark must keep moving/turning throughout the sample")
            }
            records.append(record)
        }
        let center = NSWorkspace.shared.notificationCenter
        if scenarioFilter == nil && !CommandLine.arguments.contains("--legacy-baseline") {
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            pump(0.4)
            measure("display-asleep", 3, running: false)
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            pump(0.4)
            measure("session-inactive", 3, running: false)
            center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        }
        for (name, scenario, night) in [("idle", Int32(0), false), ("walk-turn", 1, false), ("wheel-day", 2, false), ("wheel-night", 2, true), ("sleep", 6, false)] {
            if let scenarioFilter, name != scenarioFilter { continue }
            let menu = view.makeSettingsMenu()
            if (menu.item(at: 3)!.state == .on) != night { menu.performActionForItem(at: 3) }
            HamsterTestConfigureScenario(scenario, 0); view.scene3D!.update(night: night)
            var walkTimer: Timer?
            if scenario == 1 {
                var previous = HamsterEngineGetSceneStateForTest()
                walkTimer = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated {
                    let state = HamsterEngineGetSceneStateForTest()
                    walkChecks += 1
                    if abs(state.x - previous.x) > 0.01 || abs(state.heading - previous.heading) > 0.001 { activeWalkChecks += 1 }
                    if state.x > 180 { HamsterTestRetarget(30, 205) }
                    else if state.x < 115 { HamsterTestRetarget(260, 205) }
                    previous = state
                } }
                RunLoop.main.add(walkTimer!, forMode: .common)
            }
            pump(3); measure(name, sampleSeconds)
            walkTimer?.invalidate()
        }
        let menu = view.makeSettingsMenu(); menu.performActionForItem(at: menu.indexOfItem(withTitle: "暂停播放"))
        measure("paused", 3)
        window.orderOut(nil); measure("hidden-paused", 3)
        let resumeMenu = view.makeSettingsMenu()
        resumeMenu.performActionForItem(at: resumeMenu.indexOfItem(withTitle: "继续播放"))
        measure("hidden-playing", 3)
        try FileManager.default.createDirectory(atPath: "/private/tmp/hamster-3d-performance", withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/private/tmp/hamster-3d-performance/\(variant).json"))
        // Actual simulation and scene CPU time. Do not pre-build the reference
        // CPU mesh: that would move work outside the measured rendering path.
        let engine = HamsterEngineCreate(11042)!
        defer { HamsterEngineDestroy(engine) }
        HamsterEngineStart(engine)
        let renderer = Hamster3DScene(engine: engine)
        for (name, mode) in [("idle", Int32(0)), ("walk", 1), ("wheel", 2)] {
            HamsterTestConfigureScenario(mode, 0)
            var step = 0.0, scene = 0.0, wall = 0.0
            for _ in 0..<180 { autoreleasepool {
                let a = cpu(); HamsterTestStep(); let b = cpu()
                let start = ProcessInfo.processInfo.systemUptime
                renderer.update(night: false); let d = cpu()
                wall += ProcessInfo.processInfo.systemUptime - start
                step += b-a; scene += d-b
            } }
            let body = HamsterEngineBuildBodyMesh(engine)
            precondition(body.indexCount % 3 == 0 && body.indexCount > body.vertexCount)
            precondition(UnsafeBufferPointer(start: body.indices, count: Int(body.indexCount)).allSatisfy { $0 < body.vertexCount })
            print("STAGES", name, "backend", renderer.bodyMeshingBackend, "simulationCPUms", step/180*1000,
                  "sceneCPUms", scene/180*1000, "sceneWallms", wall/180*1000, "lastBodyGPUms", renderer.bodyGPUSeconds*1000,
                  "bodyVertices", body.vertexCount, "triangleCorners", body.indexCount)
        }
    }
}
