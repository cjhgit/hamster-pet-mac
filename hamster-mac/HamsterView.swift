import AppKit
import CoreText
import MetalKit
import QuartzCore
import SceneKit
import SwiftUI

final class HamsterWindow: NSWindow, NSWindowDelegate {
    private static let settingsKey = "hamster.window"
    private let preferences: UserDefaults
    private var savesSettings = false

    static let sizes: [(name: String, size: NSSize)] = [
        ("小（50%）", NSSize(width: 371, height: 371 * 212 / 282)),
        ("中（75%）", NSSize(width: 556.5, height: 556.5 * 212 / 282)),
        ("大（100%）", NSSize(width: 742, height: 742 * 212 / 282))
    ]

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let settings = preferences.dictionary(forKey: Self.settingsKey) ?? [:]
        var size = Self.sizes[2].size
        if let width = settings["width"] as? Double, let height = settings["height"] as? Double,
           width.isFinite, height.isFinite, width >= 320, height > 0 {
            // Migrate the old padded ratio, preserving pixel-rounded sizes thereafter.
            let restoredHeight = abs(width / height - 282 / 212) < 0.01 ? height : width * 212 / 282
            size = NSSize(width: width, height: restoredHeight)
        }
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable, .miniaturizable, .closable],
                   backing: .buffered, defer: false)
        title = "Hamster Pet"
        minSize = NSSize(width: 320, height: 320 * 212 / 282)
        contentAspectRatio = NSSize(width: 282, height: 212)
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
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

/// 右键菜单「帮助」打开的说明窗口：汇总互动方式、视角操作与仓鼠的日常状态。
final class HamsterHelpWindowController: NSWindowController {
    private static var sharedController: HamsterHelpWindowController?
    private let textView = NSTextView()

    static func present(dark: Bool) {
        let controller = sharedController ?? HamsterHelpWindowController()
        sharedController = controller
        controller.applyTheme(dark: dark)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let scroll = NSScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "仓鼠帮助"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("hamster.help")
        super.init(window: window)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.textStorage?.setAttributedString(Self.helpText())
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = scroll
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(dark: Bool) {
        window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window?.backgroundColor = .windowBackgroundColor
    }

    /// 帮助正文：条目左侧为操作名，右侧浅色说明；分节标题加粗。
    private static func helpText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacingBefore = 14
        titleStyle.paragraphSpacing = 5
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 6
        bodyStyle.lineSpacing = 2.5
        let title = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: 14),
                     .foregroundColor: NSColor.labelColor, .paragraphStyle: titleStyle] as [NSAttributedString.Key: Any]
        let lead = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyStyle] as [NSAttributedString.Key: Any]
        let detail = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12.5),
                      .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: bodyStyle] as [NSAttributedString.Key: Any]

        func section(_ name: String) { text.append(NSAttributedString(string: name + "\n", attributes: title)) }
        func row(_ action: String, _ effect: String) {
            text.append(NSAttributedString(string: "• " + action, attributes: lead))
            text.append(NSAttributedString(string: " —— " + effect + "\n", attributes: detail))
        }
        func note(_ content: String) {
            text.append(NSAttributedString(string: content + "\n", attributes: detail))
        }

        section("怎么玩")
        row("在画面内移动鼠标", "吸引仓鼠注意，唤醒打盹或睡觉的它")
        row("点击空白处", "投喂食物，最多同时 10 粒")
        row("按住食物拖动再松开", "移动或抛出食物")
        row("⌘ + 拖动", "播放时直接把食物拖到仓鼠面前")
        row("点击黄色轮心", "邀请仓鼠上跑轮跑一会儿")
        row("点击水瓶底部或饮水嘴", "引导仓鼠去喝水")
        row("点击圆形软垫", "引导仓鼠走到垫子上睡觉")
        row("点击仓鼠身体", "抚摸它，先减速收步，再眯眼停留 3 秒；再次点击可延长")

        section("视角与播放")
        row("拖动", "旋转视角")
        row("滚轮 / 双指捏合", "缩放")
        row("⇧ + 拖动", "平移画面")
        row("数字 0–6", "正面、立体、右侧、背面、俯视、左侧、仓鼠特写；0 同时复位缩放与平移")
        row("空格", "暂停 / 继续播放")
        row("→ 或 .", "暂停时前进一帧（1/30 秒）；暂停时仍可旋转、缩放、平移，点击不再投食")

        section("窗口与菜单")
        row("按住窗口顶部拖动", "移动窗口；拖动边缘可手动缩放")
        row("右键 / ⌃点击", "置顶、窗口大小、深色模式（点亮夜间吊灯）、显示水印、暂停播放、3D 视角等")
        row("调试工具", "在左下角显示「暂停 / 继续、下一帧、帧数」控制条；空格与菜单项始终可用")
        row("菜单栏爪印图标", "显示 / 隐藏仓鼠，或退出应用")

        section("仓鼠的一天")
        note("仓鼠按自己的节奏生活：在笼里闲逛、驻足张望；闻到食物会跑过来捧着吃；渴了去水瓶喝水；闲下来坐着洗脸梳理；上轮撒欢跑一阵，跑累了歇息，困了就地蜷成一团睡觉。移动鼠标可以把它唤醒。")
        note("源自 aBowman 的 Chrome 仓鼠小玩具，由 3D 场景重制。")
        return text
    }
}

/// AppKit input with on-demand Metal rendering and a Core Graphics fallback.
final class HamsterView: NSView, NSMenuItemValidation {
    private let engine: UnsafeMutableRawPointer
    private let preferences: UserDefaults
    private static let watermarkKey = "hamster.showsWatermark"
    private var showsWatermark = true
    private static let darkModeKey = "hamster.darkMode"
    private var isDarkMode = false
    private static let debugToolsKey = "hamster.showsDebugTools"
    private var showsDebugTools = false
    private static let skeletonModeKey = "hamster.skeletonMode"
    private var timer: Timer?
    private var visibilityWatchdog: Timer?
    private var metalRenderer: HamsterMetalRenderer?
    private(set) var scene3D: Hamster3DScene?
    private var orbitStart: NSPoint?
    private var orbitPrevious = NSPoint.zero
    private var orbitDragged = false
    private let sceneHint = CATextLayer()
    private struct SceneLayout: Equatable {
        let bounds: NSRect
        let scale: CGFloat
        let night, paused, watermark: Bool
    }
    private var sceneLayout: SceneLayout?
    private let playbackControls = NSStackView()
    private let playButton = NSButton(title: "暂停", target: nil, action: nil)
    private let stepButton = NSButton(title: "下一帧", target: nil, action: nil)
    private let playbackPosition = NSTextField(labelWithString: "")
    private(set) var isPlaybackPaused = false
    private let watermarkLayer = CATextLayer()
    private let lampLayer = CALayer()
    private let focusLayer = CAShapeLayer()
    private var lampPixelScale: CGFloat = 0
    var usesMetal: Bool { metalRenderer != nil }
    var gpuSubmittedFrames: Int { metalRenderer?.submittedFrames ?? 0 }
    private(set) var cpuRenderedFrames = 0
    var simulationFrames: Int { Int(HamsterEngineGetFrameCount(engine)) }
    var simulationMilliseconds: Double { HamsterEngineGetElapsedMilliseconds(engine) }
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displayAsleep = false
    private var sessionInactive = false
    private var previousTime = ProcessInfo.processInfo.systemUptime
    private var accumulator = 0.0
    private var pendingTimerMilliseconds = 0.0
    private var draggingFood = false
    private var pressedAuthor = false
    private var authorFocused = false
    private var mouseTracking: NSTrackingArea?
    private static let background = NSColor.white
    private static let authorURL = URL(string: "http://abowman.com/google-modules/hamster")!
    private static let lampGlow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 1, green: 0.70, blue: 0.35, alpha: 0.55).cgColor,
        NSColor(srgbRed: 1, green: 0.70, blue: 0.35, alpha: 0).cgColor
    ] as CFArray, locations: [0, 1])!

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, seed: UInt32.random(in: .min ... .max))
    }

    init(frame frameRect: NSRect, seed: UInt32, preferences: UserDefaults = .standard, prefersMetal: Bool = true, prefers3D: Bool = true) {
        self.preferences = preferences
        engine = HamsterEngineCreate(seed)!
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Register the original author font once for the process.
        if let font = Bundle.main.url(forResource: "1_Icicle Country 2", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        applyLaunchColors()
        HamsterEngineStart(engine)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("宠物仓鼠")
        showsWatermark = preferences.object(forKey: Self.watermarkKey) as? Bool ?? true
        isDarkMode = preferences.bool(forKey: Self.darkModeKey)
        showsDebugTools = preferences.bool(forKey: Self.debugToolsKey)
        updateWatermark()
        setAccessibilityHelp("点击空白处投食，按住拖动或抛出食物；点击黄色轮心让仓鼠上跑轮。移动鼠标可唤醒仓鼠。")
        if prefers3D && !ProcessInfo.processInfo.arguments.contains("--hamster-cpu-renderer") {
            let renderer = Hamster3DScene(engine: engine)
            scene3D = renderer
            renderer.showsSkeleton = preferences.bool(forKey: Self.skeletonModeKey)
            addSubview(renderer.view)
            configurePlaybackControls()
            sceneHint.isHidden = true
            sceneHint.fontSize = 10
            sceneHint.alignmentMode = .center
            sceneHint.foregroundColor = NSColor.secondaryLabelColor.cgColor
            sceneHint.zPosition = 10
            layer?.addSublayer(sceneHint)
            watermarkLayer.string = "aBowman"
            watermarkLayer.font = NSFont(name: "IcicleCountry2", size: 15) ?? NSFont.boldSystemFont(ofSize: 15)
            watermarkLayer.fontSize = 15
            watermarkLayer.alignmentMode = .right
            watermarkLayer.zPosition = 10
            layer?.addSublayer(watermarkLayer)
            setAccessibilityHelp("真实 3D 场景。空格暂停或继续，暂停后按右方向键或句点前进一帧。暂停时仍可拖动旋转视角、滚轮缩放、Shift 拖动平移。播放时点击投食、Command 拖动食物。数字 0 复位，1 立体，2 右侧，3 背面，4 俯视，5 左侧，6 仓鼠特写。")
            update3DLayout()
        } else if prefersMetal && !ProcessInfo.processInfo.arguments.contains("--hamster-cpu-renderer"),
           let renderer = HamsterMetalRenderer(engine: engine) {
            metalRenderer = renderer
            addSubview(renderer.view)
            renderer.view.layer?.addSublayer(lampLayer)
            renderer.view.layer?.addSublayer(focusLayer)
            updateMetalLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateWatermark() {
        HamsterEngineSetWatermarkVisible(engine, showsWatermark ? 1 : 0)
        authorFocused = false
        pressedAuthor = false
        setAccessibilityCustomActions(showsWatermark ? [NSAccessibilityCustomAction(name: "访问原作者 aBowman 的仓鼠页面", handler: {
            NSWorkspace.shared.open(Self.authorURL)
        })] : [])
        window?.invalidateCursorRects(for: self)
        watermarkLayer.isHidden = !showsWatermark
        needsDisplay = true
    }

    deinit {
        timer?.invalidate()
        visibilityWatchdog?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
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
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch notification.name {
                        case NSWorkspace.screensDidSleepNotification: self.displayAsleep = true
                        case NSWorkspace.screensDidWakeNotification: self.displayAsleep = false
                        case NSWorkspace.sessionDidResignActiveNotification: self.sessionInactive = true
                        case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionInactive = false
                        default: break
                        }
                        self.updateActivity()
                    }
                })
            }
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        visibilityWatchdog?.invalidate()
        visibilityWatchdog = nil
        if let window {
            window.acceptsMouseMovedEvents = true
            window.makeFirstResponder(self)
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

    /// Headless window servers (CI runners) may never deliver occlusion
    /// notifications, so visibility is also re-checked on every tick and by a
    /// low-frequency watchdog that survives while the animation is suspended.
    private var isAnimationVisible: Bool {
        window?.isVisible == true && window?.occlusionState.contains(.visible) == true &&
            window?.isMiniaturized == false && !NSApp.isHidden && !displayAsleep && !sessionInactive
    }

    private func updateActivity() {
        if window?.isKeyWindow != true { releaseFood() }
        refreshActivity()
    }

    private func refreshActivity() {
        if isAnimationVisible && !isPlaybackPaused {
            startAnimation()
        } else {
            suspendAnimation()
        }
    }

    private func startAnimation() {
        guard !isPlaybackPaused else { return }
        visibilityWatchdog?.invalidate()
        visibilityWatchdog = nil
        guard timer == nil else { return }
        previousTime = ProcessInfo.processInfo.systemUptime
        accumulator = 0
        pendingTimerMilliseconds = 0
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1 / 300
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    private func suspendAnimation() {
        if timer != nil {
            timer?.invalidate()
            timer = nil
            previousTime = ProcessInfo.processInfo.systemUptime
            accumulator = 0
            pendingTimerMilliseconds = 0
            HamsterEnginePurgeRenderCache(engine)
            metalRenderer?.releaseDrawables()
            scene3D?.view.discardDrawables()
        }
        if isPlaybackPaused || displayAsleep || sessionInactive || NSApp.isHidden || window?.isMiniaturized == true {
            visibilityWatchdog?.invalidate()
            visibilityWatchdog = nil
            return
        }
        guard window != nil, visibilityWatchdog == nil else { return }
        let watchdog = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshActivity() }
        }
        watchdog.tolerance = 0.2
        visibilityWatchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
    }

    private func tick() {
        guard isAnimationVisible && !isPlaybackPaused else {
            suspendAnimation()
            return
        }
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
        if advanced {
            displaySimulationFrame()
        }
    }

    private func displaySimulationFrame() {
        if let scene3D {
            scene3D.update(night: isDarkMode)
        } else if let renderer = metalRenderer, !renderer.failed {
            renderer.night = isDarkMode
            renderer.view.draw()
        } else {
            if let renderer = metalRenderer {
                renderer.view.removeFromSuperview()
                metalRenderer = nil
            }
            needsDisplay = true
        }
        if isPlaybackPaused { updatePlaybackControls() }
    }

    private func configurePlaybackControls() {
        // Keep native controls above SceneKit's Metal-backed rendering layer.
        playbackControls.wantsLayer = true
        playbackControls.layer?.zPosition = 10
        playbackControls.layer?.cornerRadius = 6
        playbackControls.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        playbackControls.orientation = .horizontal
        playbackControls.spacing = 7
        playbackControls.translatesAutoresizingMaskIntoConstraints = false
        for (button, action, identifier) in [
            (playButton, #selector(togglePlayback(_:)), "playback-toggle"),
            (stepButton, #selector(advanceOneFrame(_:)), "playback-step")
        ] {
            button.target = self
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            playbackControls.addArrangedSubview(button)
        }
        playButton.toolTip = "暂停 / 继续（空格）"
        stepButton.toolTip = "暂停时前进一帧（→ 或 .）"
        playbackPosition.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        playbackPosition.textColor = .secondaryLabelColor
        playbackControls.addArrangedSubview(playbackPosition)
        addSubview(playbackControls)
        NSLayoutConstraint.activate([
            playbackControls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            playbackControls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26)
        ])
        updatePlaybackControls()
    }

    private func updatePlaybackControls() {
        // 暂停/逐帧控件属于调试工具，默认隐藏，右键菜单开启后才显示。
        playbackControls.isHidden = !showsDebugTools
        playButton.title = isPlaybackPaused ? "继续" : "暂停"
        stepButton.isEnabled = isPlaybackPaused
        playbackPosition.isHidden = !isPlaybackPaused
        playbackPosition.stringValue = "第 \(simulationFrames) 帧"
    }

    @objc private func togglePlayback(_ sender: Any?) {
        releaseFood()
        authorFocused = false
        orbitStart = nil
        isPlaybackPaused.toggle()
        refreshActivity()
        updatePlaybackControls()
        update3DLayout()
        window?.makeFirstResponder(self)
    }

    @objc private func advanceOneFrame(_ sender: Any?) {
        guard isPlaybackPaused else { return }
        HamsterEngineStep(engine, 1000 / 30)
        displaySimulationFrame()
        window?.makeFirstResponder(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(advanceOneFrame(_:)) { return isPlaybackPaused }
        return true
    }

    private var canvasRect: NSRect {
        let width = min(bounds.width, bounds.height * 282 / 212)
        let height = width * 212 / 282
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    private func canvasPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = canvasRect
        return NSPoint(x: (point.x - rect.minX) * 282 / rect.width - 1,
                       y: (point.y - rect.minY) * 212 / rect.height - 1)
    }

    private func isInStage(_ point: NSPoint) -> Bool {
        (0 ... 280).contains(point.x) && (0 ... 210).contains(point.y)
    }

    private var authorRect: NSRect {
        NSRect(x: 220, y: 1, width: 56, height: 14)
    }

    private var windowDragRect: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(28, bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawing while visible restarts a stalled loop when the window server
        // omitted occlusion notifications entirely.
        if timer == nil, isAnimationVisible { startAnimation() }
        if let scene3D {
            update3DLayout()
            scene3D.view.draw()
            return
        }
        if let renderer = metalRenderer, NSGraphicsContext.current?.isDrawingToScreen == true {
            updateMetalLayout()
            renderer.night = isDarkMode
            renderer.view.draw()
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if NSGraphicsContext.current?.isDrawingToScreen == true { cpuRenderedFrames += 1 }
        render(in: context)
    }

    /// Metal surfaces cannot be captured with NSView.cacheDisplay. Read back only
    /// for an explicit snapshot; normal animation never transfers pixels to CPU.
    func captureSnapshot() -> NSBitmapImageRep? {
        if let scene3D {
            update3DLayout()
            let image = scene3D.snapshot(size: bounds.size)
            image.lockFocus()
            draw3DOverlay(in: bounds)
            image.unlockFocus()
            guard let data = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: data)
        }
        let backing = window?.backingScaleFactor ?? 2
        let width = Int(ceil(bounds.width * backing)), height = Int(ceil(bounds.height * backing))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: backing, y: -backing)
        metalRenderer?.night = isDarkMode
        let rect = canvasRect
        let image = metalRenderer?.snapshot(size: CGSize(width: ceil(rect.width * backing), height: ceil(rect.height * backing)))
        render(in: context, gpuImage: image)
        return context.makeImage().map { NSBitmapImageRep(cgImage: $0) }
    }

    private func render(in context: CGContext, gpuImage: CGImage? = nil) {
        let rect = canvasRect
        context.saveGState()
        let scale = rect.width / 282
        let outline = CGPath(roundedRect: rect, cornerWidth: 6 * scale, cornerHeight: 6 * scale, transform: nil)
        context.addPath(outline)
        context.clip()
        context.setFillColor(Self.background.cgColor)
        context.fill(bounds)
        context.translateBy(x: rect.minX + scale, y: rect.minY + scale)
        context.scaleBy(x: scale, y: scale)
        if let image = gpuImage {
            context.saveGState()
            context.translateBy(x: -1, y: 211)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 282, height: 212))
            context.restoreGState()
        } else {
            HamsterEngineDrawWithTheme(engine, context, isDarkMode ? 1 : 0)
            if isDarkMode {
                context.saveGState()
                context.setBlendMode(.multiply)
                let light = CGPoint(x: 259, y: 40)
                context.setFillColor(NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1).cgColor)
                context.fill(CGRect(x: -1, y: -1, width: 282, height: 212))
                context.setBlendMode(.screen)
                context.drawRadialGradient(Self.lampGlow, startCenter: light, startRadius: 0,
                                           endCenter: light, endRadius: 32, options: [])
                context.restoreGState()
            }
        }
        if isDarkMode { drawNightLamp(in: context) }
        context.restoreGState()
        if authorFocused && window?.firstResponder === self {
            let focus = authorRect.insetBy(dx: -2, dy: -2)
            context.saveGState()
            context.translateBy(x: rect.minX + scale, y: rect.minY + scale)
            context.scaleBy(x: scale, y: scale)
            context.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor)
            context.setLineWidth(2)
            context.stroke(focus)
            context.restoreGState()
        }

    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayout()
        update3DLayout()
    }

    private func updateMetalLayout() {
        guard let renderer = metalRenderer else { return }
        let rect = canvasRect
        let scale = rect.width / 282
        let pixelScale = scale * (window?.backingScaleFactor ?? 2)
        guard pixelScale > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.view.frame = rect
        renderer.view.layer?.cornerRadius = 6 * scale
        lampLayer.frame = CGRect(x: 245 * scale, y: scale, width: 30 * scale, height: 49 * scale)
        lampLayer.isHidden = !isDarkMode
        if isDarkMode && (lampPixelScale != pixelScale || lampLayer.contents == nil) {
            let width = Int(ceil(30 * pixelScale)), height = Int(ceil(49 * pixelScale))
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: pixelScale, y: -pixelScale)
                context.translateBy(x: -244, y: 0)
                drawNightLamp(in: context)
                lampLayer.contents = context.makeImage()
                lampLayer.contentsScale = window?.backingScaleFactor ?? 2
                lampPixelScale = pixelScale
            }
        }
        focusLayer.frame = CGRect(origin: .zero, size: rect.size)
        focusLayer.isHidden = !authorFocused || window?.firstResponder !== self
        focusLayer.fillColor = nil
        focusLayer.strokeColor = NSColor.keyboardFocusIndicatorColor.cgColor
        focusLayer.lineWidth = 2 * scale
        let focus = authorRect.insetBy(dx: -2, dy: -2)
        focusLayer.path = CGPath(rect: CGRect(x: (focus.minX + 1) * scale, y: (focus.minY + 1) * scale,
                                             width: focus.width * scale, height: focus.height * scale), transform: nil)
        renderer.night = isDarkMode
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if scene3D != nil && !playbackControls.isHidden && playbackControls.frame.contains(local) {
            return playbackControls.hitTest(local)
        }
        if scene3D != nil { return bounds.contains(convert(point, from: superview)) ? self : nil }
        return super.hitTest(point)
    }

    private func update3DLayout() {
        guard let scene3D else { return }
        let scale = window?.backingScaleFactor ?? 2
        let layout = SceneLayout(bounds: bounds, scale: scale, night: isDarkMode, paused: isPlaybackPaused, watermark: showsWatermark)
        guard sceneLayout != layout else { return }
        sceneLayout = layout
        scene3D.resize(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene3D.view.layer?.cornerRadius = 12
        sceneHint.contentsScale = scale
        sceneHint.frame = .init(x: 4, y: bounds.height - 20, width: bounds.width - 8, height: 16)
        sceneHint.fontSize = bounds.width < 500 ? 8 : 10
        sceneHint.string = isPlaybackPaused ? "已暂停 · 空格继续 · → 下一帧" : nil
        sceneHint.isHidden = !isPlaybackPaused
        sceneHint.foregroundColor = (isDarkMode ? NSColor.lightGray : NSColor.gray).cgColor
        let appearanceName: NSAppearance.Name = isDarkMode ? .darkAqua : .aqua
        if playbackControls.appearance?.name != appearanceName {
            playbackControls.appearance = NSAppearance(named: appearanceName)
        }
        playbackControls.layer?.backgroundColor = (isDarkMode ? NSColor(white: 0.16, alpha: 0.92) : NSColor(white: 0.94, alpha: 0.94)).cgColor
        playbackPosition.textColor = isDarkMode ? .lightGray : .darkGray
        watermarkLayer.contentsScale = scale
        watermarkLayer.frame = .init(x: bounds.width - 115, y: 7, width: 104, height: 22)
        watermarkLayer.foregroundColor = (isDarkMode ? NSColor.white : NSColor.black).cgColor
        watermarkLayer.isHidden = !showsWatermark
        CATransaction.commit()
    }

    private func draw3DOverlay(in rect: NSRect) {
        if showsWatermark {
            let text = "aBowman" as NSString
            text.draw(at: .init(x: rect.width - 105, y: rect.height - 25), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: isDarkMode ? NSColor.white : NSColor.black])
        }
    }

    private func scenePoint(_ event: NSEvent) -> NSPoint {
        guard let scene3D else { return .zero }
        return scene3D.view.convert(event.locationInWindow, from: nil)
    }

    private func drawNightLamp(in context: CGContext) {
        context.saveGState()
        // A small pendant stays below the author credit and moves with the scene.
        context.setStrokeColor(NSColor(srgbRed: 0.42, green: 0.37, blue: 0.29, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 259, y: 1))
        context.addLine(to: CGPoint(x: 259, y: 28))
        context.strokePath()
        context.setShadow(offset: .zero, blur: 8,
                          color: NSColor(srgbRed: 1, green: 0.65, blue: 0.22, alpha: 0.85).cgColor)
        context.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.56, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 255, y: 35, width: 8, height: 5))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let shade = CGMutablePath()
        shade.move(to: CGPoint(x: 254, y: 28))
        shade.addLine(to: CGPoint(x: 264, y: 28))
        shade.addLine(to: CGPoint(x: 270, y: 36))
        shade.addQuadCurve(to: CGPoint(x: 248, y: 36), control: CGPoint(x: 259, y: 39))
        shade.closeSubpath()
        context.addPath(shade)
        context.setFillColor(NSColor(srgbRed: 0.35, green: 0.30, blue: 0.23, alpha: 1).cgColor)
        context.setStrokeColor(NSColor(srgbRed: 0.71, green: 0.55, blue: 0.32, alpha: 1).cgColor)
        context.setLineWidth(0.8)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        releaseFood()
        let menu = makeSettingsMenu()
        menu.addItem(.separator())
        let restart = menu.addItem(withTitle: "重启应用", action: #selector(restartApp(_:)), keyEquivalent: "")
        restart.target = self
        let close = menu.addItem(withTitle: "关闭窗口", action: #selector(closeWindow(_:)), keyEquivalent: "")
        close.target = self
        return menu
    }

    func makeSettingsMenu() -> NSMenu {
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
        let watermark = menu.addItem(withTitle: "显示水印", action: #selector(toggleWatermark(_:)), keyEquivalent: "")
        watermark.target = self
        watermark.state = showsWatermark ? .on : .off
        let darkMode = menu.addItem(withTitle: "深色模式", action: #selector(toggleDarkMode(_:)), keyEquivalent: "")
        darkMode.target = self
        darkMode.state = isDarkMode ? .on : .off
        let debugTools = menu.addItem(withTitle: "调试工具", action: #selector(toggleDebugTools(_:)), keyEquivalent: "")
        debugTools.target = self
        debugTools.state = showsDebugTools ? .on : .off
        if let scene3D {
            let skeleton = menu.addItem(withTitle: "骨骼模式", action: #selector(toggleSkeletonMode(_:)), keyEquivalent: "")
            skeleton.target = self
            skeleton.state = scene3D.showsSkeleton ? .on : .off
            skeleton.toolTip = "显示当前运动姿态的骨骼，可配合暂停、逐帧和 3D 视角调试"
        }
        menu.addItem(.separator())
        let playback = menu.addItem(withTitle: isPlaybackPaused ? "继续播放" : "暂停播放", action: #selector(togglePlayback(_:)), keyEquivalent: "")
        playback.target = self
        let step = menu.addItem(withTitle: "前进一帧", action: #selector(advanceOneFrame(_:)), keyEquivalent: "")
        step.target = self
        step.isEnabled = isPlaybackPaused
        if scene3D != nil {
            menu.addItem(.separator())
            let views = NSMenu(title: "3D 视角")
            for (i, title) in ["正面（0）", "立体（1）", "右侧（2）", "背面（3）", "俯视（4）", "左侧（5）", "仓鼠特写（6）"].enumerated() {
                let item = views.addItem(withTitle: title, action: #selector(change3DView(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
            }
            menu.addItem(withTitle: "3D 视角", action: nil, keyEquivalent: "").submenu = views

        }
        menu.addItem(.separator())
        let help = menu.addItem(withTitle: "帮助", action: #selector(showHelp(_:)), keyEquivalent: "")
        help.target = self
        return menu
    }

    @objc private func showHelp(_ sender: NSMenuItem) {
        HamsterHelpWindowController.present(dark: isDarkMode)
    }

    @objc private func change3DView(_ sender: NSMenuItem) { scene3D?.preset(sender.tag) }

    @objc private func toggleOnTop(_ sender: NSMenuItem) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc private func toggleWatermark(_ sender: NSMenuItem) {
        showsWatermark.toggle()
        preferences.set(showsWatermark, forKey: Self.watermarkKey)
        updateWatermark()
    }

    @objc private func toggleDarkMode(_ sender: NSMenuItem) {
        isDarkMode.toggle()
        preferences.set(isDarkMode, forKey: Self.darkModeKey)
        scene3D?.update(night: isDarkMode)
        update3DLayout()
        needsDisplay = true
    }

    @objc private func toggleSkeletonMode(_ sender: NSMenuItem) {
        guard let scene3D else { return }
        scene3D.showsSkeleton.toggle()
        preferences.set(scene3D.showsSkeleton, forKey: Self.skeletonModeKey)
    }

    @objc private func toggleDebugTools(_ sender: NSMenuItem) {
        showsDebugTools.toggle()
        preferences.set(showsDebugTools, forKey: Self.debugToolsKey)
        updatePlaybackControls()
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

    /// 重启应用：先用 `open -n` 拉起新实例，再退出当前进程。
    @objc private func restartApp(_ sender: NSMenuItem) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("重启应用失败：\(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMetalLayout()
        update3DLayout()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        mouseTracking = tracking
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // The 3D view uses the same ray hit test for hovering and clicking.
        // Fixed canvas rectangles only match the original 2D camera.
        guard scene3D == nil else { return }
        let rect = canvasRect
        let scale = rect.width / 282
        let author = authorRect
        let contentRect = NSRect(x: bounds.minX, y: windowDragRect.maxY, width: bounds.width,
                                 height: max(0, bounds.maxY - windowDragRect.maxY))
        let authorCursor = NSRect(x: rect.minX + (author.minX + 1) * scale, y: rect.minY + (author.minY + 1) * scale,
                                  width: author.width * scale, height: author.height * scale).intersection(contentRect)
        if showsWatermark && !authorCursor.isEmpty { addCursorRect(authorCursor, cursor: .pointingHand) }
        addCursorRect(NSRect(x: rect.minX + 158 * scale, y: rect.minY + 96 * scale, width: 20 * scale, height: 20 * scale), cursor: .pointingHand)
        addCursorRect(windowDragRect, cursor: .openHand)
    }

    private func update3DCursor(at location: NSPoint) {
        guard let scene3D else { return }
        let cursor: NSCursor
        if showsWatermark && watermarkLayer.frame.contains(location) {
            cursor = .pointingHand
        } else if windowDragRect.contains(location) {
            cursor = .openHand
        } else if !isPlaybackPaused && scene3D.interactionTarget(at: scene3D.view.convert(location, from: self)) != nil {
            cursor = .pointingHand
        } else {
            cursor = .arrow
        }
        cursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard scene3D != nil else { super.cursorUpdate(with: event); return }
        update3DCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if scene3D != nil { NSCursor.arrow.set() }
        super.mouseExited(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if event.keyCode == 49 && plain && !authorFocused {
            if !event.isARepeat { togglePlayback(nil) }
        } else if isPlaybackPaused && plain && (event.keyCode == 124 || event.charactersIgnoringModifiers == ".") {
            advanceOneFrame(nil)
        } else if let scene3D, let text = event.charactersIgnoringModifiers, let preset = Int(text), (0...6).contains(preset) {
            scene3D.preset(preset)
        } else if showsWatermark && event.keyCode == 48 {
            authorFocused.toggle()
            needsDisplay = true
        } else if authorFocused && (event.keyCode == 36 || event.keyCode == 49) {
            NSWorkspace.shared.open(Self.authorURL)
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scene3D else { super.scrollWheel(with: event); return }
        scene3D.magnify(-event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.06))
    }
    override func magnify(with event: NSEvent) { scene3D?.magnify(event.magnification) }
    override func otherMouseDown(with event: NSEvent) { orbitPrevious = convert(event.locationInWindow, from: nil) }
    override func otherMouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        scene3D?.orbit(dx: p.x - orbitPrevious.x, dy: p.y - orbitPrevious.y)
        orbitPrevious = p
    }

    override func mouseMoved(with event: NSEvent) {
        update3DCursor(at: convert(event.locationInWindow, from: nil))
        guard !isPlaybackPaused else { return }
        if let scene3D {
            if let p = scene3D.stagePoint(scenePoint(event)), isInStage(p) { HamsterEngineMouse(engine, p.x, p.y, 0) }
            return
        }
        let canvas = canvasPoint(event)
        let point = canvas
        if isInStage(point) && !(showsWatermark && authorRect.contains(canvas)) { HamsterEngineMouse(engine, point.x, point.y, 0) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if scene3D != nil && showsWatermark && watermarkLayer.frame.contains(location) {
            pressedAuthor = true
            return
        }
        if windowDragRect.contains(location) || !bounds.insetBy(dx: 6, dy: 6).contains(location) {
            releaseFood()
            window?.performDrag(with: event)
            return
        }
        if let scene3D {
            pressedAuthor = showsWatermark && watermarkLayer.frame.contains(location)
            if pressedAuthor { return }
            orbitStart = location
            orbitPrevious = location
            orbitDragged = false
            if !isPlaybackPaused, event.modifierFlags.contains(.command), let p = scene3D.stagePoint(scenePoint(event)), isInStage(p) {
                draggingFood = true
                HamsterEngineMouse(engine, p.x, p.y, 1)
            }
            return
        }
        let canvas = canvasPoint(event)
        pressedAuthor = showsWatermark && authorRect.contains(canvas)
        authorFocused = false
        if pressedAuthor { return }
        guard !isPlaybackPaused else { return }
        let point = canvas
        if isInStage(point) {
            draggingFood = true
            HamsterEngineMouse(engine, point.x, point.y, 1)
        } else {
            window?.performDrag(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if let scene3D {
            let p = convert(event.locationInWindow, from: nil)
            if draggingFood {
                if let stage = scene3D.stagePoint(scenePoint(event)) { HamsterEngineMouse(engine, stage.x, stage.y, 0) }
            } else if let start = orbitStart {
                if hypot(p.x - start.x, p.y - start.y) > 3 { orbitDragged = true }
                if orbitDragged {
                    if event.modifierFlags.contains(.shift) { scene3D.pan(dx: p.x - orbitPrevious.x, dy: p.y - orbitPrevious.y) }
                    else { scene3D.orbit(dx: p.x - orbitPrevious.x, dy: p.y - orbitPrevious.y) }
                }
            }
            orbitPrevious = p
            return
        }
        guard draggingFood else { return }
        let point = canvasPoint(event)
        HamsterEngineMouse(engine, point.x, point.y, 0)
    }
    override func mouseUp(with event: NSEvent) {
        if let scene3D {
            if pressedAuthor && watermarkLayer.frame.contains(convert(event.locationInWindow, from: nil)) { NSWorkspace.shared.open(Self.authorURL) }
            else if !isPlaybackPaused && orbitStart != nil && !orbitDragged && !draggingFood {
                switch scene3D.interactionTarget(at: scenePoint(event)) {
                case .wheel:
                    HamsterEngineMouse(engine, 167, 105, 1)
                    HamsterEngineMouse(engine, 167, 105, 2)
                case .water:
                    HamsterEngineRequestDrink(engine)
                case .hamster:
                    HamsterEnginePet(engine)
                case .cushion:
                    HamsterEngineRequestSleep(engine, Double(Hamster3DScene.cushionCenter.x) + 140)
                case nil:
                    if let p = scene3D.stagePoint(scenePoint(event)), isInStage(p) {
                        HamsterEngineMouse(engine, p.x, p.y, 1)
                        HamsterEngineMouse(engine, p.x, p.y, 2)
                    }
                }
            }
            orbitStart = nil
            releaseFood()
            return
        }
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
