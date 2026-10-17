import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var window: HamsterWindow?
    private(set) var statusItem: NSStatusItem?
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Hamster Pet", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Hamster Pet")
        appMenu.addItem(withTitle: "隐藏 Hamster Pet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Hamster Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        let window = HamsterWindow(preferences: preferences)
        window.contentView = HamsterView(frame: NSRect(origin: .zero, size: window.frame.size),
                                        seed: UInt32.random(in: .min ... .max), preferences: preferences)
        window.center()
        self.window = window
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Hamster Pet")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Hamster Pet"
        let trayMenu = NSMenu(title: "Hamster Pet")
        trayMenu.delegate = self
        statusItem.menu = trayMenu
        self.statusItem = statusItem
        menuNeedsUpdate(trayMenu)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden
        let visibility = menu.addItem(withTitle: visible ? "隐藏仓鼠" : "显示仓鼠",
                                      action: #selector(toggleWindow(_:)), keyEquivalent: "")
        visibility.target = self
        menu.addItem(.separator())
        if let view = window?.contentView as? HamsterView {
            let settings = view.makeSettingsMenu()
            for item in settings.items {
                settings.removeItem(item)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Hamster Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let window else { return }
        if window.isVisible && !window.isMiniaturized && !NSApp.isHidden {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        NSApp.unhide(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
}
