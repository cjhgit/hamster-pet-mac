import AppKit
import SceneKit
import Darwin

@main struct VerifyPlayback {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "hamster.playback.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let view = HamsterView(frame: .init(x: 0, y: 0, width: 742, height: 558), seed: 11042, preferences: prefs)
        let window = HamsterWindow(preferences: prefs)
        window.contentView = view
        window.setContentSize(.init(width: 742, height: 558))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func key(_ code: UInt16, _ chars: String) {
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func button(_ id: String) -> NSButton {
            view.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }!
        }
        let play = button("playback-toggle"), step = button("playback-step")
        pump(0.4)
        let runningFrames = view.simulationFrames
        precondition(runningFrames > 0, "Visible animation must advance")
        precondition(!step.isEnabled)
        key(49, " "); precondition(view.isPlaybackPaused)
        key(49, " "); precondition(!view.isPlaybackPaused)
        view.layoutSubtreeIfNeeded()
        let point = play.convert(NSPoint(x: play.bounds.midX, y: play.bounds.midY), to: view)
        precondition(view.hitTest(view.convert(point, to: view.superview)) === play, "Overlay button must receive actual mouse hits")
        play.performClick(nil)
        precondition(view.isPlaybackPaused && step.isEnabled)
        let frame = view.simulationFrames, milliseconds = view.simulationMilliseconds
        let scene = view.scene3D!, position = scene.hamster.position, landmarks = scene.hamsterLandmarks
        let yaw = scene.yaw
        scene.orbit(dx: 45, dy: 20)
        precondition(scene.yaw != yaw)
        view.display()
        window.setContentSize(.init(width: 780, height: 586))
        let settings = view.makeSettingsMenu()
        settings.performActionForItem(at: 3)
        settings.performActionForItem(at: 3)
        precondition(scene.hamster.position.x == position.x && scene.hamster.position.y == position.y && scene.hamster.position.z == position.z, "Lighting must not advance a paused pose")
        precondition(scene.hamsterLandmarks.elementsEqual(landmarks, by: { $0.x == $1.x && $0.y == $1.y && $0.z == $1.z }))
        pump(0.3)
        window.orderOut(nil); pump(0.1); window.makeKeyAndOrderFront(nil); pump(0.2)
        precondition(view.simulationFrames == frame && view.simulationMilliseconds == milliseconds, "Pause must survive redraw, resize, visibility and theme changes")
        let foods = HamsterTestFoodCount()
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: 350, y: 260), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown)); view.mouseUp(with: mouse(.leftMouseUp)); view.mouseMoved(with: mouse(.mouseMoved))
        precondition(HamsterTestFoodCount() == foods)
        step.performClick(nil); key(124, "\u{f703}"); key(47, ".")
        let menu = view.makeSettingsMenu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "前进一帧"))
        precondition(view.simulationFrames == frame + 4)
        precondition(abs(view.simulationMilliseconds - milliseconds - 4000 / 30) < 0.001)
        pump(0.2); precondition(view.simulationFrames == frame + 4)
        key(49, " ")
        precondition(!view.isPlaybackPaused && !step.isEnabled)
        let resumedFrame = view.simulationFrames, resumedTime = view.simulationMilliseconds
        pump(0.22)
        precondition(view.simulationFrames > resumedFrame)
        precondition(view.simulationMilliseconds - resumedTime < 500, "Resume must not catch up paused time")
        let pauseMenu = view.makeSettingsMenu()
        pauseMenu.performActionForItem(at: pauseMenu.indexOfItem(withTitle: "暂停播放"))
        precondition(view.isPlaybackPaused)
        window.orderOut(nil)
        print("PASS: playback controls, hit testing, shortcuts, frame stepping, frozen pose/input, orbit, theme/resize/hide and resume without catch-up")
    }
}
