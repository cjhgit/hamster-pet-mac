import AppKit
import CoreText

@main struct Snapshot {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let font = root.appendingPathComponent("hamster-mac/Resources/1_Icicle Country 2.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        let suiteName = "hamster.snapshot.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let view = HamsterView(frame: NSRect(x: 0, y: 0, width: 742, height: 550), seed: 11042, preferences: preferences)
        let window = HamsterWindow(preferences: preferences)
        window.contentView = view
        precondition(!window.styleMask.contains(.titled) && window.canBecomeKey && window.canBecomeMain)
        let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        func contextMenu() -> NSMenu { view.menu(for: contextEvent)! }
        let initialFood = HamsterTestFoodCount()
        let menu = contextMenu()
        precondition(menu.item(at: 0)!.title == "置顶")
        menu.performActionForItem(at: 0)
        precondition(window.level == .floating)
        let pinnedMenu = contextMenu()
        precondition(pinnedMenu.item(at: 0)!.title == "取消置顶" && pinnedMenu.item(at: 0)!.state == .on)
        pinnedMenu.performActionForItem(at: 0)
        precondition(window.level == .normal && HamsterTestFoodCount() == initialFood)
        for index in HamsterWindow.sizes.indices {
            let sizes = contextMenu().item(at: 1)!.submenu!
            sizes.performActionForItem(at: index)
            let expected = HamsterWindow.sizes[index].size
            precondition(abs(window.frame.width - expected.width) < 1 && abs(window.frame.height - expected.height) < 1)
            precondition(contextMenu().item(at: 1)!.submenu!.item(at: index)!.state == .on)
            let restored = HamsterWindow(preferences: UserDefaults(suiteName: suiteName)!)
            precondition(abs(restored.frame.width - window.frame.width) < 1 &&
                         abs(restored.frame.height - window.frame.height) < 1 && restored.level == .normal,
                         "Restored \(restored.frame.size), expected \(window.frame.size)")
        }
        print("PASS: borderless focus, context menu pin/unpin, all size presets and menu selection states")
        window.setContentSize(NSSize(width: 600, height: 600 * 212 / 282))
        contextMenu().performActionForItem(at: 0)
        let restored = HamsterWindow(preferences: UserDefaults(suiteName: suiteName)!)
        precondition(abs(restored.frame.width - window.frame.width) < 1 &&
                     abs(restored.frame.height - window.frame.height) < 1 && restored.level == .floating)
        contextMenu().performActionForItem(at: 0)
        precondition(HamsterWindow(preferences: preferences).level == .normal)
        window.setContentSize(HamsterWindow.sizes[2].size)
        print("PASS: persisted preset/custom window sizes and pin/unpin restore in new windows")
        // Offscreen AppKit capture exercises the actual shipping view and layout.
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: "/private/tmp/hamster-native-window.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print("PASS: actual AppKit view rendered to \(output.path)")
        view.setFrameSize(NSSize(width: 375, height: 600))
        let narrow = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: narrow)
        try narrow.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/hamster-native-narrow.png"))
        print("PASS: narrow AppKit window rendered")
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Exercise the actual NSView event handlers at two window scales.
        for width: CGFloat in [742, 375] {
            view.setFrameSize(NSSize(width: width, height: width * 212 / 282))
            let scale = width / 282
            let initial = HamsterTestFoodCount()
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 201 * scale, y: 81 * scale)))
            precondition(HamsterTestFoodCount() == initial + 1 && HamsterTestDragging() == 1)
            view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 221 * scale, y: 61 * scale)))
            HamsterTestStep()
            precondition(abs(HamsterTestFoodX() - 220) < 0.000_01)
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 221 * scale, y: 61 * scale)))
            precondition(HamsterTestDragging() == 0)
        }
        print("PASS: real AppKit NSEvents exercise feeding, dragging, release and scaled coordinate mapping")
        precondition(contextMenu().item(at: 2)!.state == .on && HamsterTestWatermarkVisible() == 1)
        contextMenu().performActionForItem(at: 2)
        precondition(contextMenu().item(at: 2)!.state == .off && HamsterTestWatermarkVisible() == 0)
        view.setFrameSize(window.frame.size)
        let hidden = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: hidden)
        try hidden.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/hamster-native-no-watermark.png"))
        let restoredView = HamsterView(frame: view.frame, seed: 11042, preferences: UserDefaults(suiteName: suiteName)!)
        precondition(HamsterTestWatermarkVisible() == 0 && restoredView.menu(for: contextEvent)!.item(at: 2)!.state == .off)
        contextMenu().performActionForItem(at: 2)
        precondition(HamsterTestWatermarkVisible() == 1)
        let visibleView = HamsterView(frame: view.frame, seed: 11042, preferences: UserDefaults(suiteName: suiteName)!)
        precondition(HamsterTestWatermarkVisible() == 1 && visibleView.menu(for: contextEvent)!.item(at: 2)!.state == .on)
        print("PASS: watermark visibility toggles in engine and persists when hidden or shown")
        func capture(_ target: HamsterView) -> NSBitmapImageRep {
            let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds)!
            target.cacheDisplay(in: target.bounds, to: bitmap)
            return bitmap
        }
        let daylight = capture(view)
        precondition(contextMenu().item(at: 3)!.state == .off)
        contextMenu().performActionForItem(at: 3)
        let night = capture(view)
        try night.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/hamster-native-night.png"))
        func brightness(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let color = night.colorAt(x: Int((x + 1) / 282 * CGFloat(night.pixelsWide)),
                                      y: Int((y + 1) / 212 * CGFloat(night.pixelsHigh)))!.usingColorSpace(.sRGB)!
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        precondition(brightness(257, 49) > brightness(72, 178) * 1.15)
        precondition(brightness(72, 178) > 0.18 && brightness(72, 178) < 0.35 && brightness(257, 49) < 0.65)
        precondition(abs(brightness(220, 49) - brightness(72, 178)) < 0.03)
        precondition(brightness(25, 60) > brightness(72, 178) && brightness(25, 60) < 0.65)
        let nightView = HamsterView(frame: view.frame, seed: 11042, preferences: UserDefaults(suiteName: suiteName)!)
        precondition(nightView.menu(for: contextEvent)!.item(at: 3)!.state == .on)
        nightView.setFrameSize(HamsterWindow.sizes[0].size)
        try capture(nightView).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/hamster-native-night-small.png"))
        contextMenu().performActionForItem(at: 3)
        precondition(capture(view).representation(using: .png, properties: [:]) == daylight.representation(using: .png, properties: [:]))
        let dayView = HamsterView(frame: view.frame, seed: 11042, preferences: UserDefaults(suiteName: suiteName)!)
        precondition(dayView.menu(for: contextEvent)!.item(at: 3)!.state == .off)
        print("PASS: night lighting falls off with distance, day/night restore exactly, and theme preferences persist")
    }
}
