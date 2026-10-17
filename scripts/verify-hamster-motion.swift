import AppKit
import SceneKit
import simd
import Darwin
import ImageIO
import UniformTypeIdentifiers

@main struct VerifyHamsterMotion {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: "/private/tmp/hamster-motion", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "hamster.motion.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func png(_ image: NSImage, _ path: URL) throws {
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        }
        func skinVertices(_ renderer: Hamster3DScene) -> [SIMD3<Float>] {
            let vertices = renderer.hamsterBodyVertices
            precondition(!vertices.isEmpty && vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            return vertices
        }
        let scenarios: [(String, Int32, Double)] = [
            ("idle-front", 0, .pi / 2), ("idle-side", 0, 0),
            ("walk-right", 1, 0), ("walk-left", 7, .pi), ("turn", 1, 0),
            ("wheel-right", 2, 0), ("wheel-left", 2, .pi),
            ("eat-front", 3, .pi / 2), ("eat-side", 3, 0),
            ("wash-front", 4, .pi / 2), ("wash-side", 4, 0),
            ("drink", 5, .pi), ("sleep", 6, 0)
        ]
        var summary: [[String: Any]] = []
        for (name, scenario, heading) in scenarios {
            let view = HamsterView(frame: .init(x: 0, y: 0, width: 800, height: 600), seed: 11042, preferences: preferences)
            let renderer = view.scene3D!
            let expectedBackend = ProcessInfo.processInfo.arguments.contains("--hamster-cpu-body") ? "CPU" : "Metal compute"
            precondition(renderer.bodyMeshingBackend == expectedBackend, "Unexpected body backend: \(renderer.bodyMeshingBackend)")
            HamsterTestConfigureScenario(scenario, heading)
            let directory = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let surroundings = renderer.scene.rootNode.childNodes.filter { $0 !== renderer.hamster && $0.camera == nil && $0.light == nil }
            let visibility = surroundings.map(\.isHidden)
            surroundings.forEach { $0.isHidden = true }
            var previous: [SIMD3<Float>] = []
            var previousVelocity: [SIMD3<Float>] = []
            var maxJump: Float = 0, maxJerk: Float = 0, maxWheelError: Float = 0
            var motion: [[String: Any]] = []
            var updateTimes: [Double] = []
            var overlaps: [Double] = []
            var minimumRunningSpeed = Double.infinity
            var minimumHipToWaist: Float = .infinity
            let animated = ["walk-right", "wheel-right", "turn"].contains(name)
            let gif = animated ? CGImageDestinationCreateWithURL(directory.appendingPathComponent("comparison.gif") as CFURL, UTType.gif.identifier as CFString, 120, nil) : nil
            if let gif { CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
            let start = ProcessInfo.processInfo.systemUptime
            for frame in 0..<120 {
                try autoreleasepool {
                    if name == "turn" && frame == 0 { HamsterTestRetarget(25, 205) }
                    if name == "turn" && frame == 65 { HamsterTestRetarget(255, 205) }
                    HamsterTestStep()
                    let updateStart = ProcessInfo.processInfo.systemUptime
                    renderer.update(night: false)
                    precondition(renderer.bodyMeshingBackend == expectedBackend, "GPU body must not silently fall back")
                    updateTimes.append((ProcessInfo.processInfo.systemUptime - updateStart) * 1000)
                    renderer.inspectHamster()
                    let state = HamsterEngineGetSceneStateForTest()
                    if scenario == 2 {
                        precondition(state.onWheel != 0 && state.speed >= 0.79, "Wheel comparison must run at full speed")
                        minimumRunningSpeed = min(minimumRunningSpeed, state.speed)
                    }
                    let points = (0..<24).map { index -> SIMD3<Float> in
                        let p = HamsterTestRigPoint(Int32(index))
                        precondition(p.x.isFinite && p.y.isFinite && p.z.isFinite)
                        return .init(Float(p.x), Float(p.y), Float(p.z))
                    }
                    let rendered = renderer.hamsterLandmarks
                    if scenario == 2 && frame < 8 {
                        let center = (points[0] + points[1]) * 0.5
                        let axis = simd_normalize(points[1] - points[0])
                        let side = SIMD3<Float>(sin(Float(state.heading)), 0, -cos(Float(state.heading)))
                        let down = simd_normalize(simd_cross(side, axis))
                        let halfLength = simd_distance(points[0], points[1]) * 0.5 + 20
                        var hip: Float = 0, waist: Float = 0
                        for vertex in skinVertices(renderer) {
                            let local = vertex - center, u = simd_dot(local, axis) / halfLength
                            // Measure the upper flanks so stretched legs do not mask
                            // the waist. An ellipsoid has the opposite proportions.
                            if simd_dot(local, down) <= 0 {
                                if abs(u + 0.38) < 0.04 { hip = max(hip, abs(simd_dot(local, side))) }
                                if abs(u) < 0.04 { waist = max(waist, abs(simd_dot(local, side))) }
                            }
                        }
                        let ratio = hip / waist
                        precondition(ratio.isFinite && ratio > 1.08, "Running body lost its fuller hips and narrower waist")
                        minimumHipToWaist = min(minimumHipToWaist, ratio)
                    }
                    precondition(rendered.count == points.count)
                    for i in points.indices {
                        let error = simd_distance(rendered[i], points[i])
                        precondition(error < (state.onWheel != 0 ? 7 : 0.001), "Unexpected deviation from reference articulation")
                    }
                    let world = rendered.map { p -> SIMD3<Float> in
                        let rotation = Float(-state.rotation * .pi / 180)
                        return .init(Float(state.x - 140) + p.x * cos(rotation) - p.y * sin(rotation),
                                     Float(210 - state.y) + p.x * sin(rotation) + p.y * cos(rotation), p.z)
                    }
                    if !previous.isEmpty {
                        let velocity = zip(world, previous).map(-)
                        maxJump = max(maxJump, velocity.map(simd_length).max()!)
                        if !previousVelocity.isEmpty { maxJerk = max(maxJerk, zip(velocity, previousVelocity).map { simd_length($0 - $1) }.max()!) }
                        previousVelocity = velocity
                    }
                    previous = world
                    if state.onWheel != 0 {
                        for i in [8, 13, 18, 23] {
                            let distance = simd_length(SIMD2<Float>(world[i].x - 27, world[i].y - 105))
                            maxWheelError = max(maxWheelError, max(0, distance - 95.6))
                            precondition(distance <= 95.61, "Foot penetrates the wheel")
                        }
                    }
                    motion.append(["frame": frame, "x": state.x, "y": state.y, "heading": state.heading,
                                   "posture": state.posture, "headPitch": state.headPitch, "phase": state.legPhase, "speed": state.speed,
                                   "wheel": state.onWheel, "eating": state.eating, "washing": state.cleaning,
                                   "points": world.map { [$0.x, $0.y, $0.z] }])
                    if frame % 10 == 0 || animated || (scenario == 2 && frame < 8) {
                        let sceneImage = renderer.snapshot(size: .init(width: 640, height: 480))
                        if frame % 10 == 0 || (scenario == 2 && frame < 8) { try png(sceneImage, directory.appendingPathComponent(String(format: "3d-%03d.png", frame))) }
                        let center = renderer.inspectionCenter
                        let width = 640, height = 480
                        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.setFillColor(NSColor.white.cgColor); context.fill(.init(x: 0, y: 0, width: width, height: height))
                        let scale = CGFloat(height) / (218 / 2.1)
                        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
                        context.translateBy(x: -(CGFloat(center.x) + 140) + CGFloat(width) / scale / 2,
                                            y: -(210 - CGFloat(center.y)) + CGFloat(height) / scale / 2)
                        HamsterTestDrawHamster(context)
                        let image = NSImage(cgImage: context.makeImage()!, size: .init(width: width, height: height))
                        if frame % 10 == 0 || (scenario == 2 && frame < 8) { try png(image, directory.appendingPathComponent(String(format: "reference-%03d.png", frame))) }
                        if let gif {
                            let pair = NSImage(size: .init(width: 960, height: 390))
                            pair.lockFocus()
                            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 960, height: 390).fill()
                            image.draw(in: .init(x: 0, y: 0, width: 480, height: 360))
                            sceneImage.draw(in: .init(x: 480, y: 0, width: 480, height: 360))
                            ("原版" as NSString).draw(at: .init(x: 12, y: 366), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
                            ("3D · 同一模拟帧" as NSString).draw(at: .init(x: 492, y: 366), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
                            pair.unlockFocus()
                            let cg = NSBitmapImageRep(data: pair.tiffRepresentation!)!.cgImage!
                            CGImageDestinationAddImage(gif, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame % 3 == 2 ? 0.04 : 0.03]] as CFDictionary)
                        }
                        func silhouette(_ image: NSImage) -> [Bool] {
                            var rgba = [UInt8](repeating: 255, count: width * height * 4)
                            rgba.withUnsafeMutableBytes { bytes in
                                let c = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                                let cg = NSBitmapImageRep(data: image.tiffRepresentation!)!.cgImage!
                                c.draw(cg, in: .init(x: 0, y: 0, width: width, height: height))
                            }
                            return stride(from: 0, to: rgba.count, by: 4).map { min(rgba[$0], rgba[$0 + 1], rgba[$0 + 2]) < 248 }
                        }
                        let referenceMask = silhouette(image), sceneMask = silhouette(sceneImage)
                        var intersection = 0, union = 0
                        for (a, b) in zip(referenceMask, sceneMask) {
                            if a || b { union += 1 }
                            if a && b { intersection += 1 }
                        }
                        overlaps.append(Double(intersection) / Double(max(1, union)))
                    }
                    renderer.scene.rootNode.childNodes.filter { $0 !== renderer.hamster && $0.camera == nil && $0.light == nil }.forEach { $0.isHidden = true }
                }
            }
            if let gif { precondition(CGImageDestinationFinalize(gif)) }
            if scenario == 2 {
                let cycle = NSImage(size: .init(width: 960, height: 8 * 390))
                cycle.lockFocus()
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 960, height: 8 * 390).fill()
                for phase in 0..<8 {
                    let y = CGFloat((7 - phase) * 390)
                    for (column, prefix) in ["reference", "3d"].enumerated() {
                        let path = directory.appendingPathComponent(String(format: "%@-%03d.png", prefix, phase))
                        NSImage(contentsOf: path)!.draw(in: .init(x: CGFloat(column * 480), y: y, width: 480, height: 360))
                    }
                    ("全速 \(minimumRunningSpeed) · 连续第 \(phase + 1) 帧   原版 / 3D" as NSString).draw(at: .init(x: 12, y: y + 366), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
                }
                cycle.unlockFocus()
                try png(cycle, directory.appendingPathComponent("full-speed-cycle.png"))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            precondition(overlaps.min()! > 0.80, "Silhouette diverges from the original: \(name)")
            updateTimes.sort()
            var record: [String: Any] = ["silhouetteIoUMean": overlaps.reduce(0, +) / Double(overlaps.count),
                                         "silhouetteIoUMin": overlaps.min()!,
                                         "poseUpdateP95Milliseconds": updateTimes[Int(Double(updateTimes.count - 1) * 0.95)],
                                         "scenario": name, "frames": 120, "maxFrameDisplacement": maxJump,
                                         "maxVelocityChange": maxJerk, "maxWheelContactError": maxWheelError,
                                         "secondsIncludingSnapshots": elapsed]
            if scenario == 2 { record["minimumHipToWaistWidthRatio"] = minimumHipToWaist }
            summary.append(record)
            try JSONSerialization.data(withJSONObject: motion, options: [.sortedKeys]).write(to: directory.appendingPathComponent("motion.json"))
            print("SCENARIO", record)
            // Inspect front, rear, side, and above at the end of every actual behavior.
            for (i, angle) in [Float(0), .pi / 2, .pi, -.pi / 2].enumerated() {
                renderer.inspectHamster(yaw: angle, pitch: 0.15)
                try png(renderer.snapshot(size: .init(width: 640, height: 480)), directory.appendingPathComponent("angle-\(i).png"))
            }
            if scenario == 2 {
                for (node, hidden) in zip(surroundings, visibility) { node.isHidden = hidden }
                for preset in [0, 1, 4] {
                    renderer.preset(preset)
                    try png(renderer.snapshot(size: .init(width: 960, height: 720)), directory.appendingPathComponent("in-wheel-\(preset).png"))
                }
            }
        }
        let reviewCases = ["idle-front", "wheel-right", "turn", "eat-front", "wash-side", "drink", "sleep"]
        let overview = NSImage(size: .init(width: 960, height: reviewCases.count * 390))
        overview.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 960, height: reviewCases.count * 390).fill()
        for (i, name) in reviewCases.enumerated() {
            let y = CGFloat((reviewCases.count - i - 1) * 390)
            let folder = output.appendingPathComponent(name)
            NSImage(contentsOf: folder.appendingPathComponent("reference-040.png"))!.draw(in: .init(x: 0, y: y, width: 480, height: 360))
            NSImage(contentsOf: folder.appendingPathComponent("3d-040.png"))!.draw(in: .init(x: 480, y: y, width: 480, height: 360))
            (name + "   原版 / 同帧 3D" as NSString).draw(at: .init(x: 12, y: y + 366), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
        }
        overview.unlockFocus()
        try png(overview, output.appendingPathComponent("overview.png"))
        // Measure animation updates without readbacks and comparison rendering.
        let performanceView = HamsterView(frame: .init(x: 0, y: 0, width: 800, height: 600), seed: 11042, preferences: preferences)
        HamsterTestConfigureScenario(2, 0)
        var timings: [Double] = []
        for _ in 0..<180 {
            autoreleasepool {
                HamsterTestStep()
                let start = ProcessInfo.processInfo.systemUptime
                performanceView.scene3D!.update(night: false)
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        timings.sort()
        print("PERFORMANCE full-speed pose update: mean \(timings.reduce(0, +) / Double(timings.count)) ms, p95 \(timings[170]) ms")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
        print("PASS: thirteen scenarios, 1,560 simulated frames, paired reference images, three continuous gait comparisons and 52 orbit views")
        print("OUTPUT", output.path)
    }
}
