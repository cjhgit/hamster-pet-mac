import AppKit
import CoreText

@main struct Snapshot {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let font = root.appendingPathComponent("hamster-mac/Resources/1_Icicle Country 2.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        let view = HamsterView(frame: NSRect(x: 0, y: 0, width: 742, height: 605), seed: 11042)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
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
            view.setFrameSize(NSSize(width: width, height: 605))
            let scale = width / 742
            let top = (605 - (550 * scale + 54.4)) / 2
            let initial = HamsterTestFoodCount()
            view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 500 * scale, y: top + 200 * scale)))
            precondition(HamsterTestFoodCount() == initial + 1 && HamsterTestDragging() == 1)
            view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 540 * scale, y: top + 150 * scale)))
            HamsterTestStep()
            precondition(abs(HamsterTestFoodX() - (540 - 31) * 280 / 653) < 0.000_01)
            view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 540 * scale, y: top + 150 * scale)))
            precondition(HamsterTestDragging() == 0)
        }
        print("PASS: real AppKit NSEvents exercise feeding, dragging, release and scaled coordinate mapping")
    }
}
