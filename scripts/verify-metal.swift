import AppKit
import CoreText
import Darwin

@main struct VerifyMetal {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let font = URL(fileURLWithPath: "hamster-mac/Resources/1_Icicle Country 2.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        if ProcessInfo.processInfo.arguments.contains("--benchmark") {
            try benchmark()
            return
        }
        let engine = HamsterEngineCreate(11042)!
        defer { HamsterEngineDestroy(engine) }
        HamsterEngineStart(engine)
        guard let renderer = HamsterMetalRenderer(engine: engine) else { fatalError("No Metal renderer") }
        print("GPU: \(renderer.device.name), \(renderer.view.sampleCount)x MSAA")
        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        var previous = 0
        for frame in [0, 100, 500, 5000] {
            for _ in previous..<frame { HamsterEngineStep(engine, 1000 / 30) }
            previous = frame
            if frame == 100 { HamsterEngineMouse(engine, 200, 80, 1) }
            if frame == 500 { HamsterEngineMouse(engine, 0, 0, 2) }
            for width in [742, 1484] { for night in [false, true] {
                let height = Int(ceil(Double(width) * 212 / 282))
                renderer.night = night
                guard let gpu = renderer.snapshot(size: CGSize(width: width, height: height)) else { fatalError("GPU readback failed") }
                let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.scaleBy(x: CGFloat(width) / 282, y: -CGFloat(height) / 212)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: 282, height: 212))
                ctx.translateBy(x: 1, y: 1)
                HamsterEngineDrawWithTheme(engine, ctx, night ? 1 : 0)
                if night {
                    ctx.setBlendMode(.multiply)
                    ctx.setFillColor(NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: -1, y: -1, width: 282, height: 212))
                    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                        NSColor(srgbRed: 1, green: 0.70, blue: 0.35, alpha: 0.55).cgColor,
                        NSColor(srgbRed: 1, green: 0.70, blue: 0.35, alpha: 0).cgColor
                    ] as CFArray, locations: [0, 1])!
                    ctx.setBlendMode(.screen)
                    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 259, y: 40), startRadius: 0,
                                           endCenter: CGPoint(x: 259, y: 40), endRadius: 32, options: [])
                }
                let a = rgba(gpu), b = rgba(ctx.makeImage()!)
                var delta = 0, large = 0
                for pixel in 0..<(width * height) {
                    var worst = 0
                    for channel in 0..<3 {
                        let d = abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel]))
                        delta += d; worst = max(worst, d)
                    }
                    if worst > 64 { large += 1 }
                }
                let mean = Double(delta) / Double(width * height * 3)
                let fraction = Double(large) / Double(width * height)
                print(String(format: "METAL: frame %d, %dpx %@, mean delta %.3f/255, large delta %.3f%%", frame, width, night ? "night" : "day", mean, fraction * 100))
                if width == 1484 {
                    let name = "/private/tmp/hamster-metal-\(frame)-\(night ? "night" : "day").png"
                    try NSBitmapImageRep(cgImage: gpu).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
                }
                precondition(mean < 3 && fraction < 0.02, "Metal geometry must match the reference within rasterization differences")
            } }
        }
        HamsterEngineSetWatermarkVisible(engine, 0)
        precondition(renderer.snapshot(size: CGSize(width: 371, height: 279)) != nil)
        print("PASS: Metal fill/stroke coverage, masks, depth, glyphs, day/night shading, scale and watermark")
    }

    @MainActor static func pump(for duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        RunLoop.main.add(stop, forMode: .common)
        NSApp.run()
        stop.invalidate()
    }

    @MainActor static func benchmark() throws {
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        for metal in [false, true] { for night in [false, true] {
            let suite = "hamster.benchmark.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            preferences.set(night, forKey: "hamster.darkMode")
            let window = HamsterWindow(preferences: preferences)
            window.setContentSize(HamsterWindow.sizes[2].size)
            let view = HamsterView(frame: NSRect(origin: .zero, size: window.frame.size), seed: 11042,
                                   preferences: preferences, prefersMetal: metal, prefers3D: false)
            precondition(view.usesMetal == metal)
            window.contentView = view
            // Keep the measured window visible when focus returns to the editor.
            window.level = .floating
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            pump(for: 1)
            let cpu = cpuTime(), start = ProcessInfo.processInfo.systemUptime
            let frames = view.simulationFrames, gpu = view.gpuSubmittedFrames, cpuFrames = view.cpuRenderedFrames
            pump(for: 8)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let percent = (cpuTime() - cpu) / elapsed * 100
            let rendered = metal ? view.gpuSubmittedFrames - gpu : view.cpuRenderedFrames - cpuFrames
            print(String(format: "CPU: %@ %@, %.2f%% of one core, %.1f simulation FPS, %d rendered frames, %.0fx backing scale",
                         metal ? "Metal" : "CoreGraphics", night ? "night" : "day", percent,
                         Double(view.simulationFrames - frames) / elapsed, rendered, window.backingScaleFactor))
            fflush(stdout)
            precondition(view.simulationFrames - frames > 200 && rendered > 200, "Benchmark requires a visible, rendering window")
            window.orderOut(nil)
            pump(for: 0.2)
            let hiddenCPU = cpuTime(), hiddenStart = ProcessInfo.processInfo.systemUptime
            let hiddenGPU = view.gpuSubmittedFrames
            pump(for: 1)
            print(String(format: "HIDDEN: %.2f%% CPU, %d GPU submissions", (cpuTime() - hiddenCPU) / (ProcessInfo.processInfo.systemUptime - hiddenStart) * 100,
                         view.gpuSubmittedFrames - hiddenGPU))
            precondition(view.gpuSubmittedFrames == hiddenGPU)
            window.close()
            preferences.removePersistentDomain(forName: suite)
        } }
    }
}
