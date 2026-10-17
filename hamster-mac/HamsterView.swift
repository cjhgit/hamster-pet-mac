import AppKit
import CoreText
import SwiftUI

final class HamsterWindow: NSWindow, NSWindowDelegate {
    private static let settingsKey = "hamster.window"
    private let preferences: UserDefaults
    private var savesSettings = false

    static let sizes: [(name: String, size: NSSize)] = [
        ("小（50%）", NSSize(width: 371, height: 275)),
        ("中（75%）", NSSize(width: 556.5, height: 412.5)),
        ("大（100%）", NSSize(width: 742, height: 550))
    ]

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let settings = preferences.dictionary(forKey: Self.settingsKey) ?? [:]
        var size = Self.sizes[2].size
        if let width = settings["width"] as? Double, let height = settings["height"] as? Double,
           width.isFinite, height.isFinite, width >= 320, height >= 320 * 550 / 742,
           abs(width / height - 742 / 550) < 0.01 {
            size = NSSize(width: width, height: height)
        }
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable, .miniaturizable, .closable],
                   backing: .buffered, defer: false)
        title = "Canvas 仓鼠"
        minSize = NSSize(width: 320, height: 320 * 550 / 742)
        contentAspectRatio = NSSize(width: 742, height: 550)
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        level = settings["pinned"] as? Bool == true ? .floating : .normal
        delegate = self
        savesSettings = true
    }

    override var level: NSWindow.Level {
        didSet { saveSettings() }
    }

    func windowDidResize(_ notification: Notification) { saveSettings() }

    private func saveSettings() {
        guard savesSettings else { return }
        preferences.set(["width": frame.width, "height": frame.height, "pinned": level == .floating],
                        forKey: Self.settingsKey)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct HamsterCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> HamsterView { HamsterView() }
    func updateNSView(_ nsView: HamsterView, context: Context) {}
}

/// AppKit input and Core Graphics rendering, with no browser or script runtime.
final class HamsterView: NSView {
    private let engine: UnsafeMutableRawPointer
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previousTime = ProcessInfo.processInfo.systemUptime
    private var accumulator = 0.0
    private var pendingTimerMilliseconds = 0.0
    private var draggingFood = false
    private var pressedAuthor = false
    private var authorFocused = false
    private var mouseTracking: NSTrackingArea?
    private static let background = NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1)
    private static let authorURL = URL(string: "http://abowman.com/google-modules/hamster")!

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, seed: UInt32.random(in: .min ... .max))
    }

    init(frame frameRect: NSRect, seed: UInt32) {
        engine = HamsterEngineCreate(seed)!
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        // Register the original author font once for the process.
        if let font = Bundle.main.url(forResource: "1_Icicle Country 2", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        applyLaunchColors()
        HamsterEngineStart(engine)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("宠物仓鼠")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "访问原作者 aBowman 的仓鼠页面", handler: {
            NSWorkspace.shared.open(Self.authorURL)
        })])
        setAccessibilityHelp("点击空白处投食，按住拖动或抛出食物；点击黄色轮心让仓鼠上跑轮。移动鼠标可唤醒仓鼠。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        HamsterEngineDestroy(engine)
    }

    private func applyLaunchColors() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--hamster-query"), args.indices.contains(index + 1),
              let query = URLComponents(string: "?" + args[index + 1])?.queryItems else { return }
        let supported: Set<String> = ["bgColor", "bodyColor", "earColor", "snoutColor", "eyeColor", "feetColor", "tailColor", "waterColor", "foodColor", "wheelColor", "wheelOuterColor", "wheelCenterColor", "wheelSpokeColor"]
        for item in query where item.name.hasPrefix("up_") {
            let name = String(item.name.dropFirst(3))
            if supported.contains(name), let hex = item.value, hex.count == 6,
               hex.allSatisfy({ $0.isASCII && $0.isHexDigit }), let value = UInt32(hex, radix: 16) {
                name.withCString { HamsterEngineSetColor(engine, $0, value) }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window {
            window.acceptsMouseMovedEvents = true
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActivity() }
                })
            }
        }
        updateActivity()
    }

    private func updateActivity() {
        if window?.isKeyWindow != true { releaseFood() }
        let visible = window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false && !NSApp.isHidden
        if visible && timer == nil {
            accumulator = 0
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            needsDisplay = true
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - previousTime)
        previousTime = now
        // Preserve 30 FPS physics without a busy loop or unbounded catch-up.
        accumulator += min(elapsed, 0.1)
        pendingTimerMilliseconds += elapsed * 1000
        var advanced = false
        while accumulator + 0.000_001 >= 1 / 30 {
            HamsterEngineStep(engine, pendingTimerMilliseconds)
            pendingTimerMilliseconds = 0
            accumulator -= 1 / 30
            advanced = true
        }
        if advanced { needsDisplay = true }
    }

    private var canvasRect: NSRect {
        let width = min(bounds.width, bounds.height * 742 / 550)
        let height = width * 550 / 742
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    private func canvasPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = canvasRect
        return NSPoint(x: (point.x - rect.minX) * 742 / rect.width,
                       y: (point.y - rect.minY) * 550 / rect.height)
    }

    private func stagePoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: (point.x - 31) * 280 / 653, y: (point.y - 25) * 210 / 490)
    }

    private func isInStage(_ point: NSPoint) -> Bool {
        (0 ... 280).contains(point.x) && (0 ... 210).contains(point.y)
    }

    private var authorRect: NSRect {
        NSRect(x: 31 + 220 * 653 / 280, y: 25 + 490 / 210, width: 56 * 653 / 280, height: 14 * 490 / 210)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = canvasRect
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 742, y: rect.width / 742)
        let rim = CGPath(roundedRect: CGRect(x: 9, y: 9, width: 698, height: 523), cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(rim)
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        context.addPath(rim)
        context.setStrokeColor(NSColor(srgbRed: 183 / 255, green: 183 / 255, blue: 183 / 255, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        context.clip(to: CGRect(x: 30, y: 24, width: 655, height: 492))
        context.translateBy(x: 31, y: 25)
        context.scaleBy(x: 653 / 280, y: 490 / 210)
        HamsterEngineDraw(engine, context)
        context.restoreGState()
        if authorFocused && window?.firstResponder === self {
            let focus = authorRect.insetBy(dx: -2, dy: -2)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 742, y: rect.width / 742)
            context.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor)
            context.setLineWidth(2)
            context.stroke(focus)
            context.restoreGState()
        }

    }

    override func menu(for event: NSEvent) -> NSMenu? {
        releaseFood()
        let menu = NSMenu()
        let pinned = window?.level == .floating
        let pin = menu.addItem(withTitle: pinned ? "取消置顶" : "置顶", action: #selector(toggleOnTop(_:)), keyEquivalent: "")
        pin.target = self
        pin.state = pinned ? .on : .off

        let sizeMenu = NSMenu(title: "窗口大小")
        for (index, preset) in HamsterWindow.sizes.enumerated() {
            let item = sizeMenu.addItem(withTitle: preset.name,
                                        action: #selector(changeWindowSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            if let size = window?.contentLayoutRect.size,
               abs(size.width - preset.size.width) < 1, abs(size.height - preset.size.height) < 1 {
                item.state = .on
            }
        }
        menu.addItem(withTitle: "窗口大小", action: nil, keyEquivalent: "").submenu = sizeMenu
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "关闭窗口", action: #selector(closeWindow(_:)), keyEquivalent: "")
        close.target = self
        return menu
    }

    @objc private func toggleOnTop(_ sender: NSMenuItem) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc private func changeWindowSize(_ sender: NSMenuItem) {
        guard let window, HamsterWindow.sizes.indices.contains(sender.tag) else { return }
        let size = HamsterWindow.sizes[sender.tag].size
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
    }

    @objc private func closeWindow(_ sender: NSMenuItem) { window?.close() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        mouseTracking = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = canvasRect
        let scale = rect.width / 742
        let author = authorRect
        addCursorRect(NSRect(x: rect.minX + author.minX * scale, y: rect.minY + author.minY * scale, width: author.width * scale, height: author.height * scale), cursor: .pointingHand)
        addCursorRect(NSRect(x: rect.minX + (31 + 157 * 653 / 280) * scale, y: rect.minY + (25 + 95 * 490 / 210) * scale, width: 20 * 653 / 280 * scale, height: 20 * 490 / 210 * scale), cursor: .pointingHand)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            authorFocused.toggle()
            needsDisplay = true
        } else if authorFocused && (event.keyCode == 36 || event.keyCode == 49) {
            NSWorkspace.shared.open(Self.authorURL)
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let canvas = canvasPoint(event)
        let point = stagePoint(canvas)
        if isInStage(point) && !authorRect.contains(canvas) { HamsterEngineMouse(engine, point.x, point.y, 0) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        window?.makeFirstResponder(self)
        let canvas = canvasPoint(event)
        pressedAuthor = authorRect.contains(canvas)
        authorFocused = false
        if pressedAuthor { return }
        let point = stagePoint(canvas)
        if isInStage(point) {
            draggingFood = true
            HamsterEngineMouse(engine, point.x, point.y, 1)
        } else {
            window?.performDrag(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard draggingFood else { return }
        let point = stagePoint(canvasPoint(event))
        HamsterEngineMouse(engine, point.x, point.y, 0)
    }
    override func mouseUp(with event: NSEvent) {
        if pressedAuthor && authorRect.contains(canvasPoint(event)) { NSWorkspace.shared.open(Self.authorURL) }
        pressedAuthor = false
        releaseFood()
    }
    private func releaseFood() {
        if draggingFood { HamsterEngineMouse(engine, 0, 0, 2) }
        draggingFood = false
        pressedAuthor = false
    }
}
